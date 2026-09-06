### void/core/pool — a fiber-aware resource pool.
###
### The one pool void/db and void/redis run on. Each package used to
### carry its own 230-line copy, and each copy got a different fix —
### the cancellation-proof handoff landed in db, the cleanliness check
### in redis — which is the case for a kernel with adapters over it
### (ROADMAP 8.3). The pool knows nothing about connections: it is
### handed how to make one, how to close one, and two questions — is
### an idle one still good before it goes out (`:validate`), is a
### returned one safe for the next owner (`:reusable?`) — and it
### manages the rest: lazy creation up to `:size`, FIFO handoff to
### parked fibers, a checkout deadline that never touches the caller's
### root task, and the counters void/obs exports.
###
### Checkout beyond capacity parks the fiber on its own waiter channel
### with a deadline, so a saturated pool back-pressures request fibers
### instead of stacking resources. Release hands the resource to the
### oldest live waiter directly (FIFO — no thundering herd) and only
### falls back to the idle stack when nobody waits.
###
### The wait deadline runs in a child task, never `ev/with-deadline` on
### the caller: that cancels the *root task*, which for a request fiber
### is the whole request (the bug class documented in http/server
### run-handler). The resource itself never travels through the
### waiter's channel: `release` writes it into the waiter record and
### the channel carries only a wake-up. A value given to a parked
### `ev/take` sits in the run queue until the taker runs, and a cancel
### queued ahead of it supersedes it — so a resource in flight on the
### channel would be lost whenever the waiter's caller was cancelled
### while a release was already scheduled (a request deadline firing
### under pool saturation). With the handover in the record, a
### cancelled wake-up costs nothing: the waiter's exit reads the
### record and rehomes what it finds, deterministically.
###
###     (def p (pool/make {:name "db"
###                        :connect (fn [] (open-a-connection))
###                        :close   (fn [c] (close-it c))
###                        :reusable? (fn [c] (not (mid-protocol? c)))
###                        :size 10 :checkout-timeout 5
###                        :timeout-kind :void.db/pool-timeout
###                        :counters {:queries 0 :query-us 0}}))
###     (pool/with p (fn [c] ...))            ; acquire, run, release
###     (pool/note! p :queries 1 :query-us 120)
###     (pool/stats p)                        ; -> {:size :created :in-use :idle :waiting
###                                           ;     :checkouts :waits :wait-us :timeouts
###                                           ;     :queries :query-us}

(import ./errors :as errors)
(import ./deadline :as deadline)

(errors/define! :void.core/pool-timeout
  {:status 503 :doc "no pooled resource became free within :checkout-timeout"})
(errors/define! :void.core/pool-closed
  {:status 503 :doc "the pool was closed (the component stopped) and refuses checkouts"})

(def- retry
  "Handover marker: the pool state changed (a slot was freed, or the
  pool closed) — the waiter re-enters `acquire` and decides again."
  :void.core.pool/retry)

(defn- always-reusable
  "The default `:reusable?`: a resource comes back as good as it went out."
  [_]
  true)

(defn make
  ``Build a pool. `opts`:

    :connect          (fn [] resource) — opens one; may throw, and the
                      error reaches the fiber that asked (the slot is
                      released first). Required.
    :close            (fn [resource]) — closes one; called under
                      `protect`, on the idle stack at `close!`, and on
                      any resource the pool will not reuse. Required.
    :reusable?        (fn [resource] bool) — asked at every `release`:
                      a resource that says no (or throws) is closed,
                      not handed to the next owner. This is also how
                      an owner discards one on purpose (a failed
                      ROLLBACK): mark it, and answer no. Default:
                      always.
    :validate         (fn [resource] truthy) — asked of an *idle*
                      resource before it goes out: falsy means it died
                      while it sat (closed; the checkout decides again
                      with the slot freed — the next idle one first, a
                      fresh one only when none is left); a throw closes
                      it and reaches the caller. Default: none.
    :size             resources at most (default 10).
    :checkout-timeout seconds a checkout waits for a free resource
                      (default 5).
    :name             what the resource is called in messages
                      (default "resource").
    :timeout-kind     the error kind a timed-out checkout raises
                      (default :void.core/pool-timeout).
    :counters         the owner's own counters, with their zero values
                      ({:queries 0 ...}); `note!` adds to them and
                      `stats` reports them alongside the pool's.``
  [opts]
  (unless (function? (get opts :connect))
    (errorf "pool/make: :connect must be a function, got %q" (get opts :connect)))
  (unless (function? (get opts :close))
    (errorf "pool/make: :close must be a function, got %q" (get opts :close)))
  @{:connect (opts :connect)
    :close (opts :close)
    :reusable? (get opts :reusable? always-reusable)
    :validate (get opts :validate)
    :name (get opts :name "resource")
    :timeout-kind (get opts :timeout-kind :void.core/pool-timeout)
    :size (get opts :size 10)
    :checkout-timeout (get opts :checkout-timeout 5)
    :idle @[]
    :waiters @[]
    :created 0
    :in-use 0
    :closed false
    :stats (merge @{:checkouts 0 :waits 0 :wait-us 0 :timeouts 0}
                  (get opts :counters {}))})

