# Auto-instrumentation: what installs, what is skipped, what a
# teardown puts back — the two built-ins that can be driven without a
# server behind them (void/cache and the jobs event hook), and the db
# pool one against a live pool.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/core/hooks :as hooks)
(import void/core/system :as system)
(import void/test :as test)
(import void/db/pool :as pool)
(import void/obs/metrics :as metrics)
(import void/obs/instrument :as instrument)
(import void/obs/prometheus :as prom)
(import void/obs/trace :as trace)
(import void/db/state :as dbstate)
(import void/jobs/job :as job)
(import void/jobs/state :as jobstate)
(import void/jobs/worker :as jobworker)
(require "void/cache/init")
(require "void/db/init")
(require "void/db-sqlite/init")
(require "void/jobs/init")

(log/set-level! "void.obs" :error)
(log/set-level! "void.cache" :error)
(log/set-level! "void.db" :error)
(log/set-level! "void.db.sqlite" :error)

(def empty-boot @{:system (system/init [] {}) :hooks (hooks/registry)})

# -- needs that this composition does not have ---------------------------

(var installed-count 0)
(def missing
  {:name :test/missing
   :needs [:nothing/here]
   :install (fn [_ _] (++ installed-count) nil)})

(def applied (instrument/install! empty-boot [missing]))
(assert (empty? applied) "an instrumentation whose component is absent is skipped")
(assert (zero? installed-count)
        "quietly: 'observe the database if there is one' is the whole point, and a boot that failed because obs is present and Postgres is not would be an anti-feature")

# -- an instrumentation with nothing to need -----------------------------

(var torn-down false)
(def simple
  {:name :test/simple
   :install (fn [boot]
              (assert (= empty-boot boot) "the boot is the first argument — hooks and extensions live in it")
              (fn [] (set torn-down true)))})

(def one (instrument/install! empty-boot [simple]))
(assert (= 1 (length one)))
(assert (= :test/simple (get-in one [0 :name])))
(instrument/remove! one)
(assert torn-down "and its teardown runs at :before-stop")

# -- the config filter ---------------------------------------------------

(assert (empty? (instrument/install! empty-boot [simple] []))
        "[:obs :instrument] false installs nothing")
(assert (= 1 (length (instrument/install! empty-boot [simple] [:test/simple])))
        "a list of names installs those")
(assert (empty? (instrument/install! empty-boot [simple] [:test/other]))
        "and only those")

# -- a broken instrumentation is not a broken boot -----------------------

(def broken {:name :test/broken :install (fn [_] (error "no"))})
(assert (empty? (instrument/install! empty-boot [broken]))
        "an install that throws is logged and left out, never propagated into the boot")
(assert (first (protect (instrument/remove! [{:name :test/x :teardown (fn [] (error "no"))}])))
        "and a teardown that throws does not stop a shutdown")

# -- jobs: the event hook ------------------------------------------------

(metrics/reset! :void.jobs/events-total)
(metrics/reset! :void.jobs/duration-seconds)
(metrics/reset! :void.jobs/queue-delay-seconds)

(instrument/job-event!
  {:event :started
   :job {:queue :default :job :orders/settle :enqueued-at 100 :run-at 100 :started-at 100.25}})
(instrument/job-event!
  {:event :completed
   :job {:queue :default :job :orders/settle :started-at 100.25 :finished-at 100.75}})
(instrument/job-event!
  {:event :failed
   :job {:queue :default :job :orders/settle :started-at 200 :finished-at 200.5}})

(assert (= 1 (metrics/value instrument/job-events ["started" "default" "orders/settle"])))
(assert (= 1 (metrics/value instrument/job-events ["failed" "default" "orders/settle"]))
        "the E of a queue's RED is its :failed and :dead events")
(def d (metrics/value instrument/job-duration ["default" "orders/settle"]))
(assert (= 2 (d :count)) "a job that failed still took time, and the histogram says how much")
(assert (= 1 (get (metrics/value instrument/job-queue-delay) :count))
        "and the delay before a worker picked it up is the number that says whether the queue needs more workers")

