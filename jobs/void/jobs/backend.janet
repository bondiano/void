### void/jobs/backend — the :void/jobs-backend contract (SPEC.md
### §5.12, ADR-0012).
###
### A backend is a plain dictionary produced by a backend component's
### :start (the component declares :provides [:void/jobs-backend], so
### the config picks the implementation and the runtime never names
### one). It answers eight questions, and every one of them is about
### *storage* — nothing about retries, priorities or timeouts lives
### here, because those are decisions, and decisions belong to the
### runtime that every backend shares:
###
###   :push!    (fn [job] job-or-nil)   store a new record; nil when a
###                                     unique key is already held
###   :claim!   (fn [opts] job-or-nil)  atomically take the next
###                                     runnable record and mark it
###                                     :running — see below
###   :settle!  (fn [job] job)          write a record back in the
###                                     state the runtime put it in,
###                                     releasing the claim and the
###                                     unique key when it is done
###   :fetch    (fn [id] job-or-nil)
###   :list     (fn [opts] [job ...])   {:queue :state :job :parent
###                                     :limit}
###   :counts   (fn [] {queue {state n}})
###   :remove!  (fn [id] removed?)
###   :clear!   (fn [opts] n)           {:queue :state}, everything
###                                     when neither is given
###
### `claim!` is the only one that has to be atomic, and it is the whole
### reason a backend exists rather than a table: two workers asking at
### the same moment must not get the same record. opts:
###
###   :queues       the queues this worker serves, most-wanted first
###   :now          the clock the worker is reading
###   :token        who is claiming (a worker id — what `reap!` uses
###                 to tell a dead claim from a live one)
###   :skip-groups  group keys already at their concurrency cap, which
###                 is how fair scheduling between tenants is spelled
###   :priority-key not passed: ordering is the backend's job, and it
###                 is always (priority asc, run-at asc, id asc)
###
### Optional keys, each with a documented fallback so that a backend
### can start as eight functions:
###
###   :reap!            (fn [opts] [job ...]) — {:now :ttl :token
###                     :limit}: claims older than the ttl are taken
###                     over by this worker (re-tokened, still
###                     :running) and handed back for it to settle
###                     through the ordinary failure path. Without it a
###                     worker killed mid-job leaves that job :running
###                     for good
###   :lock! / :unlock! (fn [name ttl token] got?) — the cross-process
###                     lock `defschedule` needs to fire once per slot
###                     across a fleet. Falls back to an in-process
###                     lock, which is correct for exactly one process
###   :rate-take!       (fn [queue limit duration now] wait-seconds) — a
###                     shared rate limiter. Falls back to an
###                     in-process one: the limit then holds per worker
###                     process, not per fleet, and `capabilities` says
###                     so out loud
###   :touch!           (fn [ids now] n) — refresh the claims a worker
###                     is still working on, so that a job slower than
###                     the claim ttl is not reaped out from under it.
###                     Without it, [:jobs :claim-ttl] has to exceed
###                     the slowest job, and the worker says so at boot
###   :release-parent!  (fn [child] parent-or-nil) — flows. A backend
###                     without it refuses flows at enqueue rather than
###                     losing the parent
###   :stats / :close
###
### `normalize` validates a backend and fills the fallbacks in, so the
### runtime can call every key unconditionally — the same shape
### void/db/driver and void/cache/store have, for the same reason.

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(def- required
  [:push! :claim! :settle! :fetch :list :counts :remove! :clear!])

(def- optional
  [:reap! :touch! :lock! :unlock! :rate-take! :release-parent! :stats :close])

# -- the in-process fallbacks -------------------------------------------

