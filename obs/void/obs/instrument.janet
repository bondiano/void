### void/obs/instrument — auto-instrumentation (SPEC.md §5.13,
### ROADMAP 3.1).
###
### An instrumentation is a contribution to `:void.obs/instrument`:
###
###     {:name    :void.db/pool
###      :needs   [:db/pool]        # component keys or interfaces
###      :install (fn [boot pool] ...)   # -> a teardown thunk, or nil
###      :doc     "..."}
###
### It is applied at `:after-start`, when the components it names are
### running, and its teardown runs at `:before-stop`. The instances it
### is handed are the ones running *then*; an instrumentation whose
### numbers must survive a `system/restart` (the dev reload path,
### ADR-0002) should resolve the component when it reads instead of
### capturing it — the built-ins below do, and `reader` is where that
### happens. A named component that is not in this composition means
### the instrumentation is *skipped*, quietly: "observe the database if
### there is one" is the whole point of an auto-instrumentation, and a
### boot that fails because obs is present and Postgres is not would
### be an anti-feature.
###
### **Why the built-in instrumentations live here and not in the
### packages they observe.** SPEC §5.13 sketches every plugin
### registering its own (`:void.obs/instrument [redis-instrumentation]`
### in void/redis's manifest), and that is right for a plugin written
### after obs exists. It cannot be right for the wave-2 packages: a
### contribution to a point *no active plugin owns* is a boot error by
### design (SPEC part II §1.2 — contributions may not dangle), so
### void/db contributing to an obs point would break every application
### that does not run obs. The dependency cannot go the other way
### either: `import void/db` in obs would drag a database into a
### process that only wanted a /metrics endpoint.
###
### So obs reaches the other way round — through the component
### instance the system already has, and through the *public* stats
### function of the owning package, resolved with `require` at install
### time. A package that is not on this process's module path resolves
### to nil and its instrumentation is skipped; a package that is there
### keeps ownership of what its numbers mean, because obs calls the
### same function its own `:health` does. When a wave-3+ plugin ships
### with obs in mind, it contributes to the point directly and none of
### this applies to it.
###
### **Durations are converted here.** The pools count microseconds
### internally; Prometheus base units are seconds, and the conversion
### belongs at the one seam where an external number becomes a metric.

(import void/core/log :as log)
(import void/core/hooks :as hooks)
(import void/core/system :as system)
(import ./metrics :as metrics)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.obs.instrument")

(defn- module-fn
  ``The public binding `name` of module `path`, or nil when that
  package is not on this process's module path. This is the seam that
  keeps obs free of a dependency on the packages it instruments (see
  the module docstring).``
  [path name]
  (def [ok env] (protect (require path)))
  (when ok (get-in env [name :value])))

(defn- instance-of
  "The running instance behind a component key or interface, or nil
  when this composition has none (or it is not running)."
  [boot ref]
  (def [ok inst] (protect (system/instance (boot :system) ref)))
  (when ok inst))

(defn- reader
  ``A thunk returning the stats dictionary, or nil when it cannot be
  read.

  The component is resolved **at collect time**, not captured at
  install time: `system/restart` (the dev reload path, ADR-0002)
  replaces the instance, and a collector holding the old one would go
  on reporting a pool that has been closed. A resolution per metric
  per scrape is a table lookup every fifteen seconds.

  A stats call that throws yields no series rather than a failed
  scrape — an instrumented pool that starts misbehaving must not take
  /metrics down with it.``
  [boot ref f &opt pick]
  (fn read-stats []
    (when-let [inst (instance-of boot ref)]
      (def target (if pick (pick inst) inst))
      (when target
        (def [ok s] (protect (f target)))
        (when (and ok (dictionary? s)) s)))))

(defn- from
  "A collector reading `key` out of a stats reader; nil (an absent
  key) becomes no series rather than a zero."
  [read key &opt scale]
  (fn collect []
    (when-let [s (read)]
      (def v (get s key))
      (when (number? v) (if scale (* scale v) v)))))

(def- us->s
  "Microseconds to seconds — the pools count the first, Prometheus
  wants the second."
  0.000001)

# -- void/db -------------------------------------------------------------