(instrument/job-event! {:event :enqueued :job {}})
(assert (= 1 (metrics/value instrument/job-events ["enqueued" "-" "-"]))
        "a record with neither queue nor name still counts, under a constant label")

# -- cache: a real component through its own public stats ----------------

(test/with-system [boot {:plugins [:void/cache]
                         :config {:cli {:log {:level :error}}}}]
  (def contribs (filter |(= :void.cache/store ($ :name)) instrument/built-ins))
  (assert (= 1 (length contribs)) "obs ships the cache instrumentation itself (see the module docstring)")
  (def on (instrument/install! boot contribs))
  (assert (= 1 (length on)) "and it installs when :void/cache is in the composition")

  (def cache (system/instance (boot :system) :void/cache))
  (def cachemod (require "void/cache/init"))
  (def put! (get-in cachemod ['put! :value]))
  (def fetch (get-in cachemod ['fetch :value]))
  (with-dyns [(get-in (require "void/cache/state") ['cache-dyn :value]) cache]
    (put! "k" "v")
    (fetch "k")
    (fetch "missing"))

  (def snap (metrics/snapshot))
  (defn- value-of [name]
    (get-in (first (filter |(= name ($ :name)) snap)) [:series 0 :value]))
  (assert (= 1 (value-of :void.cache/hits-total)) "the hit went through the funnel obs reads")
  (assert (= 1 (value-of :void.cache/misses-total)))
  (assert (= 1 (value-of :void.cache/puts-total)))

  # a component may be restarted under the instrumentation (the dev reload
  # path): the collector has to follow the new instance, not go on
  # reporting the closed one
  (system/restart (boot :system) :cache/store)
  (def restarted (metrics/snapshot))
  (assert (zero? (get-in (first (filter |(= :void.cache/hits-total ($ :name)) restarted))
                         [:series 0 :value]))
          "after a restart the numbers are the new instance's — the component is resolved at collect time, not captured at install time")

  (instrument/remove! on)
  (def after (metrics/snapshot))
  (assert (empty? (get-in (first (filter |(= :void.cache/hits-total ($ :name)) after)) [:series]))
          "and a detached instrumentation reports no series rather than the numbers it had when it stopped"))

# -- db: the pool gauges against a live pool -----------------------------

(test/with-system [boot {:plugins [:void/db :void/db-sqlite]
                         :config {:cli {:log {:level :error}
                                        :db {:pool {:size 1}}
                                        :db-sqlite {:path ":memory:"}}}}]
  (def contribs (filter |(= :void.db/pool ($ :name)) instrument/built-ins))
  (assert (= 1 (length contribs)) "obs ships the db pool instrumentation itself (see the module docstring)")
  (def on (instrument/install! boot contribs))
  (assert (= 1 (length on)) "and it installs when :db/pool is in the composition")

  (def p (system/instance (boot :system) :db/pool))
  (def held (pool/checkout p))
  # a second checkout has to park: the pool is at :size with nothing
  # idle — which is exactly the state the audit wanted a gauge on
  (ev/go (fn [] (pool/checkin p (pool/checkout p))))
  (ev/sleep 0.02)

  (defn- pool-gauge [snap name]
    (get-in (first (filter |(= name ($ :name)) snap)) [:series 0 :value]))
  (def busy (metrics/snapshot))
  (assert (= 1 (pool-gauge busy :void.db/pool-size)) "the configured size is a series")
  (assert (= 1 (pool-gauge busy :void.db/pool-connections)))
  (assert (= 1 (pool-gauge busy :void.db/pool-in-use)))
  (assert (zero? (pool-gauge busy :void.db/pool-idle)))
  (assert (= 1 (pool-gauge busy :void.db/pool-waiting))
          "the parked fiber is visible while it waits")
  (assert (zero? (pool-gauge busy :void.db/pool-timeouts-total)) "and it has not timed out")

  # the same numbers reach the text exposition a scraper reads
  (def text (prom/render busy))
  (assert (string/find "# TYPE void_db_pool_size gauge" text))
  (assert (string/find "\nvoid_db_pool_size 1" text))
  (assert (string/find "\nvoid_db_pool_in_use 1" text))
  (assert (string/find "\nvoid_db_pool_waiting 1" text))

  # hand the connection over: the parked fiber runs and returns it
  (pool/checkin p held)
  (ev/sleep 0.02)
  (def calm (metrics/snapshot))
  (assert (zero? (pool-gauge calm :void.db/pool-waiting)))
  (assert (zero? (pool-gauge calm :void.db/pool-in-use)))
  (assert (= 1 (pool-gauge calm :void.db/pool-idle)) "the connection is back on the idle stack")

  (instrument/remove! on)
  (assert (empty? (get-in (first (filter |(= :void.db/pool-size ($ :name)) (metrics/snapshot)))
                          [:series]))
          "a detached pool reports no series, not its last numbers"))

# -- the seams: a span around the work, and the traceparent out ----------
#
# The other half of an instrumentation. A stats function is read; a
# span has to be around the work, so the packages expose a var obs
# fills (see the module docstring) — these check that obs fills it,
# that the package calls it, and that a teardown puts back what it
# found.

(def spans @[])
(trace/set-exporters! [{:name :test/collect :fn (fn [s] (array/push spans s))}])
(set trace/enabled true)

(defn- var-of
  "The current value of a module's var — what `module-var!` writes."
  [path name]
  (in (get-in (require path) [name :ref] @[nil]) 0))

(defn- span-named [name]
  (first (filter |(= name ($ :name)) spans)))

(assert (trace/consuming?)
        "with an exporter installed, a span started inside a statement has a reader")

# a statement, through the funnel void/db actually runs it in
(test/with-system [boot {:plugins [:void/db :void/db-sqlite]
                         :config {:cli {:log {:level :error}
                                        :db {:pool {:size 1}}
                                        :db-sqlite {:path ":memory:"}}}}]
  (def on (instrument/install! boot (filter |(= :void.db/pool ($ :name)) instrument/built-ins)))
  (assert (= instrument/traced-statement (var-of "void/db/state" 'around-statement))
          "obs fills void/db/state's seam at install")

  (array/clear spans)
  (with-dyns [dbstate/pool-dyn (system/instance (boot :system) :db/pool)]
    (trace/with-span "outer" {:sampled true}
      (dbstate/execute-sql "SELECT 1" [])))

  (def q (span-named "db SELECT"))
  (assert q "a statement under a traced request is a span of that request")
  (assert (= "SELECT 1" (get-in q [:attrs :db.statement]))
          "with the statement on it — the shape of the query, which belongs in a trace")
  (assert (nil? (get-in q [:attrs :db.params]))
          "and never the parameters, which are the data and do not")
  (assert (= :sqlite (get-in q [:attrs :db.system])))
  (assert (= (q :parent-id) ((span-named "outer") :span-id))
          "the child hangs off the span it ran inside")
  (assert (= :client (q :kind)))

  (instrument/remove! on)
  (assert (nil? (var-of "void/db/state" 'around-statement))
          "and a teardown puts back what it found — an uninstrumented process runs the statement it always ran"))

# an unrecognised statement does not become a series of its own
(array/clear spans)
(trace/with-span "outer" {:sampled true}
  (instrument/traced-statement "/* hello */ SELECT 1" {:dialect :postgres} (fn [] :ok))
  (instrument/traced-statement "insert into t values (1)" {:dialect :postgres} (fn [] :ok)))
(assert (span-named "db OTHER") "a span name is a metric label, so it is the verb or OTHER")
(assert (span-named "db INSERT") "and the verb is read whatever case it was written in")

# redis: one span per attempt, named by the command word
(array/clear spans)
(trace/with-span "outer" {:sampled true}
  (assert (= :pong (instrument/traced-command "PING" (fn [] :pong)))
          "the wrapper returns what the command returned"))
(assert (span-named "redis PING"))
(assert (= :redis (get-in (span-named "redis PING") [:attrs :db.system])))

# the http client: the span, and the header the client had nobody to write
(array/clear spans)
(def headers @{"content-type" "application/json"})
(def sent
  (trace/with-span "outer" {:sampled true}
    (instrument/traced-request @{:host "collector.test" :port "4318"}
                               "POST" "/v1/traces?tenant=acme" headers
                               (fn [] {:status 200}))))
(assert (= 200 (sent :status)) "the wrapper returns the response")
(def out (span-named "http POST"))
(assert out)
(def tp (trace/parse-traceparent (get headers "traceparent")))
(assert tp "traceparent goes out on the request")
(assert (= (out :span-id) (tp :parent-id))
        "naming the span of this very call as the parent of whatever the peer starts")
(assert (= (out :trace-id) (tp :trace-id)))
(assert (= "/v1/traces" (get-in out [:attrs :url.path]))
        "the path without its query — a query carries values, and a span attribute is not the place for a token somebody put in a URL")
(assert (= "collector.test" (get-in out [:attrs :server.address])))
(assert (= 200 (get-in out [:attrs :http.response.status_code])))
(assert (= :ok (out :status)))

(array/clear spans)
(trace/with-span "outer" {:sampled true}
  (instrument/traced-request @{:host "collector.test" :port "4318"}
                             "POST" "/v1/traces" @{} (fn [] {:status 503})))
(assert (= :error ((span-named "http POST") :status))
        "an outbound 4xx or 5xx is this call not getting what it asked for")

# jobs: the span around running one, and the seam the worker calls
(array/clear spans)
(trace/with-span "outer" {:sampled true}
  (instrument/traced-job {:job :orders/settle :queue :default :id "j1" :attempt 2}
                         (fn [] :done)))
(def js (span-named "job orders/settle"))
(assert js)
(assert (= :consumer (js :kind)))
(assert (= "default" (get-in js [:attrs :messaging.destination.name])))
(assert (= "j1" (get-in js [:attrs :messaging.message.id])))

# a failure is the span's failure, and the error still reaches the caller
(array/clear spans)
(assert (not (first (protect (trace/with-span "outer" {:sampled true}
                              (instrument/traced-command "GET" (fn [] (error "boom")))))))
        "a wrapper does not swallow what it wrapped")
(assert (= :error ((span-named "redis GET") :status)))

# jobs: the record carries the trace it was queued in, and the worker
# hangs its span off it — the one assertion that is only worth making
# end to end, because the two halves are minutes and a process apart
(job/defjob traced-ping [] :pong)

(test/with-system [boot {:plugins [:void/jobs]
                         :config {:cli {:log {:level :error}}}}]
  (def on (instrument/install! boot (filter |(= :void.jobs/events ($ :name))
                                            instrument/built-ins)))
  (assert (= instrument/queued-in (var-of "void/jobs/state" 'trace-context))
          "obs fills the enqueue-side seam")

  (array/clear spans)
  (def queued
    (trace/with-span "request" {:sampled true}
      (jobstate/enqueue :traced-ping)))
  (assert (trace/parse-traceparent (queued :traceparent))
          "the record remembers the trace it was queued in")

  # the worker: another fiber, and in production another process
  (assert (= 1 (jobworker/drain!)))
  (def js (span-named "job traced-ping"))
  (def req (span-named "request"))
  (assert js)
  (assert (= (req :trace-id) (js :trace-id))
          "a request that queued and a worker that ran it are one trace, not two nobody can join")
  (assert (= (req :span-id) (js :parent-id)))
  (assert (js :remote) "joined through the header, not through a shared fiber")

  (instrument/remove! on)
  (assert (nil? (var-of "void/jobs/state" 'trace-context)))
  (assert (nil? ((jobstate/enqueue :traced-ping) :traceparent))
          "and with nothing tracing, a record carries no trace context"))

# nothing to read the span, nothing built
(array/clear spans)
(trace/set-exporters! [])
(set trace/enabled false)
(assert (not (trace/consuming?)))
(assert (= :ok (instrument/traced-command "PING" (fn [] :ok))))
(assert (empty? spans)
        "with tracing off the wrapper is the work itself — no span, no ids, no attribute table")

(print "instrument-test ok")
