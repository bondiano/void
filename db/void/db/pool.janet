### void/db/pool — fiber-aware connection pool (SPEC.md §5.9).
###
### One pool per :db/pool component, fed by the configured
### :void/db-driver. Connections are created lazily up to :size; a
### checkout beyond capacity parks the fiber on its own waiter channel
### with a deadline, so a saturated pool back-pressures request fibers
### instead of stacking connections. Checkin hands the connection to
### the oldest live waiter directly (FIFO — no thundering herd) and
### only falls back to the idle stack when nobody waits. Entries wrap
### the raw driver connection with a per-connection prepared-statement
### cache.
###
### The wait deadline runs in a child task, never `ev/with-deadline` on
### the caller: that cancels the *root task*, which for a request fiber
### is the whole request (the bug class documented in ADR-0015 /
### http/server run-handler). A waiter that times out re-checks both
### its slot and its channel before giving up, so a connection handed
### over in the cancellation window is never lost.
###
### The dyn side (checkout into :void.db/conn, auto-return) lives in
### ./state — this module is mechanics plus metrics: checkouts,
### blocking waits and their total wait time, query count/time.

(defn make
  "Build a pool over a driver: opts {:size 10 :checkout-timeout 5}."
  [driver &opt opts]
  (default opts {})
  @{:driver driver
    :size (get opts :size 10)
    :checkout-timeout (get opts :checkout-timeout 5)
    :idle @[]
    :waiters @[]
    :created 0
    :in-use 0
    :next-id 0
    :closed false
    :stats @{:checkouts 0 :waits 0 :wait-us 0 :timeouts 0
             :queries 0 :query-us 0}})

(defn driver-of
  "The driver a pool runs on."
  [pool]
  (pool :driver))

(defn note-query!
  "Record one executed statement (called by the instrumented execution
  path in ./state)."
  [pool us]
  (def s (pool :stats))
  (put s :queries (inc (s :queries)))
  (put s :query-us (+ us (s :query-us))))

(defn- close-entry [pool entry]
  (protect (((pool :driver) :close) (entry :conn))))

(defn- connect-entry [pool]
  # reserve the slot first — a failing connect must release it
  (put pool :created (inc (pool :created)))
  (def [ok conn] (protect (((pool :driver) :connect))))
  (unless ok
    (put pool :created (dec (pool :created)))
    (errorf "db driver connect failed: %s"
            (if (string? conn) conn (describe conn))))
  (put pool :next-id (inc (pool :next-id)))
  @{:conn conn :stmts @{} :id (pool :next-id)})

(defn- take-with-deadline
  ``Take from a channel under a timeout without touching the caller's
  root task: the take runs in a supervised child task and lands in
  `slot`. Cancellation is cooperative (only at ev operations), so a
  take that returned always reaches the slot.``
  [ch timeout slot]
  (def sup (ev/chan 1))
  (def task (ev/go (fn waiter-task [] (put slot :entry (ev/take ch)))
                   nil sup))
  (ev/deadline timeout task task)
  (ev/take sup)
  (get slot :entry))

(def- retry
  "Handover marker: the pool state changed (a connection slot was
  freed, or the pool closed) — the waiter re-enters `checkout`."
  :void.db/retry)

(defn- await-entry
  "Park until a checkin hands this waiter a connection. Returns the
  entry, or nil when the waiter should re-enter `checkout`; a real
  timeout throws."
  [pool]
  (def s (pool :stats))
  (put s :waits (inc (s :waits)))
  (def waiter @{:chan (ev/chan 1) :live true})
  (array/push (pool :waiters) waiter)
  (def t0 (os/clock :monotonic))
  (def handed (take-with-deadline (waiter :chan) (pool :checkout-timeout) @{}))
  (put s :wait-us (+ (s :wait-us)
                     (math/round (* 1_000_000 (- (os/clock :monotonic) t0)))))
  (put waiter :live false)
  # the handover may have landed in the channel while the child task
  # was being cancelled — claim it rather than leak the connection
  (def value (or handed
                 (when (pos? (ev/count (waiter :chan)))
                   (ev/take (waiter :chan)))))
  (cond
    (= retry value) nil
    value value
    (do (put s :timeouts (inc (s :timeouts)))
        (errorf "db pool checkout timed out after %.1fs (size %d, in use %d, waiting %d)"
                (pool :checkout-timeout) (pool :size) (pool :in-use)
                (count |($ :live) (pool :waiters))))))

(defn- next-waiter
  "Pop the oldest waiter still parked (dropping timed-out ones)."
  [pool]
  (def ws (pool :waiters))
  (var found nil)
  (while (and (nil? found) (not (empty? ws)))
    (def w (in ws 0))
    (array/remove ws 0)
    (when (w :live) (set found w)))
  found)

(defn checkout
  "Take a connection entry: an idle one, a fresh one while under
  :size, else park until a checkin hands one over (or
  :checkout-timeout elapses). A waiter woken because a slot was freed
  (a discarded connection) re-enters the same decision."
  [pool]
  (def s (pool :stats))
  (put s :checkouts (inc (s :checkouts)))
  (var entry nil)
  (while (nil? entry)
    (when (pool :closed)
      (error "db pool is closed"))
    (set entry
         (cond
           (not (empty? (pool :idle))) (array/pop (pool :idle))
           (< (pool :created) (pool :size)) (connect-entry pool)
           (await-entry pool))))
  (put pool :in-use (inc (pool :in-use)))
  entry)

(defn discard!
  "Mark an entry broken: the next checkin closes the raw connection
  instead of reusing it (a failed ROLLBACK leaves the connection in an
  unknown state)."
  [entry]
  (put entry :discard true))

(defn checkin
  "Return an entry to the pool: to the oldest waiter if any, else the
  idle stack (or closed, when discarded / the pool is shutting down)."
  [pool entry]
  (put pool :in-use (dec (pool :in-use)))
  (cond
    (or (entry :discard) (pool :closed))
    (do (close-entry pool entry)
        (put pool :created (dec (pool :created)))
        # the freed slot is what a waiter needs: wake it so it opens a
        # fresh connection instead of parking until the timeout
        (when-let [w (next-waiter pool)]
          (ev/give (w :chan) retry)))

    (if-let [w (next-waiter pool)]
      (ev/give (w :chan) entry)
      (array/push (pool :idle) entry)))
  nil)

(defn close-all!
  "Close the pool: no more checkouts, idle connections closed now,
  in-use ones closed as they come back."
  [pool]
  (put pool :closed true)
  (while (not (empty? (pool :idle)))
    (def entry (array/pop (pool :idle)))
    (close-entry pool entry)
    (put pool :created (dec (pool :created))))
  (while (when-let [w (next-waiter pool)] (ev/give (w :chan) retry) true))
  nil)

(defn stats
  "Point-in-time counters: {:size :created :in-use :idle :waiting
  :checkouts :waits :wait-us :timeouts :queries :query-us}."
  [pool]
  (def s (pool :stats))
  {:size (pool :size)
   :created (pool :created)
   :in-use (pool :in-use)
   :idle (length (pool :idle))
   :waiting (count |($ :live) (pool :waiters))
   :checkouts (s :checkouts)
   :waits (s :waits)
   :wait-us (s :wait-us)
   :timeouts (s :timeouts)
   :queries (s :queries)
   :query-us (s :query-us)})

(defn health
  "The :db/pool component health value."
  [pool]
  (merge {:status (if (pool :closed) :down :up)} (stats pool)))
