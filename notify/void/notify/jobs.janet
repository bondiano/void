### void/notify-jobs — delivery off the request path (ADR-0040 §3).
###
### Composing this plugin is the whole of "send notifications through a
### queue". It installs one function on `notify/enqueue`, and from that
### moment `notify/send` hands each channel's payload to `void/jobs`
### instead of delivering it — the *call site does not change*, because
### whether this deployment has a worker is a fact about the
### deployment. The `void/mail-jobs` pose, one level up.
###
### **One job per channel, not one per notification.** They fail
### separately and they retry separately: a webhook endpoint that is
### down must not mail the letter a second time, and a rejected mailbox
### must not hold up the row in the bell. The cost is one record per
### channel per notification, which is the honest price of being able
### to say which of them actually went out.
###
### **What is queued is the projection**, not the notification: the
### letter was rendered inside the request that meant it — with its
### locale and its identity — and the retry sends that same letter with
### the same Message-ID (ADR-0026 §5, generalized in ADR-0040 §2).
###
### **A final answer is recorded, not retried.** The job asks the
### channel whether the failure was the far end's last word
### (`:permanent?`): a 5xx from SMTP or a 4xx from a webhook comes back
### as a completed job whose result says it was rejected, and only what
### might succeed later is thrown for the queue's policy to take.

(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/jobs :as jobs)
(import ./init :as notify)

(def log-ns "void.notify.jobs")

(def queue-name
  ``The queue notifications go through. Fixed rather than configured,
  for void/mail-jobs' reason: the policy a deployment tunes
  (concurrency, rate limit, attempts) is `[:jobs :queues :notify]`,
  which is where every other queue's policy already lives, and a
  second place to spell the name would only be a way for the two to
  disagree.``
  :notify)

(jobs/defjob notify-deliver
  ``Deliver one projected payload through one channel. The arguments
  are the channel's name and the payload its `:project` returned, as
  `notify/send` built them.``
  {:queue :notify :max-attempts 5 :timeout 120}
  [channel payload]
  (def [ok result] (protect (notify/deliver! channel payload)))
  (cond
    ok result
    (notify/permanent? (notify/channel-named channel) result)
    (do
      (log/error "notification rejected" :ns log-ns
                 :channel channel
                 :id (get payload :id)
                 :err (string result))
      # a completed job with the rejection in its result: the far end
      # has answered, and there is nothing a retry can change
      {:rejected true
       :channel channel
       :id (get payload :id)
       :message (string result)})
    (error result)))

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   # after :notify/configure (400), so the queue is installed on a
   # notifier that already knows its channels
   :phase 500
   :name :notify-jobs/install
   :doc "Route notify/send through void/jobs"
   :fn (fn install [_]
         (set notify/enqueue
              (fn enqueue-notification [channel payload]
                (jobs/enqueue :notify-deliver channel payload)))
         (log/info "notifications go through the queue" :ns log-ns :queue queue-name))})

(plugin/defplugin void/notify-jobs
  :doc "Delivery through void/jobs: notify/send queues each channel's projected payload and a worker delivers it, one job per channel so they retry apart — and a final answer from the far end is recorded rather than retried."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/notify ">=0.0.1" :void/jobs ">=0.0.1"})
