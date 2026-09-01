# The kernel: what the boot resolves, what it refuses, and what
# notify/send does with several channels at once — including the two
# outcomes that are not "delivered".

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/notify :as notify)
(import void/notify/channel :as channel)

(log/set-level! "void" :error)

(def plugins ["void/notify/init"])

(defn- config [extra]
  {:env @{}
   :cli (merge {:log {:level :error}} extra)})

(defn- start [&opt extra profile]
  (test/start! {:plugins plugins
                :profile (or profile :test)
                :config (config (or extra {}))}))

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok))
(assert (= 2 (get-in report [:extensions :void.notify/channel :contributions]))
        "the kernel ships :memory and :log — the two channels that need nothing")

# -- what the boot refuses ----------------------------------------------

(def [ok err] (protect (start {:notify {:channels [:telegram]}})))
(assert (not ok) "a channel nobody contributed stops the boot")
(assert (string/find "no plugin contributed" (string err)))

(def [ok2 err2] (protect (start {:notify {:channels [:memory]}} :prod)))
(assert (not ok2)
        "in production a composition whose channels all keep notifications rather than delivering them is a boot error")
(assert (string/find "delivers no notification anywhere" (string err2))
        "and the message says so, because a deployment that silently notifies nobody looks exactly like one that works")

(def [ok3 err3] (protect (start {} :prod)))
(assert (not ok3) "and so is a production composition with no delivering channel at all")
(assert (string/find ":void/notify-mail" (string err3)) "naming what to compose")

# -- a booted notifier ---------------------------------------------------

(def boot (start {:notify {:channels [:memory :log]}}))

(defer (test/stop! boot)
  (notify/clear-outbox!)

  (assert (deep= [:memory :log] (notify/active)))
  (assert (not (notify/queued?)) "without void/notify-jobs delivery is on this fiber")

  (def result (notify/send {:key :order/shipped
                            :title "Your order shipped"
                            :to {:email "ada@example.com"}}))
  (assert (string/has-prefix? "ntf_" (result :id)))
  (assert (= :order/shipped (result :key)))
  (assert (= 2 (length (result :results))) "one result per channel, in the order they were named")
  (assert (deep= @[:memory :log] (map |($ :channel) (result :results))))
  (assert (every? (map |(= :sent ($ :status)) (result :results))))
  (assert (notify/delivered? result))
  (assert (= 1 (length (notify/outbox))))
  (assert (= (result :id) (get-in (notify/outbox) [0 :id]))
          "the id is minted once and every channel carries it — which is what lets two of them be recognized as one event")

  # -- a channel with nothing to deliver to ------------------------------

  (put notify/channels :sms
       (channel/normalize {:name :sms :address :phone
                           :project (fn [n] (when (notify/address-for n {:address :phone}) n))
                           :deliver (fn [p] (channel/receipt :sms p))}))

  (def skipped (notify/send {:key :x :title "t"
                             :channels [:sms :memory]
                             :to {:email "ada@example.com"}}))
  (assert (= :skipped (get-in skipped [:results 0 :status]))
          "a projection that returns nil is not a failure: the notification was not that channel's business")
  (assert (= :not-addressed (get-in skipped [:results 0 :why])))
  (assert (= :sent (get-in skipped [:results 1 :status]))
          "and the channel beside it delivered")

  # -- one channel's failure is not another's ----------------------------

  (put notify/channels :boom
       (channel/normalize {:name :boom
                           :deliver (fn [_] (error "the far end is down"))}))

  (log/set-level! "void.notify" :fatal)
  (def partial (notify/send {:key :x :title "t"
                             :channels [:boom :memory]
                             :to {:email "ada@example.com"}}))
  (log/set-level! "void.notify" :error)
  (assert (= :failed (get-in partial [:results 0 :status])))
  (assert (= :deliver (get-in partial [:results 0 :stage])))
  (assert (string/find "far end is down" (get-in partial [:results 0 :error])))
  (assert (= :sent (get-in partial [:results 1 :status]))
          "a webhook that times out must not swallow the letter going out beside it")
  (assert (notify/delivered? partial) "and something did happen, which is what the caller asks")

  # -- the receipt hook --------------------------------------------------

  (def heard @[])
  (notify/listen! :probe (fn [r] (array/push heard (r :channel))))
  (notify/send {:key :x :title "t" :channels [:memory] :to {:email "a@b.co"}})
  (notify/unlisten! :probe)
  (assert (deep= @[:memory] heard) "every delivery passes through the receipt listeners")

  # -- an unknown channel named by the call ------------------------------

  (assert (not (first (protect (notify/send {:key :x :title "t" :channels [:carrier-pigeon]
                                             :to {:email "a@b.co"}}))))
          "a notification that names a channel nobody contributed is a bug in the calling code, not a delivery failure")

  # -- the CLI -----------------------------------------------------------

  (def cli (from-pairs (map |[($ :name) $] (plugin/extension boot :void.core/cli))))
  (assert (get cli :notify/status))
  (assert (get cli :notify/send))
  (assert (get cli :notify/outbox))
  (assert (not (first (protect (((cli :notify/status) :fn) "extra"))))
          "a CLI command with arguments it does not take says so")
  (notify/clear-outbox!)
  (((cli :notify/send) :fn) "ada@example.com")
  (assert (= 1 (length (notify/outbox)))
          "void notify send is how a deployment finds out whether it notifies anybody at all")

  # -- health ------------------------------------------------------------

  (put notify/channels :sick
       (channel/normalize {:name :sick
                           :deliver (fn [_] nil)
                           :health (fn [] (error "the far end is unreachable"))}))
  (def health (first (filter |(= :notify/channels ($ :name))
                             (plugin/extension boot :void.core/health))))
  (def h ((health :fn)))
  (assert (= :up (h :status)))
  (assert (index-of :memory (h :channels)))
  (assert (not (h :queued)))

  (put notify/settings :channels [:memory :sick])
  (def sick ((health :fn)))
  (assert (= :down (get-in sick [:detail :sick :status]))
          "a channel whose own check threw says so, rather than taking the health endpoint down with it")
  (put notify/settings :channels [:memory :log])

  (put notify/channels :sms nil)
  (put notify/channels :boom nil)
  (put notify/channels :sick nil))

# -- [:notify :queue] true without a queue -------------------------------

(def [ok4 err4] (protect (start {:notify {:channels [:memory] :queue true}})))
(assert (not ok4) "[:notify :queue] true without a queue in the composition is a boot error")
(assert (string/find "void/notify-jobs" (string err4)) "naming what is missing")