(def db-pool-size (metrics/gauge :void.db/pool-size {:doc "Configured connection pool size"}))
(def db-pool-open (metrics/gauge :void.db/pool-connections {:doc "Connections the pool has created"}))
(def db-pool-in-use (metrics/gauge :void.db/pool-in-use {:doc "Connections checked out right now"}))
(def db-pool-idle (metrics/gauge :void.db/pool-idle {:doc "Connections idle in the pool"}))
(def db-pool-waiting (metrics/gauge :void.db/pool-waiting {:doc "Fibers parked waiting for a connection"}))
(def db-checkouts (metrics/counter :void.db/pool-checkouts-total {:doc "Connection checkouts"}))
(def db-waits (metrics/counter :void.db/pool-waits-total {:doc "Checkouts that had to wait for a connection"}))
(def db-wait-seconds (metrics/counter :void.db/pool-wait-seconds-total {:doc "Total time fibers spent waiting for a connection"}))
(def db-timeouts (metrics/counter :void.db/pool-timeouts-total {:doc "Checkouts that gave up at :checkout-timeout"}))
(def db-queries (metrics/counter :void.db/queries-total {:doc "Statements executed"}))
(def db-query-seconds (metrics/counter :void.db/query-seconds-total {:doc "Total time spent executing statements"}))

(def- db-metrics
  [[db-pool-size :size] [db-pool-open :created] [db-pool-in-use :in-use]
   [db-pool-idle :idle] [db-pool-waiting :waiting]
   [db-checkouts :checkouts] [db-waits :waits]
   [db-wait-seconds :wait-us us->s] [db-timeouts :timeouts]
   [db-queries :queries] [db-query-seconds :query-us us->s]])

# -- void/redis ----------------------------------------------------------

(def redis-pool-size (metrics/gauge :void.redis/pool-size {:doc "Configured connection pool size"}))
(def redis-pool-open (metrics/gauge :void.redis/pool-connections {:doc "Connections the pool has created"}))
(def redis-pool-in-use (metrics/gauge :void.redis/pool-in-use {:doc "Connections checked out right now"}))
(def redis-pool-idle (metrics/gauge :void.redis/pool-idle {:doc "Connections idle in the pool"}))
(def redis-pool-waiting (metrics/gauge :void.redis/pool-waiting {:doc "Fibers parked waiting for a connection"}))
(def redis-checkouts (metrics/counter :void.redis/pool-checkouts-total {:doc "Connection checkouts"}))
(def redis-waits (metrics/counter :void.redis/pool-waits-total {:doc "Checkouts that had to wait for a connection"}))
(def redis-wait-seconds (metrics/counter :void.redis/pool-wait-seconds-total {:doc "Total time fibers spent waiting for a connection"}))
(def redis-timeouts (metrics/counter :void.redis/pool-timeouts-total {:doc "Checkouts that gave up at :checkout-timeout"}))
(def redis-commands (metrics/counter :void.redis/commands-total {:doc "Commands executed"}))
(def redis-command-seconds (metrics/counter :void.redis/command-seconds-total {:doc "Total time spent executing commands"}))
(def redis-reconnects (metrics/counter :void.redis/reconnects-total {:doc "Connections reopened after a broken socket"}))

(def- redis-metrics
  [[redis-pool-size :size] [redis-pool-open :created] [redis-pool-in-use :in-use]
   [redis-pool-idle :idle] [redis-pool-waiting :waiting]
   [redis-checkouts :checkouts] [redis-waits :waits]
   [redis-wait-seconds :wait-us us->s] [redis-timeouts :timeouts]
   [redis-commands :commands] [redis-command-seconds :command-us us->s]
   [redis-reconnects :reconnects]])

# -- void/cache ----------------------------------------------------------

(def cache-hits (metrics/counter :void.cache/hits-total {:doc "Cache lookups that found a live entry"}))
(def cache-misses (metrics/counter :void.cache/misses-total {:doc "Cache lookups that did not"}))
(def cache-puts (metrics/counter :void.cache/puts-total {:doc "Entries written"}))
(def cache-deletes (metrics/counter :void.cache/deletes-total {:doc "Entries deleted"}))
(def cache-errors (metrics/counter :void.cache/errors-total {:doc "Store failures the cache degraded to a miss"}))
(def cache-flight-waits (metrics/counter :void.cache/single-flight-waits-total {:doc "Fibers that waited on another fiber's computation instead of repeating it"}))
(def cache-entries (metrics/gauge :void.cache/entries {:doc "Entries the store holds (where it counts them)"}))
(def cache-evictions (metrics/counter :void.cache/evictions-total {:doc "Entries evicted to stay under the size cap"}))
(def cache-expirations (metrics/counter :void.cache/expirations-total {:doc "Entries dropped because their TTL ran out"}))

