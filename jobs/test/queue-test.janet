(import ../test-support/paths)
(import void/core/log :as log)
(import void/jobs/job :as job)
(import void/jobs/memory :as memory)
(import void/jobs/record :as record)
(import void/jobs/state :as state)

(log/set-level! "void.jobs" :error)

(defn- queue [&opt cfg]
  (state/make (memory/store (memory/make)) (or cfg {})))

(defmacro- with-queue [q & body]
  ~(with-dyns [state/queue-dyn ,q] ,;body))

(job/defjob plain [x] x)
(job/defjob declared {:queue :mail :priority 2 :max-attempts 7 :timeout 12} [x] x)

# -- the queue has to be there -------------------------------------------

(def [ok err] (protect (state/enqueue :plain 1)))
(assert (not ok) "enqueueing without a queue is an error")
(assert (string/find "not started" err) "and says so in those words")

# -- policy resolution ---------------------------------------------------

(def q (queue {:priority 4 :max-attempts 2
               :queues {:mail {:max-attempts 5 :timeout 30}}}))

(with-queue q
  (def r (state/enqueue :plain 1))
  (assert (= :default (r :queue)) "the default queue")
  (assert (= 4 (r :priority)) "the application's priority")
  (assert (= 2 (r :max-attempts)) "the application's attempts")

  (def d (state/enqueue :declared 1))
  (assert (= :mail (d :queue)) "the job's own queue")
  (assert (= 2 (d :priority)) "the job's priority beats the application's")
  (assert (= 7 (d :max-attempts)) "and its attempts beat the queue's")
  (assert (= 12 (d :timeout)) "as does its timeout")

  (def o (state/enqueue-with {:queue :other :priority 0 :max-attempts 1} :declared 1))
  (assert (= :other (o :queue)) "the call overrides the job")
  (assert (= 0 (o :priority)))
  (assert (= 1 (o :max-attempts)))

  # the queue slice sits between the application and the job
  (def m (state/enqueue-with {:queue :mail} :plain 1))
  (assert (= 5 (m :max-attempts)) "the queue's attempts beat the application's")
  (assert (= 30 (m :timeout)) "and its timeout is the queue's"))

# -- delays --------------------------------------------------------------

(def dq (queue))
(with-queue dq
  (def now (os/clock :realtime))
  (def soon (state/enqueue-in 60 :plain 1))
  (assert (>= (soon :run-at) (+ 59 now)) ":delay is from now")
  (def at (state/enqueue-at (+ now 3600) :plain 1))
  (assert (= (+ now 3600) (at :run-at)) ":at is absolute")
  (def [bok _] (protect (state/enqueue-with {:delay 1 :at 2} :plain 1)))
  (assert (not bok) "asking for both is a mistake, not a preference"))

# -- what may be queued --------------------------------------------------

(def vq (queue))
(with-queue vq
  (def [aok aerr] (protect (state/enqueue :plain (fn [] 1))))
  (assert (not aok) "an argument that cannot be stored fails at enqueue")
  (assert (string/find "plain data" aerr) "in the caller's stack, with the reason")

  (def [uok uerr] (protect (state/enqueue-with {:nonsense 1} :plain 1)))
  (assert (not uok) "an option that does not exist is refused")
  (assert (string/find "unknown option" uerr))

  (def [qok _] (protect (state/enqueue :never-defined 1)))
  (assert (not qok) "so is a job nobody declared"))

# -- unique jobs ---------------------------------------------------------

(job/defjob once {:unique :args} [x] x)
(def uq (queue))
(with-queue uq
  (def a (state/enqueue :once 1))
  (def b (state/enqueue :once 1))
  (assert (= (a :id) (b :id))
          "a second enqueue of a unique job answers with the job already queued")
  (def c (state/enqueue :once 2))
  (assert (not= (a :id) (c :id)) "different arguments are a different job")
  (assert (= 1 (get-in (state/stats) [:duplicates])) "and the duplicate is counted"))

# -- inline mode ---------------------------------------------------------

(def seen @[])
(job/defjob inline-job [x] (array/push seen x) (* 2 x))
(def iq (queue {:enabled false}))
(with-queue iq
  (def r (state/enqueue :inline-job 21))
  (assert (= [21] (tuple ;seen)) "a disabled queue runs the job inline")
  (assert (= :completed (r :state)) "and answers with a finished record")
  (assert (= 42 (r :result)) "carrying what it returned")
  (assert (empty? (state/list-jobs {})) "nothing was stored")

  (job/defjob inline-boom [] (error "no"))
  (def [bok berr] (protect (state/enqueue :inline-boom)))
  (assert (not bok) "and a failure is the caller's, not a retry")
  (assert (string/find "no" berr)))

# -- events --------------------------------------------------------------

(def heard @[])
(def eq (queue))
(state/listen! :test (fn [e] (array/push heard (e :event))))
(defer (state/unlisten! :test)
  (with-queue eq
    (state/enqueue :plain 1)
    (assert (= [:enqueued] (tuple ;heard)) "enqueueing is an event")))

(def eq2 (queue))
(state/listen! :throws (fn [_] (error "listener trouble")))
(defer (state/unlisten! :throws)
  (with-queue eq2
    (assert (state/enqueue :plain 1)
            "a listener that throws does not take the job down with it")))

# -- inspection ----------------------------------------------------------

(def iq2 (queue))
(with-queue iq2
  (def r (state/enqueue :plain 1))
  (assert (= (r :id) ((state/fetch (r :id)) :id)) "a record can be fetched")
  (assert (= 1 (length (state/list-jobs {}))) "and listed")
  (assert (= 1 (get-in (state/counts) [:default :pending])) "and counted")

  (def dead (state/enqueue :plain 2))
  (record/kill! dead "boom" (os/clock :realtime))
  (((iq2 :backend) :settle!) dead)
  (assert (= 1 (get-in (state/counts) [:default :dead])))
  (def revived (state/retry! (dead :id)))
  (assert (= :pending (revived :state)) "a dead record can be requeued")
  (assert (nil? (state/retry! "no-such-id")) "and an unknown id is merely nil")

  (assert (state/remove-job! (r :id)) "a record can be removed")
  (assert (pos? (state/clear! {})) "and the queue emptied")
  (assert (empty? (state/list-jobs {}))))

# -- perform -------------------------------------------------------------

(assert (= 5 (state/perform :plain 5)) "perform runs the work with no queue at all")

(print "queue-test ok")