(defn local-rate-limiter
  ``A fixed-window rate limiter in this process's heap: the fallback
  for a backend that has no shared counter. Returns 0 when the call
  may proceed (having counted it) and otherwise the seconds until the
  window closes.

  Fixed windows admit up to 2 × max across a window boundary, and that
  is the honest trade against a sliding window that would need a
  sorted set per queue. For "do not hammer the payment provider" it is
  the right shape; for a hard contractual ceiling, halve the number.``
  []
  (def windows @{})
  # `limit`, not `max`: the parameter would shadow the function this
  # very body needs two lines further down
  (fn take [queue limit duration now]
    (if (or (nil? limit) (nil? duration) (<= limit 0) (<= duration 0))
      0
      (do
        (def start (* duration (math/floor (/ now duration))))
        (def w (get windows queue))
        (def cur (if (and w (= start (w :start))) w
                   (let [fresh @{:start start :n 0}]
                     (put windows queue fresh)
                     fresh)))
        (if (< (cur :n) limit)
          (do (put cur :n (inc (cur :n))) 0)
          (max 0.001 (- (+ start duration) now)))))))

(defn local-locks
  ``Named leases in this process's heap: the fallback for a backend
  with no shared lock. A schedule guarded by one fires once per slot
  *per process*, which is right for a single process and wrong for a
  fleet — which is why `capabilities` reports :locks :process and the
  scheduler logs it at boot.``
  []
  (def held @{})
  {:lock! (fn lock [name ttl token now]
            (def cur (get held name))
            (if (and cur (> (cur :until) now) (not= token (cur :token)))
              false
              (do (put held name @{:token token :until (+ now ttl)}) true)))
   :unlock! (fn unlock [name token]
              (when-let [cur (get held name)]
                (when (= token (cur :token))
                  (put held name nil)
                  true)))})

# -- normalization -------------------------------------------------------

(defn normalize
  ``Validate a backend dictionary and fill in the documented
  fallbacks. Returns the completed backend; throws with the offending
  key on any contract violation.``
  [b]
  (unless (dictionary? b)
    (errorf "jobs backend must be a dictionary, got %q" b))
  (def name (get b :name :anonymous))
  (each k required
    (unless (callable? (get b k))
      (errorf "jobs backend %q: %q must be a function, got %q" name k (get b k))))
  (each k optional
    (when-let [f (get b k)]
      (unless (callable? f)
        (errorf "jobs backend %q: %q must be a function, got %q" name k f))))
  (def locks (local-locks))
  (table/to-struct
    (merge
      @{:name name
        # a backend several processes see; false means "this heap only",
        # which changes what a rate limit and a schedule lock mean
        :shared? false
        :reap! nil
        :touch! nil
        :release-parent! nil
        :rate-take! (local-rate-limiter)
        :lock! (locks :lock!)
        :unlock! (locks :unlock!)
        :shared-rate? false
        :shared-locks? false
        :stats (fn no-stats [] {})
        :close (fn no-close [] nil)}
      b
      # whether the *shared* variants are the ones in use is derived,
      # never declared: a backend cannot be wrong about it by accident
      @{:shared-rate? (truthy? (get b :rate-take!))
        :shared-locks? (truthy? (and (get b :lock!) (get b :unlock!)))})))

(defn supports-flows?
  "True when the backend can hold a parent until its children finish."
  [b]
  (truthy? (get b :release-parent!)))

(defn supports-reaping?
  "True when the backend can return an abandoned claim to the queue."
  [b]
  (truthy? (get b :reap!)))

(defn supports-heartbeat?
  "True when a worker can keep a long job's claim alive."
  [b]
  (truthy? (get b :touch!)))

(defn capabilities
  ``What this backend actually provides, as data — what `void jobs
  stats` prints and what the worker logs at boot, so that "the rate
  limit is per process" is something an operator reads rather than
  discovers.``
  [b]
  {:name (b :name)
   :shared (truthy? (get b :shared?))
   :flows (supports-flows? b)
   :reaping (supports-reaping? b)
   :heartbeat (supports-heartbeat? b)
   :rate-limit (if (b :shared-rate?) :shared :process)
   :locks (if (b :shared-locks?) :shared :process)})

(defn require-flows!
  "Throw unless the backend can hold flow parents — named, so that the
  error says which backend and what to switch to."
  [b]
  (unless (supports-flows? b)
    (errorf "the %q jobs backend cannot hold a flow parent: it has no :release-parent!. Flows need a backend that can (the in-process, db and redis backends all do)"
            (b :name)))
  true)
