(import ../test-support/paths)
(import void/core/log :as log)
(import void/jobs/job :as job)
(import void/jobs/memory :as memory)
(import void/jobs/record :as record)
(import void/jobs/state :as state)
(import void/jobs/worker :as worker)

# the worker logs a failing job at :warn and a dead one at :error, and
# this suite is mostly about making jobs fail on purpose
(each ns ["void.jobs" "void.jobs.worker"] (log/set-level! ns :fatal))

(defn- queue [&opt cfg]
  (state/make (memory/store (memory/make)) (or cfg {})))

(defmacro- with-queue [q & body]
  ~(with-dyns [state/queue-dyn ,q] ,;body))

# -- running -------------------------------------------------------------

(def ran @[])
(job/defjob adder [a b] (array/push ran [a b]) (+ a b))

(def q (queue))
(with-queue q
  (state/enqueue :adder 1 2)
  (state/enqueue :adder 3 4)
  (assert (= 2 (worker/drain!)) "drain runs what is runnable")
  (assert (= 2 (length ran)) "and really runs it")
  (assert (= 2 (get-in (state/counts) [:default :completed])))
  (def [r] (state/list-jobs {:limit 1}))
  (assert (number? (r :result)) "with the handler's value on the record")

  (state/enqueue-in 3600 :adder 5 6)
  (assert (zero? (worker/drain!)) "a delayed job is not runnable now"))

# -- retries and the dead letter queue -----------------------------------

(def attempts @[])
(job/defjob flaky
  {:max-attempts 3 :backoff {:strategy :fixed :base 0 :jitter 0}}
  []
  (array/push attempts (state/attempt))
  (when (< (length attempts) 3) (error "not yet"))
  :finally)

(def fq (queue))
(with-queue fq
  (state/enqueue :flaky)
  # with no backoff a retry is runnable again immediately, so the same
  # drain picks it up — which is exactly what a retry is
  (assert (= 3 (worker/drain!)) "a failed job with attempts left is run again")
  (def [done] (state/list-jobs {:limit 1}))
  (assert (= :completed (done :state)) "and eventually succeeds")
  (assert (= :finally (done :result)) "with the value of the attempt that worked")
  (assert (= 3 (done :attempt)) "having counted every attempt")
  (assert (deep= [1 2 3] (tuple ;attempts))
          "and the handler could see which attempt it was on"))

(job/defjob always-fails {:max-attempts 2 :backoff {:strategy :fixed :base 0 :jitter 0}}
  [] (error "always"))

(def dq (queue))
(with-queue dq
  (state/enqueue :always-fails)
  (assert (= 2 (worker/drain!)) "a job that never works is tried its two times")
  (def [d] (state/list-jobs {:limit 1}))
  (assert (= :dead (d :state)) "a job out of attempts is dead")
  (assert (= 2 (d :attempt)) "having used every one")
  (assert (= 2 (length (d :failures))) "and kept the evidence")
  (assert (= 1 (get-in (state/counts) [:default :dead]))
          "the dead letter queue is a state, not a second store"))

(job/defjob last-chance {:max-attempts 2 :backoff {:strategy :fixed :base 0 :jitter 0}}
  [] (when (state/last-attempt?) (error "final")) (error "not final"))

(def lq (queue))
(with-queue lq
  (state/enqueue :last-chance)
  (worker/drain!)
  (def [d] (state/list-jobs {:limit 1}))
  (assert (= "final" (d :error))
          "a handler can tell whether a failure now is the last one"))

# -- retry delay ---------------------------------------------------------

(job/defjob backs-off {:max-attempts 5 :backoff {:strategy :fixed :base 60 :jitter 0}}
  [] (error "boom"))

(def bq (queue))
(with-queue bq
  (def before (os/clock :realtime))
  (state/enqueue :backs-off)
  (worker/drain!)
  (def [r] (state/list-jobs {:limit 1}))
  (assert (>= (r :run-at) (+ 59 before))
          "a retry waits the backoff before it may be claimed again"))

# -- timeouts ------------------------------------------------------------

(job/defjob slow {:timeout 0.05 :max-attempts 1} [] (ev/sleep 5) :never)

(def tq (queue))
(with-queue tq
  (state/enqueue :slow)
  (worker/drain!)
  (def [r] (state/list-jobs {:limit 1}))
  (assert (= :dead (r :state)) "a job that outruns its timeout fails")
  (assert (string/find "timed out" (r :error)) "and says so"))

