# Delivery through void/jobs: composing the plugin is the whole of it,
# a channel is a job of its own, and a far end that has already
# answered is recorded rather than retried.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/jobs :as jobs)
(import void/test :as test)
(import void/notify :as notify)
(import void/notify/channel :as channel)
(require "void/notify/jobs")

(log/set-level! "void" :error)

(def plugins ["void/jobs/init" "void/notify/init" "void/notify/jobs"])

(defn- start [&opt extra]
  (test/start! {:plugins plugins
                :only [:jobs/queue]
                :profile :test
                :config {:env @{}
                         :cli (merge {:log {:level :error}
                                      # a disabled queue runs the handler inline
                                      # (void/jobs' own switch for a suite), which is
                                      # exactly what this suite needs: the routing is
                                      # what is under test, not the worker
                                      :jobs {:enabled false}
                                      :notify {:channels [:memory]}}
                                     (or extra {}))}}))

(def boot (start))

(defer (test/stop! boot)
  (notify/clear-outbox!)

  (assert (notify/queued?)
          "composing void/notify-jobs is the whole of \"notify through a queue\" — no call site changes")

  (def result (notify/send {:key :order/shipped :title "Your order shipped"
                            :to {:email "ada@example.com"}}))
  (assert (= :queued (get-in result [:results 0 :status]))
          "the result says the notification was handed over")
  (assert (get-in result [:results 0 :job]) "and names the job")
  (assert (= 1 (length (notify/outbox)))
          "with [:jobs :enabled] false the handler ran inline and the notification went out")
  (assert (= (result :id) (get-in (notify/outbox) [0 :id]))
          "what is queued is the projection, so the worker delivered this very notification")

  # -- one job per channel -----------------------------------------------

  (notify/clear-outbox!)
  (def both (notify/send {:key :x :title "t" :channels [:memory :log]
                          :to {:email "ada@example.com"}}))
  (assert (= 2 (length (both :results))))
  (assert (every? (map |(= :queued ($ :status)) (both :results)))
          "one job per channel, because they fail separately and retry separately")
  (assert (not= (get-in both [:results 0 :job]) (get-in both [:results 1 :job])))

  # -- a final answer is recorded, not retried ---------------------------

  (put notify/channels :refuses
       (channel/normalize {:name :refuses
                           :deliver (fn [_] (error {:status 404 :message "no such hook"}))
                           :permanent? (fn [err] (= 404 (get err :status)))}))
  (put notify/channels :later
       (channel/normalize {:name :later
                           :deliver (fn [_] (error {:status 503 :message "try again"}))
                           :permanent? (fn [err] (= 404 (get err :status)))}))

  (def payload (notify/normalize {:key :x :title "t" :to {:email "a@b.co"}} [:refuses]))

  # the rejection is logged at :error by design — this is the one place
  # that expects it, so the namespace is quiet for the assertion
  (log/set-level! "void.notify.jobs" :fatal)
  (def rejected (jobs/perform :notify-deliver :refuses payload))
  (assert (rejected :rejected)
          "a far end that has answered comes back as a completed job carrying the rejection")
  (assert (= :refuses (rejected :channel)))
  (assert (= (payload :id) (rejected :id)))

  (assert (not (first (protect (jobs/perform :notify-deliver :later payload))))
          "and anything that might succeed later is thrown, so the queue's retry policy takes it")
  (log/set-level! "void.notify.jobs" :error)

  (put notify/channels :refuses nil)
  (put notify/channels :later nil)

  # -- the job's own policy ----------------------------------------------

  (def opts ((jobs/job-of :notify-deliver) :opts))
  (assert (= :notify (opts :queue))
          "notifications have their own queue, so [:jobs :queues :notify] is where a deployment tunes them")
  (assert (= 5 (opts :max-attempts))))

# -- [:notify :queue] false opts out -------------------------------------

(def direct (start {:notify {:channels [:memory] :queue false}}))
(defer (test/stop! direct)
  (notify/clear-outbox!)
  (def r (notify/send {:key :x :title "t" :to {:email "a@b.co"}}))
  (assert (= :sent (get-in r [:results 0 :status]))
          "an application that wants the request to wait for the delivery can say so")
  (assert (= 1 (length (notify/outbox)))))

# -- :needs — what the delivery needs *open* where it runs ---------------
#
# `:project` runs on the request fiber, inside an application whose
# components are all up. `:deliver` runs on a worker, and a worker is a
# CLI command: it starts what it declared and nothing else. A channel
# that posts over https is the only thing that knows it needs the TLS
# stack, so it says so, and this is where that reaches the job the
# worker reads (examples/hub, ROADMAP 6.6).

(def over-https
  (plugin/manifest 'test/over-https
    :doc "A channel that would open a socket to somebody."
    :requires {:void/notify ">=0.0.1"}
    :contributes {:void.notify/channel
                  [{:name :pigeon
                    :needs [:tls/lib]
                    :deliver (fn [payload] (channel/receipt :pigeon payload))}]}))

(def with-needs
  (test/start! {:plugins [;plugins over-https]
                :only [:jobs/queue]
                :profile :test
                :config {:env @{}
                         :cli {:log {:level :error}
                               :jobs {:enabled false}
                               :notify {:channels [:memory :pigeon]}}}}))

(defer (test/stop! with-needs)
  (assert (= [:tls/lib] (get-in (jobs/job-of :notify-deliver) [:opts :needs]))
          "the union of the active channels' :needs is on the delivery job, which is what `void jobs work` starts")
  (assert (= [:tls/lib] (jobs/job-needs [:notify]))
          "...and therefore in what the worker on the :notify queue asks for"))
