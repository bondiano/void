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
  "Default of [:pressure :db-pool-max-waiting] — waiters on an
  exhausted pool at or above which the clock starts. One: a single
  parked fiber already means every connection is checked out."
  1)

(def default-wait-grace
  ``Default of [:pressure :db-pool-wait-grace], in seconds. The pool's
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
  [s max-waiting grace since now]
  (def waiting (get s :waiting 0))
  (if (and (pos? max-waiting) (>= waiting max-waiting))
    (let [t0 (or since now)
          held (- now t0)]
      [(if (>= held grace)
         {:ok false
          :reason (string/format
                    "db pool exhausted: %d waiting for %.1f s (size %d, in use %d, %d timeouts)"
                    waiting held (get s :size 0) (get s :in-use 0)
                    (get s :timeouts 0))}
         {:ok true})
       t0])
    [{:ok true} nil]))

(defn make-db-pool-check
  ``A pool-exhaustion check over `read-stats`, a thunk returning a
  `pool/stats`-shaped dictionary or nil (nil answers `{:ok true}`).
  `opts` may fix `:max-waiting` and `:grace`; without them the
  defaults above apply. This is the seam for a test — and for an
  application with a second pool to watch: register the result with
  `add-check!` or a `:void.pressure/check` contribution of its own.``
  [read-stats &opt opts]
  (default opts {})
  (var since nil)
  (fn db-pool-check []
    (if-let [s (read-stats)]
      (let [[r t0] (evaluate s
                             (get opts :max-waiting default-max-waiting)
                             (get opts :grace default-wait-grace)
                             since (os/clock :monotonic))]
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

(defn- db-pool-stats
  "This process's `:db/pool` stats, or nil when there is no void/db,
  no running boot, or no pool in this composition — all resolved per
  call, never captured."
  []
  (when-let [stats (module-fn "void/db/pool" 'stats)
             boot plugin/current-boot
             sys (get boot :system)]
    (def [ok pool] (protect (system/instance sys :db/pool)))
    (when (and ok pool)
      (def [ok-s s] (protect (stats pool)))
      (when (and ok-s (dictionary? s)) s))))

(defn- limit
  "A numeric [:pressure] config value off the active state, else the
  default — the state a check runs against is the one that holds the
  slice its thresholds came from."
  [key dflt]
  (def v (get-in (or (state/active) {}) [:config key]))
  (if (number? v) v dflt))

(var- exhausted-since
  "When the built-in first saw the pool exhausted (monotonic), nil
  while it is not — the grace period's memory, one per process like
  the pool it watches."
  nil)

(def db-pool-contribution
  "The `:void.pressure/check` contribution void/pressure ships:
  `:db/pool` exhausted with fibers waiting longer than the grace
  period is one more reason to shed."
  {:name :void.db/pool
   :doc "Shed while :db/pool is exhausted and fibers have waited longer than [:pressure :db-pool-wait-grace] seconds; skipped where there is no pool"
   :fn (fn db-pool-pressure []
         (if-let [s (db-pool-stats)]
           (let [[r t0] (evaluate s
                                  (limit :db-pool-max-waiting default-max-waiting)
                                  (limit :db-pool-wait-grace default-wait-grace)
                                  exhausted-since (os/clock :monotonic))]
             (set exhausted-since t0)
             r)
           (do (set exhausted-since nil) {:ok true})))})
