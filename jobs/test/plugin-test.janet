(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/jobs :as jobs)
(import void/jobs/schedule :as schedule)
(import void/jobs/state :as state)

(each ns ["void.jobs" "void.jobs.worker" "void.jobs.schedule"] (log/set-level! ns :fatal))

(def plugins ["void/jobs/init"])

(defn- config [extra]
  {:env @{} :cli (merge {:log {:level :error}} extra)})

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "the plugin composes on its own")
(each k [:jobs/memory :jobs/queue :jobs/worker :jobs/scheduler]
  (assert (index-of k (report :components)) (string/format "%q is in the graph" k)))

(def interfaces (get-in report [:extensions :void.core/interface :contributions]))
(assert (and interfaces (>= interfaces 2))
        "both interfaces are declared — the one you depend on and the one you implement")
(assert (>= (get-in report [:extensions :void.core/cli :contributions]) 7)
        "and the queue is operable from the command line")

(each [slice reason]
  [[{:jobs {:max-attempts 0}} "a job that may never run"]
   [{:jobs {:backoff {:strategy :magic}}} "a backoff strategy nobody implements"]
   [{:jobs {:backoff {:jitter 3}}} "more jitter than there is delay"]
   [{:jobs {:claim-ttl 0}} "a claim that is stale the moment it is taken"]
   [{:jobs {:worker {:concurrency 0}}} "a worker that runs nothing"]
   [{:jobs {:queues {:mail {:rate-limit {:max 0}}}}} "a rate limit of nothing"]
   [{:jobs {:scheduler {:interval 0}}} "a scheduler that never sleeps"]]
  (def [ok _] (protect (plugin/dry-run {:plugins plugins :profile :test
                                        :config (config slice)})))
  (assert (not ok) (string reason " fails the boot")))

(def [gok _] (protect (plugin/dry-run
                        {:plugins plugins :profile :test
                         :config (config {:jobs {:queues {:mail {:concurrency 2
                                                                 :group-concurrency 1
                                                                 :rate-limit {:max 100 :duration 60}}}}})})))
(assert gok "a fully spelled-out queue slice is valid")

# -- started -------------------------------------------------------------

(jobs/defjob welcome [x] (* 2 x))

(def boot
  (plugin/start! {:plugins plugins :profile :test
                  :config (config {:jobs {:max-attempts 2
                                          :queues {:mail {:concurrency 1}}}})}))
(defer (plugin/shutdown! boot 3)
  (def q (get-in boot [:system :instances :jobs/queue]))
  (assert q "the queue component started")
  (assert (= q (state/active-queue)) "and is what the module-level functions reach for")
  (assert (= :memory (get-in q [:backend :name])) "over the backend this plugin ships")

  (def w (get-in boot [:system :instances :jobs/worker]))
  (assert (get w :disabled) "the worker is off unless a process asks for one")
  (def sc (get-in boot [:system :instances :jobs/scheduler]))
  (assert (get sc :disabled) "and so is the scheduler")

  # -- the surface applications import ------------------------------------

  (def r (jobs/enqueue :welcome 21))
  (assert (= :pending (r :state)))
  (assert (= 2 (r :max-attempts)) "with the configured policy on it")
  (assert (= 1 (jobs/drain!)) "and a drain runs it")
  (assert (= 42 ((jobs/fetch (r :id)) :result)))
  (assert (= 1 (get-in (jobs/counts) [:default :completed])))
  (assert (jobs/stats) "stats answer")

  (jobs/enqueue-in 3600 :welcome 1)
  (assert (zero? (jobs/drain!)) "a delayed job waits")
  (assert (= 1 (get-in (jobs/counts) [:default :pending])))

  (def flow-root (jobs/flow {:job :welcome :args [1]
                             :children [{:job :welcome :args [2]}]}))
  (assert (= :waiting (flow-root :state)) "flows work through the plugin surface")

  # the CLI commands are the ones the manifest promised
  (def cli (get-in boot [:extensions :void.core/cli :resolved]))
  (def names (map |($ :name) cli))
  (each n [:jobs/stats :jobs/list :jobs/show :jobs/retry :jobs/remove
           :jobs/clear :jobs/work :jobs/schedules]
    (assert (index-of n names) (string/format "%q is a command" n)))

  # health carries the queue, not merely :up
  (def h (get-in boot [:system :components :jobs/queue :health]))
  (assert (= :up ((h q) :status)) "the queue reports its health")
  (assert (get (h q) :counts) "with what it is holding"))

# -- a worker that is asked for ------------------------------------------

(def running
  (plugin/start! {:plugins plugins :profile :test
                  :config (config {:jobs {:worker {:enabled true :concurrency 2
                                                   :poll-interval 0.02}}})}))
(defer (plugin/shutdown! running 5)
  (def w (get-in running [:system :instances :jobs/worker]))
  (assert (not (get w :disabled)) "[:jobs :worker :enabled] starts one")
  (assert (not (w :stopped)) "and it is running")
  (jobs/enqueue :welcome 5)
  (var waited 0)
  (while (and (< waited 100) (zero? (get-in (jobs/counts) [:default :completed] 0)))
    (ev/sleep 0.02)
    (++ waited))
  (assert (= 1 (get-in (jobs/counts) [:default :completed]))
          "the running worker picks jobs up on its own"))

# -- a scheduler that is asked for ---------------------------------------

(each n (schedule/defined) (schedule/forget! n))
(jobs/defschedule often {:every 0.05} :welcome {:args [1]})
(assert (= :welcome (often :job)) "defschedule is on the plugin surface too")

(def scheduled
  (plugin/start! {:plugins plugins :profile :test
                  :config (config {:jobs {:scheduler {:enabled true :interval 0.02}}})}))
(defer (do (plugin/shutdown! scheduled 3) (schedule/forget! :often))
  (ev/sleep 0.25)
  (assert (pos? (length (jobs/list-jobs {})))
          "a started scheduler enqueues without a worker being involved"))

(print "plugin-test ok")
