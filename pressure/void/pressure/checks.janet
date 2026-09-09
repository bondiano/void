### void/pressure/checks — the built-in `:void.pressure/check`
### contributions.
###
### The module docstring of init.janet names an exhausted database pool as
### the motivating example of a check, and this is where that example
### stops being prose. It cannot live in void/db: a contribution to a
### point no active plugin owns is a boot error by design, so void/db
### contributing here would break every application that composes a
### database without the shedder. void/pressure owns the point, so its own
### contribution can never dangle — the same reasoning that puts the
### wave-2 instrumentations inside void/obs (obs/instrument.janet).
###
### And like those, this check reaches the pool the long way round: the
### *public* stats function of void/db/pool, resolved with `require` at
### check time, and the `:db/pool` instance of the running system,
### resolved per call rather than captured — a `system/restart` (the dev
### reload path) must not leave the check watching a pool that has been
### closed. A process without void/db on its module path, or a composition
### without a `:db/pool` component, answers `{:ok true}`: "shed on the
### database if there is one" is the whole point.
###
### Two are shipped — `:db/pool` and `:void/redis`'s pool — and they
### are one function twice: a redis pool runs out of connections
### exactly the way a database pool does, and the reason string is the
### only thing that differs.
###
### The decision itself has a grace period instead of hysteresis. A
### burst that parks a fiber for one sample is the pool doing its job —
### back-pressure, not overload; a pool that *stays* exhausted with
### fibers waiting is a process about to time those fibers out at
### `:checkout-timeout`, and shedding new work before that happens is
### cheaper than accepting requests that will spend their budget in a
### queue. So the check trips only after the exhaustion has held for
### `:db-pool-wait-grace` seconds without a break.

(import void/core/system :as system)
(import void/core/plugin :as plugin)
(import ./state :as state)

(def default-max-waiting
  "Default of [:pressure :db-pool-max-waiting] and its redis twin —
  waiters on an exhausted pool at or above which the clock starts.
  One: a single parked fiber already means every connection is checked
  out."
  1)

(def default-wait-grace
  ``Default of [:pressure :db-pool-wait-grace] and its redis twin, in
  seconds. The pool's
  own :checkout-timeout defaults to 5 s; shedding at 2 means the
  process starts refusing new work while the fibers already queued
  still have a chance, instead of discovering the exhaustion by
  watching them time out.``
  2)

(defn evaluate
  ``The decision, as a pure function: `[result since']` from one stats
  reading. `since` is when the exhaustion was first seen (nil when it
  was not), `now` the current monotonic clock; the caller keeps
  `since'` for the next call. The result is what a check answers —
  `{:ok true}` or `{:ok false :reason ...}`.``
  [s max-waiting grace since now &opt label]
  (def waiting (get s :waiting 0))
  (if (and (pos? max-waiting) (>= waiting max-waiting))
    (let [t0 (or since now)
          held (- now t0)]
      [(if (>= held grace)
         {:ok false
          :reason (string/format
                    "%s exhausted: %d waiting for %.1f s (size %d, in use %d, %d timeouts)"
                    (or label "pool") waiting held
                    (get s :size 0) (get s :in-use 0) (get s :timeouts 0))}
         {:ok true})
       t0])
    [{:ok true} nil]))

(defn make-pool-check
  ``A pool-exhaustion check over `read-stats`, a thunk returning a
  `pool/stats`-shaped dictionary or nil (nil answers `{:ok true}`).
  `opts` may fix `:max-waiting`, `:grace` and the `:label` the reason
  names the pool by; without them the defaults above apply. This is
  the seam for a test — and for an application with a pool of its own
  to watch: register the result with `add-check!` or a
  `:void.pressure/check` contribution.

  Any pool of void/core/pool's shape fits, which is why the two this
  package ships are one function and not two: a redis pool runs out of
  connections exactly the way a database pool does, and a process that
  keeps timing fibers out at `:checkout-timeout` is overloaded either
  way.``
  [read-stats &opt opts]
  (default opts {})
  (var since nil)
  (fn pool-check []
    (if-let [s (read-stats)]
      (let [[r t0] (evaluate s
                             (get opts :max-waiting default-max-waiting)
                             (get opts :grace default-wait-grace)
                             since (os/clock :monotonic)
                             (get opts :label "pool"))]
        (set since t0)
        r)
      (do (set since nil) {:ok true}))))

# -- the built-in: this process's :db/pool -------------------------------

(defn- module-fn
  "The public binding `name` of module `path`, or nil when that
  package is not on this process's module path (the seam that keeps
  void/pressure free of a dependency on void/db — see the module
  docstring)."
  [path name]
  (def [ok env] (protect (require path)))
  (when ok (get-in env [name :value])))

(defn- pool-stats-reader
  ``A thunk answering the stats of the `component` pool through
  `module`'s public `stats`, or nil when the package is not on this
  process's module path, no boot is running, or this composition has
  no such component. `pick` reaches the pool inside a component that
  holds one (void/redis's client does).

  Everything is resolved per call and nothing is captured: a
  `system/restart` (the dev reload path) must not leave a check
  watching a pool that has been closed.``
  [module component &opt pick]
  (fn read-pool-stats []
    (when-let [stats (module-fn module 'stats)
               boot (plugin/running-boot)
               sys (get boot :system)]
      (def [ok inst] (protect (system/instance sys component)))
      (when (and ok inst)
        (def pool (if pick (pick inst) inst))
        (when pool
          (def [ok-s s] (protect (stats pool)))
          (when (and ok-s (dictionary? s)) s))))))

(defn- limit
  "A numeric [:pressure] config value off the active state, else the
  default — the state a check runs against is the one that holds the
  slice its thresholds came from."
  [key dflt]
  (def v (get-in (or (state/active) {}) [:config key]))
  (if (number? v) v dflt))

(defn- pool-contribution
  ``One shipped check over one pool: the reader above, the thresholds
  off the active state's config (so a check runs against the slice its
  numbers came from), and the grace period's memory — one var per
  contribution, like the pool each watches.``
  [name label read-stats max-key grace-key]
  (var exhausted-since nil)
  {:name name
   :doc (string/format
          "Shed while %s is exhausted and fibers have waited longer than [:pressure %s] seconds; skipped where there is no such pool"
          label grace-key)
   :fn (fn pool-pressure []
         (if-let [s (read-stats)]
           (let [[r t0] (evaluate s
                                  (limit max-key default-max-waiting)
                                  (limit grace-key default-wait-grace)
                                  exhausted-since (os/clock :monotonic)
                                  label)]
             (set exhausted-since t0)
             r)
           (do (set exhausted-since nil) {:ok true})))})

(def db-pool-contribution
  "The `:void.pressure/check` contribution void/pressure ships for the
  database: `:db/pool` exhausted with fibers waiting longer than the
  grace period is one more reason to shed."
  (pool-contribution :void.db/pool "db pool"
                     (pool-stats-reader "void/db/pool" :db/pool)
                     :db-pool-max-waiting :db-pool-wait-grace))

(def redis-pool-contribution
  ``The same for redis. A cache or a session store that has run out of
  connections is the same overload as a database that has: fibers
  parked, `:checkout-timeout` about to fire, and a process that would
  do better refusing new work than accepting requests it will time out
  on. `:void/redis` is the interface, so a composition that swapped
  the client keeps the check.``
  (pool-contribution :void.redis/pool "redis pool"
                     (pool-stats-reader "void/redis/pool" :void/redis
                                        |(get $ :pool))
                     :redis-pool-max-waiting :redis-pool-wait-grace))
