(import ../test-support/paths)
(import void/core/log :as log)
(import void/jobs/job :as job)
(import void/jobs/memory :as memory)
(import void/jobs/schedule :as schedule)
(import void/jobs/state :as state)
(import void/jobs/worker :as worker)

(each ns ["void.jobs" "void.jobs.schedule" "void.jobs.worker"] (log/set-level! ns :fatal))

(defn- queue [] (state/make (memory/store (memory/make)) {}))

(defmacro- with-queue [q & body]
  ~(with-dyns [state/queue-dyn ,q] ,;body))

(job/defjob report [& args] args)

# -- declaring -----------------------------------------------------------

(schedule/defschedule nightly "0 3 * * *" :report {:args ["yesterday"]})
(assert (index-of :nightly (schedule/defined)) "a schedule registers under its name")
(assert (= :report (nightly :job)) "naming the job it enqueues")
(assert (deep= ["yesterday"] (tuple ;(nightly :args))) "with its arguments")

(schedule/defschedule ticker {:every 30} :report)
(assert (= :every (ticker :kind)) "an interval is a schedule too")

(schedule/defschedule utc-vs-local {:cron "0 3 * * *" :local true} :report)
(assert (utc-vs-local :local) "local time is opt-in")
(assert (not (nightly :local)) "and UTC is what a bare crontab means here")

(each [spec reason]
  [["not a crontab at all" "nonsense"]
   [{:every -1} "an interval that runs backwards"]
   [{} "a rule that says nothing"]
   [42 "a number"]]
  (def [ok _] (protect (schedule/define! :bad spec :report)))
  (assert (not ok) (string reason " is refused")))

# an option in the rule's place is a schedule that would never have
# fired the way it was written
(def [sok serr] (protect (schedule/define! :bad {:every 60 :on-start true} :report)))
(assert (not sok) "an option inside the rule is refused")
(assert (string/find "after the job name" serr) "with where it belongs")

(def [ok _] (protect (schedule/define! :bad "* * * * *" :report {:nonsense 1})))
(assert (not ok) "and so is an option that does not exist")

# -- slots ---------------------------------------------------------------

(def every-minute (schedule/define! :per-minute {:every 60} :report))
(assert (= 1200 (schedule/next-slot every-minute 1180)) "the next interval boundary")
(assert (= 1260 (schedule/next-slot every-minute 1200)) "strictly after, never the same one twice")

(def [slot skipped] (schedule/due-slot every-minute 1000 1200))
(assert (= 1200 slot) "the most recent occurrence is the one that fires")
(assert (= 3 skipped) "and the ones missed are counted, not fired")
(assert (nil? (schedule/due-slot every-minute 1180 1190)) "nothing due is nil")

(def cron-slot (schedule/define! :hourly "0 * * * *" :report))
(def next-hour (schedule/next-slot cron-slot 0))
(assert (= 3600 next-hour) "a crontab reads in UTC")

# -- firing --------------------------------------------------------------

(def q (queue))
(with-queue q
  (def r (schedule/fire! every-minute 1200 {:token "t1"}))
  (assert r "firing a slot enqueues the job")
  (assert (= :report (r :job)))
  (assert (nil? (schedule/fire! every-minute 1200 {:token "t2"}))
          "a second process firing the same slot gets nothing — the lease is the slot's")
  (assert (schedule/fire! every-minute 1260 {:token "t2"})
          "and the next slot is nobody's yet")
  (assert (= 2 (get-in (state/counts) [:default :pending]))))

# -- ticking -------------------------------------------------------------

(def tq (queue))
(with-queue tq
  (schedule/forget! :nightly)
  (schedule/forget! :ticker)
  (schedule/forget! :utc-vs-local)
  (schedule/forget! :per-minute)
  (schedule/forget! :hourly)
  (schedule/forget! :bad)
  (schedule/define! :fast {:every 0.05} :report)

  (def cursors @{})
  (assert (empty? (schedule/tick! cursors))
          "the first pass only notes where the clock is — starting at 03:05 must not fire 03:00")
  (ev/sleep 0.12)
  (def fired (schedule/tick! cursors))
  (assert (= 1 (length fired)) "the next pass fires what has come due")
  (assert (= 1 (length (state/list-jobs {}))) "once, however many slots went by")

  (schedule/define! :eager {:every 3600} :report {:on-start true})
  (def c2 @{})
  (assert (= 1 (length (schedule/tick! c2)))
          ":on-start fires the first pass as well")

  (schedule/define! :off {:every 0.01} :report {:enabled false})
  (def c3 @{})
  (ev/sleep 0.05)
  (schedule/tick! c3)
  (assert (nil? (get c3 :off)) "a disabled schedule is not even looked at"))

# -- status --------------------------------------------------------------

(def rows (schedule/status))
(assert (not (empty? rows)) "status lists the schedules")
(each s rows
  (assert (number? (s :next)) "each with when it fires next")
  (assert (>= (s :in) 0) "which is in the future"))

# -- the component -------------------------------------------------------

(def sq (queue))
(each n (schedule/defined) (schedule/forget! n))
(schedule/define! :loop-test {:every 0.05} :report)
(def sc (schedule/make sq {:interval 0.02 :lock-ttl 5}))
(schedule/start! sc)
(defer (schedule/stop! sc)
  (ev/sleep 0.25)
  (assert (pos? (with-queue sq (fn [] (length (state/list-jobs {})))))
          "a started scheduler enqueues on its own"))
(assert (sc :stopped) "and stops")

(print "schedule-test ok")
