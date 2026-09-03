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
(require "void/cache/init")
(require "void/db/init")
(require "void/db-sqlite/init")

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

(print "instrument-test ok")
