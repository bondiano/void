### void/mail-jobs — delivery off the request path (ADR-0026 §5).
###
### Composing this plugin is the whole of "send mail through a queue".
### It installs one function on `mail/enqueue`, and from that moment
### `mail/send` hands its delivery to `void/jobs` instead of to the
### transport — the *call site does not change*, because whether this
### deployment has a worker is a fact about the deployment.
###
### **What is queued is the rendered letter**, not the arguments that
### would render it. A message rendered on the worker would be rendered
### without the request that meant it: no identity in the dyn, no
### locale, no `:void.html/csrf` slot, and a different Message-ID on
### every retry. So `mail/send` renders here and queues the octets, and
### the retry sends *the same letter* — which costs a larger job
### payload and is worth it.
###
### **A 5xx is not retried.** The job asks the failure whether the
### server already gave its final answer (`mail/permanent-failure?`):
### a rejected mailbox comes back as a completed job whose result says
### it was rejected, and only a 4xx or a broken connection is thrown
### for the queue to retry. Retrying "no such user here" five times
### with exponential backoff is how a mailer gets a relay to rate-limit
### it.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/jobs :as jobs)
(import ./init :as mail)

(def log-ns "void.mail.jobs")

(def queue-name
  ``The queue mail goes through. Fixed rather than configured: the
  policy that a deployment tunes (concurrency, rate limit, attempts)
  is `[:jobs :queues :mail]`, which is where every other queue's
  policy already lives, and a second place to spell the name would
  only be a way for the two to disagree.``
  :mail)

(jobs/defjob mail-deliver
  ``Deliver one rendered mail through the active transport. The
  argument is a delivery — `{:message :bytes :id :at}` — as
  `mail/send` built it.``
  {:queue :mail :max-attempts 5 :timeout 120}
  [delivery]
  (def [ok result] (protect (mail/deliver! delivery)))
  (cond
    ok result
    (mail/permanent-failure? result)
    (do
      (log/error "mail rejected" :ns log-ns
                 :id (get delivery :id)
                 :to (get-in delivery [:message :recipients])
                 :code (get result :code)
                 :err (get result :message))
      # a completed job with a rejection in its result: the server has
      # answered, and there is nothing a retry can change
      {:rejected true
       :code (get result :code)
       :message (get result :message)
       :id (get delivery :id)})
    (error result)))

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   # after :mail/configure (400), so that a queue is installed on a
   # mailer that already knows its transport
   :phase 500
   :name :mail-jobs/install
   :doc "Route mail/send through void/jobs"
   :fn (fn install [_]
         (set mail/enqueue
              (fn enqueue-mail [delivery] (jobs/enqueue :mail-deliver delivery)))
         (log/info "mail goes through the queue" :ns log-ns :queue queue-name))})

(plugin/defplugin void/mail-jobs
  :doc "Delivery through void/jobs: mail/send queues the rendered letter and a worker sends it, with the queue's retry policy — and a permanent rejection is recorded rather than retried."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/mail ">=0.0.1" :void/jobs ">=0.0.1"})