# -- events --------------------------------------------------------------

(def heard @[])
(def eq (queue))
(state/listen! :spy (fn [e] (array/push heard (e :event))))
(defer (state/unlisten! :spy)
  (with-queue eq
    (state/enqueue :adder 1 1)
    (worker/drain!)
    (assert (deep= [:enqueued :started :completed] (tuple ;heard))
            "a job that works fires three events"))
  (array/clear heard)
  (def eq2 (queue))
  (with-queue eq2
    (state/enqueue :always-fails)
    (worker/drain!)
    (assert (index-of :failed heard) "a retryable failure fires :failed")
    (assert (index-of :dead heard) "and a final one fires :dead")))

# -- rate limiting -------------------------------------------------------

(def rq (queue {:queues {:default {:rate-limit {:max 2 :duration 3600}}}}))
(with-queue rq
  (each _ (range 5) (state/enqueue :adder 1 1))
  (assert (= 2 (worker/drain!)) "a rate limit stops the drain at its ceiling")
  (assert (= 3 (get-in (state/counts) [:default :pending]))
          "and what it would not run is still queued")
  (def [r] (state/list-jobs {:state :pending :limit 1}))
  (assert (zero? (r :attempt))
          "a job put back by a rate limit has not used an attempt"))

# -- per-queue concurrency and groups ------------------------------------

(def cq (queue {:queues {:default {:concurrency 1}}}))
(def w (worker/make cq {:concurrency 4}))
(assert (deep= [:default] (worker/eligible-queues w (os/clock :realtime)))
        "a queue under its cap is eligible")
(put-in w [:per-queue :default] 1)
(assert (empty? (worker/eligible-queues w (os/clock :realtime)))
        "and one at its cap is not claimed from at all")

(def gq (queue {:queues {:default {:group-concurrency 1}}}))
(def gw (worker/make gq {:concurrency 4}))
(assert (empty? (worker/blocked-groups gw)) "no group is blocked to begin with")
(put-in gw [:per-group "acme"] 1)
(assert (get (worker/blocked-groups gw) "acme")
        "a group at its cap is skipped by the claim — that is what fair scheduling is")

(job/defjob tenant-work {:group (fn [t] (string t))} [t] t)
(def fair (queue {:queues {:default {:group-concurrency 1}}}))
(with-queue fair
  (state/enqueue :tenant-work "acme")
  (state/enqueue :tenant-work "acme")
  (state/enqueue :tenant-work "globex")
  (def fw (worker/make fair {:concurrency 1}))
  (put-in fw [:per-group "acme"] 1)
  (def claimed (with-queue fair (worker/claim-one fw)))
  (assert (= "globex" (claimed :group))
          "with one tenant at its cap the next job comes from another"))

# -- stalled claims ------------------------------------------------------

(def sq (queue {:claim-ttl 0.01}))
(with-queue sq
  (state/enqueue :adder 1 1)
  (def sw (worker/make sq {:concurrency 1}))
  (def held (worker/claim-one sw))
  (assert (= :running (held :state)))
  (ev/sleep 0.05)
  (assert (= 1 (worker/reap-once! sw)) "an abandoned claim is reaped")
  (def [r] (state/list-jobs {:limit 1}))
  (assert (= :pending (r :state)) "and the job goes back to the queue")
  (assert (string/find "stopped answering" (r :error)) "with the reason on it"))

# -- lifecycle -----------------------------------------------------------

(def lifecycle (queue))
(with-queue lifecycle
  (def lw (worker/make lifecycle {:concurrency 2 :poll-interval 0.02
                                  :shutdown-timeout 2}))
  (worker/start! lw)
  (state/enqueue :adder 2 2)
  (var waited 0)
  (while (and (< waited 100) (zero? (get-in (state/counts) [:default :completed] 0)))
    (ev/sleep 0.02)
    (++ waited))
  (assert (= 1 (get-in (state/counts) [:default :completed]))
          "a started worker picks up what is enqueued after it started")
  (assert (zero? (worker/stop! lw)) "and stops cleanly")
  (assert (lw :stopped))
  (assert (pos? (get-in (worker/stats lw) [:completed])))

  (state/enqueue :adder 3 3)
  (ev/sleep 0.1)
  (assert (= 1 (get-in (state/counts) [:default :pending]))
          "a stopped worker claims nothing"))