(def- cache-metrics
  [[cache-hits :hits] [cache-misses :misses] [cache-puts :puts]
   [cache-deletes :deletes] [cache-errors :errors]
   [cache-flight-waits :flight-waits] [cache-entries :size]
   [cache-evictions :evictions] [cache-expirations :expirations]])

# -- void/jobs -----------------------------------------------------------

(def job-events
  "Job lifecycle events as they happen — the RED of a queue: rate from
  :started, errors from :failed and :dead, and the duration below."
  (metrics/counter :void.jobs/events-total
    {:doc "Job lifecycle events"
     :labels [:event :queue :job]}))

(def job-duration
  "How long jobs take, from :started-at to :finished-at as the record
  itself stamped them."
  (metrics/histogram :void.jobs/duration-seconds
    {:doc "Job execution time in seconds"
     :labels [:queue :job]}))

(def job-queue-delay
  ``How long a job waited before a worker picked it up — the number
  that says whether a queue needs more workers, and the one a job's
  own duration cannot show.``
  (metrics/histogram :void.jobs/queue-delay-seconds
    {:doc "Seconds between a job becoming runnable and a worker starting it"}))

(defn- job-labels [payload]
  [(string (get-in payload [:job :queue] "-"))
   (string (get-in payload [:job :job] "-"))])

(defn job-event!
  "Record one `:void.jobs/event` payload. Public so a test does not
  need a worker to check what the instrumentation counts."
  [payload]
  (def r (get payload :job {}))
  (def [queue job] (job-labels payload))
  (metrics/inc! job-events [(string (payload :event)) queue job])
  (case (payload :event)
    :started
    (let [runnable (or (get r :run-at) (get r :enqueued-at))
          started (get r :started-at)]
      (when (and (number? runnable) (number? started) (>= started runnable))
        (metrics/observe! job-queue-delay nil (- started runnable))))

    (when (in {:completed true :failed true :dead true} (payload :event))
      (let [started (get r :started-at)
            finished (get r :finished-at)]
        (when (and (number? started) (number? finished) (>= finished started))
          (metrics/observe! job-duration [queue job] (- finished started))))))
  nil)

# -- void/http's client --------------------------------------------------
#
# The one instrumentation with no component behind it: a client is a
# module (void/http/client), its counters are process-wide, and there
# is nothing in the system graph to name in `:needs`. It is skipped
# where void/http is not on the module path and installs everywhere
# else — including in a process that only *makes* requests.
#
# The OTLP exporter's own requests are in these numbers. That is not a
# leak to be filtered: they are requests this process made, and an
# exporter hammering a collector is exactly the thing an operator
# wants to see here.

(def client-requests (metrics/counter :void.http/client-requests-total {:doc "Outbound HTTP requests"}))
(def client-responses (metrics/counter :void.http/client-responses-total {:doc "Outbound requests that got an answer"}))
(def client-failures (metrics/counter :void.http/client-failures-total {:doc "Outbound requests that got none"}))
(def client-timeouts (metrics/counter :void.http/client-timeouts-total {:doc "Outbound requests that timed out"}))
(def client-connects (metrics/counter :void.http/client-connects-total {:doc "Connections opened"}))
(def client-reconnects (metrics/counter :void.http/client-reconnects-total {:doc "Sockets reopened after the peer closed an idle keep-alive connection"}))
(def client-seconds (metrics/counter :void.http/client-request-seconds-total {:doc "Total time spent waiting for outbound responses"}))
(def client-bytes-out (metrics/counter :void.http/client-sent-bytes-total {:doc "Bytes written to outbound connections"}))
(def client-bytes-in (metrics/counter :void.http/client-received-bytes-total {:doc "Bytes read from outbound connections"}))

(def- client-metrics
  [[client-requests :requests] [client-responses :responses]
   [client-failures :failures] [client-timeouts :timeouts]
   [client-connects :connects] [client-reconnects :reconnects]
   [client-seconds :request-us us->s]
   [client-bytes-out :bytes-out] [client-bytes-in :bytes-in]])

# -- applying an instrumentation -----------------------------------------

(defn- attach!
  "Point a list of [metric stats-key scale?] triples at one reader.
  Returns the thunk that detaches them again."
  [pairs read]
  (each p pairs
    (metrics/set-collector! (in p 0) (from read (in p 1) (get p 2))))
  (fn detach []
    (each p pairs (metrics/set-collector! (in p 0) nil))))

