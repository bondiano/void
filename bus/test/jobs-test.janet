(import ../test-support/paths)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/test :as test)
(import void/jobs :as jobs)
(import void/bus :as bus)
(import void/bus/jobs :as bridge)
(import void/bus/state :as state)

(log/set-level! "void" :error)
# the dead-letter case below logs an error on purpose
(log/set-level! "void.jobs.worker" :fatal)

# The last promise, made true: void/jobs publishes its
# lifecycle events onto the bus when there is one. The seam is
# `jobs/listen!`, which void/jobs left ready in wave 2 for exactly
# this; the bridge is a plugin rather than a line in void/jobs so that
# a queue does not drag a message bus in behind it.

(def plugins ["void/bus/init" "void/jobs/init" "void/bus/jobs"])

(def events @[])
(bus/defhandler watch-jobs
  "Everything the queue says about itself."
  {:topic :jobs/*}
  [msg]
  (array/push events [(msg :topic) (msg :payload)]))

(jobs/defjob add-up
  "Add two numbers, or refuse to."
  {:queue :sums :max-attempts 1}
  [a b]
  (when (= a :boom) (error "cannot add that"))
  (+ a b))

(def boot
  (test/start! {:plugins plugins
                :profile :test
                :config {:env @{}
                         :cli {:log {:level :error}
                               :bus {:dedup {:enabled false}
                                     :poison {:enabled false}
                                     :retry {:enabled false}}}}}))

(defer (test/stop! boot)
  # every topic the bridge can publish on is declared, not invented at
  # the call site
  (assert (= (length jobs/events) (length bridge/topics)))
  (assert (= :jobs/completed (bridge/topics :completed)))

  (jobs/enqueue :add-up 2 3)
  (jobs/drain! {:queues [:sums]})
  (ev/sleep 0.08)

  (def topics (map first events))
  (assert (index-of :jobs/enqueued topics))
  (assert (index-of :jobs/started topics))
  (assert (index-of :jobs/completed topics))

  (def [_ completed] (find |(= :jobs/completed (first $)) events))
  (assert (= "add-up" (completed "job")))
  (assert (= "sums" (completed "queue")))
  (assert (= "completed" (completed "state")))
  (assert (number? (completed "duration")))

  # the arguments are deliberately not on a topic the whole fleet reads
  (assert (nil? (completed "args"))
          "a job's arguments stay in the queue: this is a summary, not the record")

  # one job, one correlation — which is how a job is followed from
  # :enqueued to :dead with a single filter
  (def ids (distinct (map |(get-in $ [1 "id"])
                          (filter |(string/has-prefix? "jobs/" (string (first $))) events))))
  (assert (= 1 (length ids)))

  (array/clear events)

  # -- a failure travels too ----------------------------------------

  (jobs/enqueue :add-up :boom 1)
  (jobs/drain! {:queues [:sums]})
  (ev/sleep 0.08)
  (def topics2 (map first events))
  # one attempt, so there is no :failed-and-will-retry — the job goes
  # straight to the dead letter queue, and says so on the bus
  (assert (index-of :jobs/dead topics2)
          "out of attempts, the queue says so on the bus as well as in its own table")
  (def [_ dead] (find |(= :jobs/dead (first $)) events))
  (assert (string/find "cannot add that" (dead "error"))
          "and the error comes with it")

  # -- nothing here may fail a job ------------------------------------
  #
  # A bus having a bad afternoon must not turn a completed job into a
  # failed one, so the bridge swallows what it cannot publish.

  (def br state/current-broker)
  (def real (br :backend))
  (put br :backend
       (merge (table ;(kvs real))
              {:publish! (fn broken [_] (error "the bus is having an afternoon"))}))
  (def [ok res] (protect (jobs/perform :add-up 1 1)))
  (put br :backend real)
  (assert ok "a job still runs and still returns when the bus cannot publish")
  (assert (= 2 res)))

(print "void/bus-jobs tests OK")
