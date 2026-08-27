### void/redis/pool — fiber-aware connection pool (SPEC.md §5.10,
### ROADMAP 2.2).
###
### The same shape as void/db's pool, and deliberately not the same
### code: a cache should not require a database, so the two packages
### stay independent of each other. Connections are opened lazily up to
### :size; a checkout beyond capacity parks the fiber on a waiter
### channel with a deadline, so a saturated pool back-pressures request
### fibers instead of stacking connections on a server that is already
### the bottleneck. Checkin hands the connection to the oldest live
### waiter directly (FIFO — no thundering herd) and only falls back to
### the idle stack when nobody waits.
###
### The wait deadline runs in a child task, never `ev/with-deadline` on
### the caller: that cancels the *root task*, which for a request fiber
### is the whole request (the bug class documented in ADR-0015).
###
### Why a pool at all, when redis is single-threaded and one connection
### can carry every command? Because a fiber that sends a command has
### to wait for the reply before another fiber may use that connection
### — replies are ordered, not addressed — so a single connection makes
### every fiber queue behind the slowest one. The pool is what lets N
### fibers have N round trips in the air. It is also why the default
### size is small: eight connections is plenty of overlap for a
### sub-millisecond server, and a hundred idle connections are a
### hundred client buffers redis pays for.
###
### One thing this pool does that void/db's does not: a connection
### taken from the idle stack may have been closed by the server while
### it sat there (redis `timeout`, a restart, a proxy) — a checkout
### notices and reconnects before handing it over, which is the whole
### reason `conn/reconnect!` keeps the connection's identity.

(import void/core/log :as log)
(import ./conn :as conn)

(def log-ns "void.redis.pool")

(defn make
  ``Build a pool over connection options: opts {:size 8
  :checkout-timeout 5}, `conn-opts` as ./conn takes them.``
  [conn-opts &opt opts]
  (default opts {})
  @{:conn-opts conn-opts
    :size (get opts :size 8)
    :checkout-timeout (get opts :checkout-timeout 5)
    :idle @[]
    :waiters @[]
    :created 0
    :in-use 0
    :closed false
    :stats @{:checkouts 0 :waits 0 :wait-us 0 :timeouts 0
             :commands 0 :command-us 0 :reconnects 0}})

(defn note-command!
  "Record one executed command (called by the instrumented execution
  path in ./state)."
  [pool us]
  (def s (pool :stats))
  (put s :commands (inc (s :commands)))
  (put s :command-us (+ us (s :command-us))))

(defn- close-conn [pool c]
  (protect (conn/close c))
  (put pool :created (dec (pool :created))))

(defn- open-conn [pool]
  # reserve the slot first — a failing connect must release it
  (put pool :created (inc (pool :created)))
  (def [ok c] (protect (conn/open (pool :conn-opts))))
  (unless ok
    (put pool :created (dec (pool :created)))
    (error c))
  # opened for this checkout: a failure on it is the server being
  # unreachable, not a socket that went stale in the idle stack, and
  # ./state tells the two apart before it retries anything
  (put c :fresh true)
  c)

(defn- revive
  ``An idle connection, checked before it is handed over. A server-side
  idle timeout or a restart leaves a socket that looks fine until the
  first command fails on it, and a client that noticed only then would
  fail one request per pooled connection after every redis restart.``
  [pool c]
  (put c :fresh false)
  (if (conn/open? c)
    c
    (do
      (put-in pool [:stats :reconnects] (inc (get-in pool [:stats :reconnects])))
      (def [ok err] (protect (conn/reconnect! c)))
      (unless ok
        (close-conn pool c)
        (error err))
      (log/debug "reopened a connection the server had closed" :ns log-ns
                 :id (c :id) :generation (c :generation))
      c)))

(defn- take-with-deadline
  ``Take from a channel under a timeout without touching the caller's
  root task: the take runs in a supervised child task and lands in
  `slot`. Cancellation is cooperative (only at ev operations), so a
  take that returned always reaches the slot.``
  [ch timeout slot]
  (def sup (ev/chan 1))
  (def task (ev/go (fn waiter-task [] (put slot :conn (ev/take ch))) nil sup))
  (ev/deadline timeout task task)
  (ev/take sup)
  (get slot :conn))

(def- retry
  "Handover marker: the pool state changed (a connection slot was
  freed, or the pool closed) — the waiter re-enters `checkout`."
  :void.redis/retry)

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

(defn- await-conn
  "Park until a checkin hands this waiter a connection. Returns it, or
  nil when the waiter should re-enter `checkout`; a real timeout
  throws."
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
        (errorf "redis pool checkout timed out after %.1fs (size %d, in use %d, waiting %d)"
                (pool :checkout-timeout) (pool :size) (pool :in-use)
                (count |($ :live) (pool :waiters))))))

(defn checkout
  "Take a connection: an idle one (reopened if the server closed it), a
  fresh one while under :size, else park until a checkin hands one over
  (or :checkout-timeout elapses)."
  [pool]
  (def s (pool :stats))
  (put s :checkouts (inc (s :checkouts)))
  (var c nil)
  (while (nil? c)
    (when (pool :closed) (error "redis pool is closed"))
    (set c
         (cond
           (not (empty? (pool :idle))) (revive pool (array/pop (pool :idle)))
           (< (pool :created) (pool :size)) (open-conn pool)
           (await-conn pool))))
  (put pool :in-use (inc (pool :in-use)))
  c)

(defn discard!
  "Mark a connection broken: the next checkin closes it instead of
  reusing it. A connection whose reply stream desynchronised is worse
  than no connection at all."
  [c]
  (put c :discard true))

(defn checkin
  "Return a connection: to the oldest waiter if any, else the idle
  stack (or closed, when discarded / the pool is shutting down)."
  [pool c]
  (put pool :in-use (dec (pool :in-use)))
  (cond
    (or (c :discard) (not (conn/open? c)) (pool :closed))
    (do (close-conn pool c)
        # the freed slot is what a waiter needs: wake it so it opens a
        # fresh connection instead of parking until the timeout
        (when-let [w (next-waiter pool)]
          (ev/give (w :chan) retry)))

    (if-let [w (next-waiter pool)]
      (ev/give (w :chan) c)
      (array/push (pool :idle) c)))
  nil)

(defn close-all!
  "Close the pool: no more checkouts, idle connections closed now,
  in-use ones closed as they come back."
  [pool]
  (put pool :closed true)
  (while (not (empty? (pool :idle)))
    (close-conn pool (array/pop (pool :idle))))
  (while (when-let [w (next-waiter pool)] (ev/give (w :chan) retry) true))
  nil)

(defn stats
  "Point-in-time counters: {:size :created :in-use :idle :waiting
  :checkouts :waits :wait-us :timeouts :commands :command-us
  :reconnects}."
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
   :commands (s :commands)
   :command-us (s :command-us)
   :reconnects (s :reconnects)})

(defn health
  "The :redis/client component health value."
  [pool]
  (merge {:status (if (pool :closed) :down :up)} (stats pool)))