# -- a zero poll interval polls again, it does not park -------------------
#
# The config schema refuses a zero, but make takes its opts as given,
# and the wait underneath reads a non-positive deadline as none: a
# runner that took the stop channel with no deadline would sit there
# until stop! and never claim the job enqueued after it started.

(def spinq (queue))
(with-queue spinq
  (def sw (worker/make spinq {:concurrency 1 :poll-interval 0
                              :shutdown-timeout 2}))
  (worker/start! sw)
  (state/enqueue :adder 7 8)
  (var waited 0)
  (while (and (< waited 100) (zero? (get-in (state/counts) [:default :completed] 0)))
    (ev/sleep 0.01)
    (++ waited))
  (assert (= 1 (get-in (state/counts) [:default :completed]))
          "a worker polling with no interval still picks up what is enqueued")
  (def t0 (os/clock :monotonic))
  (assert (zero? (worker/stop! sw)) "and stops cleanly")
  (assert (< (- (os/clock :monotonic) t0) 1) "promptly — the loop was not parked on its stop channel"))

# -- shutdown is a drain, not a kill --------------------------------------
#
# The test above stops a worker whose jobs already finished, which any
# stop! passes. The promise worth checking is the other one: a job
# still running when stop! is called gets its :shutdown-timeout to
# finish rather than being abandoned to the reaper.

(job/defjob dawdles [] (ev/sleep 0.3) :eventually)

(def drainq (queue))
(with-queue drainq
  (def dw (worker/make drainq {:concurrency 2 :poll-interval 0.02
                               :shutdown-timeout 5}))
  (worker/start! dw)
  (state/enqueue :dawdles)
  (var waited 0)
  (while (and (< waited 100) (empty? (dw :running)))
    (ev/sleep 0.01)
    (++ waited))
  (assert (= 1 (length (dw :running))) "the slow job is running when stop! is called")
  (assert (zero? (worker/stop! dw)) "stop! drains it rather than giving up")
  (def [r] (state/list-jobs {:limit 1}))
  (assert (= :completed (r :state)) "the job finished, it was not left :running")
  (assert (= :eventually (r :result)) "with its result settled"))

# -- the trace a job was queued in ---------------------------------------
#
# `trace-context` is what void/obs fills so a record remembers the
# request that asked for the work; the worker's half is the seam
# below, which is where obs reads it back.

(def tp "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
(def tpq (queue))
(with-queue tpq
  (assert (nil? ((state/enqueue :adder 1 2) :traceparent))
          "nothing tracing, nothing carried")
  (set state/trace-context (fn [] tp))
  (assert (= tp ((state/enqueue :adder 1 2) :traceparent))
          "the record carries the trace it was queued in, so a worker an hour later can join it")
  (set state/trace-context (fn [] nil))
  (assert (nil? ((state/enqueue :adder 1 2) :traceparent))
          "a seam that answers nil — a job queued by a cron tick — leaves the field alone")
  (set state/trace-context nil))

# -- the wrapper seam ----------------------------------------------------
#
# `around-run` is what void/obs fills to put a span around a job (and
# with it, the trace ids on the worker's own log records). The worker
# only has to call it, and to run the job itself when nobody has.

(def wrapped @[])
(job/defjob wrappable [] :done)

(def wq (queue))
(set worker/around-run
     (fn [r run]
       (array/push wrapped (r :job))
       (run)))
(with-queue wq
  (state/enqueue :wrappable)
  (assert (= 1 (worker/drain!)))
  (assert (deep= @[:wrappable] wrapped) "the seam is handed the record it is about to run")
  (assert (= 1 (get-in (state/counts) [:default :completed]))
          "and the job settles inside it"))

(set worker/around-run nil)
(with-queue wq
  (state/enqueue :wrappable)
  (assert (= 1 (worker/drain!)))
  (assert (= 1 (length wrapped)) "nil is the plain path"))

# -- what a worker refuses to be built as --------------------------------

(each [opts reason]
  [[{:concurrency 0} "a worker that runs nothing"]
   [{:concurrency 1.5} "a fractional fiber"]
   [{:queues []} "a worker serving no queue"]
   [{:queues ["default"]} "a queue named by string"]]
  (def [ok _] (protect (worker/make (queue) opts)))
  (assert (not ok) (string reason " is refused")))

(print "worker-test ok")