(def built-ins
  ``The instrumentations obs ships: the wave-2 data plugins, each
  reached through its own public stats function (see the module
  docstring). Every one of them is skipped when its component is not
  in the composition.

  The http-client one is the exception to "each through its
  component": `void/http/client` (ROADMAP 4.1) is a module with
  process-wide counters and nothing in the system graph to name, so it
  needs nothing and installs wherever void/http is on the module path.
  The outbound trace context stays the caller's — `trace/inject!`
  writes `traceparent` into the headers of whatever makes the call.``
  [{:name :void.db/pool
    :doc "Pool occupancy, checkout waits and statement timing from :db/pool"
    :needs [:db/pool]
    :install (fn install-db [boot _]
               (when-let [stats (module-fn "void/db/pool" 'stats)]
                 (attach! db-metrics (reader boot :db/pool stats))))}

   {:name :void.redis/pool
    :doc "Pool occupancy, checkout waits and command timing from :redis/client"
    :needs [:void/redis]
    :install (fn install-redis [boot _]
               (when-let [stats (module-fn "void/redis/pool" 'stats)]
                 (attach! redis-metrics
                          (reader boot :void/redis stats |(get $ :pool)))))}

   {:name :void.cache/store
    :doc "Hit rate, writes and store failures from the :void/cache funnel"
    :needs [:void/cache]
    :install (fn install-cache [boot _]
               (def stats (module-fn "void/cache/state" 'stats))
               (def cache-dyn (module-fn "void/cache/state" 'cache-dyn))
               (when (and stats cache-dyn)
                 (attach! cache-metrics
                          (reader boot :void/cache
                                  (fn cache-stats [cache]
                                    (with-dyns [cache-dyn cache] (stats)))))))}

   {:name :void.http/client
    :doc "Outbound request rate, failures, reconnects and timing from void/http/client"
    :needs []
    :install (fn install-client [boot]
               (when-let [stats (module-fn "void/http/client" 'stats)]
                 (attach! client-metrics
                          # nothing until the process has actually made
                          # a request: a worker that never calls out
                          # should report no series rather than nine
                          # zeros, which is the same bargain `from`
                          # makes for an absent stats key
                          (fn read-client []
                            (let [s (stats)]
                              (when (pos? (get s :requests 0)) s))))))}

   {:name :void.jobs/events
    :doc "Job lifecycle events and execution time, off the :void.jobs/event hook"
    :needs [:void/jobs]
    :install (fn install-jobs [boot _]
               (hooks/add! (boot :hooks) :void.jobs/event
                           (fn obs-job-event [payload] (job-event! payload))
                           :name :obs/jobs
                           :plugin :void/obs
                           :doc "Count job lifecycle events into the obs registry")
               (fn detach-jobs []
                 (hooks/remove! (boot :hooks) :void.jobs/event :obs/jobs)))}])

(defn install!
  ``Apply the instrumentations that can be applied. `contribs` are the
  resolved `:void.obs/instrument` contributions; `wanted`, when it is
  a list of names, keeps only those (config `[:obs :instrument]`).
  Returns the installed entries — {:name :teardown} — for `remove!`.``
  [boot contribs &opt wanted]
  (def keep (when (indexed? wanted) (tabseq [n :in wanted] n true)))
  (def installed @[])
  (each c (or contribs [])
    (when (or (nil? keep) (in keep (c :name)))
      (def needs (get c :needs []))
      (def instances (map |(instance-of boot $) needs))
      (if (some nil? instances)
        (log/debug "instrumentation skipped — its component is not in this composition"
                   :ns log-ns :instrument (c :name)
                   :missing (filter |(nil? (instance-of boot $)) needs))
        (let [[ok teardown] (protect ((c :install) boot ;instances))]
          (if ok
            (do
              (array/push installed {:name (c :name) :teardown teardown})
              (log/debug "instrumentation installed" :ns log-ns :instrument (c :name)))
            (log/warn "instrumentation failed to install" :ns log-ns
                      :instrument (c :name)
                      :err (if (string? teardown) teardown (describe teardown))))))))
  (tuple ;installed))

(defn remove!
  "Run the teardowns of `install!`'s entries — a stopped pool stops
  reporting series rather than reporting the numbers it had when it
  stopped."
  [installed]
  (each e (or installed [])
    (when-let [t (e :teardown)]
      (def [ok err] (protect (t)))
      (unless ok
        (log/warn "instrumentation teardown failed" :ns log-ns
                  :instrument (e :name)
                  :err (if (string? err) err (describe err))))))
  nil)