(defn note!
  ``Add to the owner's counters: `(pool/note! p :queries 1 :query-us
  us)`. A counter not declared in `:counters` starts at zero.``
  [pool & kvs]
  (def s (pool :stats))
  (each [k n] (partition 2 kvs)
    (put s k (+ n (get s k 0))))
  nil)

(defn closed?
  "Has `close!` been called on this pool?"
  [pool]
  (truthy? (pool :closed)))

(defn- live-waiters
  "How many fibers are parked on the pool right now."
  [pool]
  (count |($ :live) (pool :waiters)))

(defn- close-resource
  "Close a resource and free its slot. The `:close` hook runs under
  `protect`: a resource that fails to close is still gone."
  [pool res]
  (protect ((pool :close) res))
  (put pool :created (dec (pool :created)))
  nil)

(defn- connect-resource
  "Open a resource in a free slot. The slot is reserved first — a
  failing `:connect` must release it, or the pool shrinks by one for
  good each time the server is unreachable."
  [pool]
  (put pool :created (inc (pool :created)))
  (def [ok res] (protect ((pool :connect))))
  (unless ok
    (put pool :created (dec (pool :created)))
    (error res))
  res)

(defn- take-idle
  "Pop the newest idle resource and put it through `:validate`. Returns
  the resource, or nil when it had died on the stack (it is closed and
  the caller decides again with the slot freed); a validation that
  throws closes it and propagates."
  [pool]
  (def res (array/pop (pool :idle)))
  (def validate (pool :validate))
  (if (nil? validate)
    res
    (let [[ok v] (protect (validate res))]
      (cond
        (and ok v) res
        ok (do (close-resource pool res) nil)
        (do (close-resource pool res) (error v))))))

(def- wake
  "Wake-up marker: a release wrote a resource into the waiter record."
  :void.core.pool/wake)

(defn- wait-for-wake-up
  ``Park on the waiter's channel under the checkout timeout without
  touching the caller's root task: the take runs in a supervised child
  task. Returns the marker taken (`wake` or `retry`), or nil on a
  timeout. The child is cancelled on any non-normal exit of the caller
  (a cancelled checkout), so no orphaned taker is ever left parked on
  the channel. What the child takes is only ever a marker: the
  resource is in the waiter record, and a cancel that supersedes the
  child's scheduled value (see the module docstring) loses nothing
  `await`'s exit cannot recover.``
  [waiter timeout]
  (deadline/call timeout
                 (fn waiter-task [] (ev/take (waiter :chan)))
                 (fn [] nil)))

(defn- next-waiter
  "Pop the oldest waiter still parked (dropping any left non-live)."
  [pool]
  (def ws (pool :waiters))
  (var found nil)
  (while (and (nil? found) (not (empty? ws)))
    (def w (in ws 0))
    (array/remove ws 0)
    (when (w :live) (set found w)))
  found)

(defn- wake-one
  "Tell the oldest waiter that a slot was freed, so it opens a fresh
  resource instead of parking until the timeout."
  [pool]
  (when-let [w (next-waiter pool)]
    (ev/give (w :chan) retry))
  nil)

(defn- wake-all
  "Tell every parked waiter that the pool state changed (it closed)."
  [pool]
  (var w (next-waiter pool))
  (while w
    (ev/give (w :chan) retry)
    (set w (next-waiter pool)))
  nil)

(defn- reusable?
  "Does the owner's `:reusable?` accept the resource back? A hook that
  throws has answered."
  [pool res]
  (def [ok v] (protect ((pool :reusable?) res)))
  (and ok v true))

(defn release
  ``Return a resource: to the oldest waiter if any, else the idle
  stack — or closed, when `:reusable?` says no or the pool is shutting
  down. Asking on every return is what makes the owner's discard
  promise hold on every path: a checkout cancelled mid-reply or
  abandoned inside a transaction comes back through here like any
  other, and the next owner must get a resource, not a crime scene.``
  [pool res]
  (put pool :in-use (dec (pool :in-use)))
  (cond
    (or (pool :closed) (not (reusable? pool res)))
    (do (close-resource pool res)
        (wake-one pool))

    (if-let [w (next-waiter pool)]
      # the record is the handover, the channel only the doorbell: a
      # resource given to the channel would sit in the run queue, where
      # a cancel of the waiter queued before us supersedes it
      (do (put w :value res)
          (ev/give (w :chan) wake))
      (array/push (pool :idle) res)))
  nil)

(defn- timeout!
  "Count the timeout and raise the pool's `:timeout-kind`."
  [pool]
  (def s (pool :stats))
  (put s :timeouts (inc (s :timeouts)))
  (errors/raise (pool :timeout-kind)
                (string/format "%s pool checkout timed out after %.1fs (size %d, in use %d, waiting %d)"
                               (pool :name) (pool :checkout-timeout) (pool :size)
                               (pool :in-use) (live-waiters pool))
                {:timeout (pool :checkout-timeout) :size (pool :size)
                 :in-use (pool :in-use) :waiting (live-waiters pool)}))

(defn- await
  "Park until a release hands this waiter a resource. Returns it, or
  nil when the waiter should re-enter `acquire`; a real timeout
  raises."
  [pool]
  (def s (pool :stats))
  (put s :waits (inc (s :waits)))
  (def waiter @{:chan (ev/chan 1) :live true :value nil})
  (array/push (pool :waiters) waiter)
  (def t0 (os/clock :monotonic))
  (defer
    # Leave the wait list no matter how we exit — a timed-out or
    # cancelled waiter that lingered would grow (pool :waiters) without
    # bound (nothing else prunes it under a stall) and could still be
    # handed a resource. Then rehome any resource handed to us that
    # the caller will not use (a cancelled checkout, a release that
    # raced our exit): a release writes it into the record before it
    # rings the channel, so the record is the one place to look, and
    # whether the wake-up ever reached the child task does not matter.
    # This whole block runs with no ev yield, so no release
    # interleaves between marking us dead and reading the record.
    (do
      (put waiter :live false)
      (when-let [i (index-of waiter (pool :waiters))]
        (array/remove (pool :waiters) i))
      (def stranded (waiter :value))
      (put waiter :value nil)
      (when stranded
        # the caller never reached acquire's own in-use increment, so
        # balance the decrement release is about to do
        (put pool :in-use (inc (pool :in-use)))
        (release pool stranded)))
    (def woken (wait-for-wake-up waiter (pool :checkout-timeout)))
    (put s :wait-us (+ (s :wait-us)
                       (math/round (* 1_000_000 (- (os/clock :monotonic) t0)))))
    (def handed (waiter :value))
    (cond
      # consumed by the caller — clear the record so the defer does
      # not rehome the resource we are about to return
      handed (do (put waiter :value nil) handed)
      # a retry that arrived, or one that a timed-out child left in
      # the channel: the pool state changed, decide again
      (or (= retry woken) (pos? (ev/count (waiter :chan)))) nil
      (timeout! pool))))

(defn acquire
  ``Take a resource: an idle one (validated), a fresh one while under
  `:size`, else park until a release hands one over (or
  `:checkout-timeout` elapses, raising `:timeout-kind`). A waiter
  woken because a slot was freed re-enters the same decision. Raises
  `:void.core/pool-closed` after `close!`.``
  [pool]
  (def s (pool :stats))
  (put s :checkouts (inc (s :checkouts)))
  (var res nil)
  (while (nil? res)
    (when (pool :closed)
      (errors/raise :void.core/pool-closed
                    (string (pool :name) " pool is closed")))
    (set res
         (cond
           (not (empty? (pool :idle))) (take-idle pool)
           (< (pool :created) (pool :size)) (connect-resource pool)
           (await pool))))
  (put pool :in-use (inc (pool :in-use)))
  res)

(defn with
  "Run `(f resource)` with a resource acquired for the call and released
  on every exit — a normal return, an error, a cancelled fiber."
  [pool f]
  (def res (acquire pool))
  (defer (release pool res)
    (f res)))

(defn close!
  "Close the pool: no more checkouts, idle resources closed now, in-use
  ones closed as they come back, parked waiters woken to fail."
  [pool]
  (put pool :closed true)
  (while (not (empty? (pool :idle)))
    (close-resource pool (array/pop (pool :idle))))
  (wake-all pool)
  nil)

(defn stats
  "Point-in-time counters: {:size :created :in-use :idle :waiting
  :checkouts :waits :wait-us :timeouts} plus the owner's `:counters`."
  [pool]
  (table/to-struct
    (merge (pool :stats)
           {:size (pool :size)
            :created (pool :created)
            :in-use (pool :in-use)
            :idle (length (pool :idle))
            :waiting (live-waiters pool)})))

(defn health
  "A component health value: `:status :up` (or `:down` once closed)
  with the stats."
  [pool]
  (merge {:status (if (pool :closed) :down :up)} (stats pool)))
