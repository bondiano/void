### ops/cli — the command an operator runs.
###
### There used to be a second one, and its absence is the more
### interesting half of this file.
###
### A CLI command starts the components it declares in `:needs` and
### nothing else — that is what lets `void jobs stats` answer without
### opening a port. `void jobs work` needs `:jobs/queue`, which is true
### of the worker and not of the **jobs**: this hub's job is a telegram
### delivery, telegram is https, and https is `:tls/lib`, a component
### the queue does not depend on. So the worker ran, the job failed five
### times against a very clear message about libssl, and the
### notification went to the dead letter queue while `void/tls` sat
### composed and unstarted in the very same process.
###
### The hub carried its own `void hub work` — the same worker with one
### more line in `:needs` — until the framework learned the general form
### of it: a job (and a notify channel) declares what its work needs
### open, and `void jobs work` starts the union over the queues it
### serves. The declaration is one line in
### ../telegram/telegram.channel.janet now, which is where the fact
### actually lives, and this file is one command shorter.
###
### `void hub replay <delivery>` is the command that is left, and it is
### the one that makes developing this application bearable. A webhook
### needs a public hostname to arrive at, so the usual way to change one
### line of ../routing is: a tunnel, a repository, and somebody to push
### to it. Replay says the bytes are already here — one real delivery,
### received once, routed again as many times as it takes
### (../intake/intake.service.janet, `replay!`, for why it routes rather
### than receives).
###
### It starts three components and not the port: the database the row is
### in, the store the bytes are in, and the queue the notification goes
### on. Delivering it is the worker's job, which is why `:tls/lib` is not
### in this list — nothing here opens a socket to telegram.
(import void/core/plugin :as plugin)
(import void/jobs)
(import ../intake/intake.service :as intake)

(defn- outcome-of
  ``The end of one channel's line: the job when there is one, and
  otherwise the reason notify gave. A channel that was skipped because
  the notification is not addressed to it is a configuration question,
  and "skipped" on its own sends an operator to the logs for it.``
  [out]
  (cond
    (get out :job) (string " (job " (out :job) ")")
    (get out :why) (string " (" (out :why) ")")
    (get out :error) (string " — " (out :error))
    ""))

(plugin/contribute! :void.core/cli
  {:name :hub/replay
   :read-only? false
   :doc "Route a kept delivery again: void hub replay DELIVERY (the sender's id, or the row id)"
   :needs [:db/pool :storage/store :jobs/queue]
   :fn (fn cli-replay [_db _store queue & args]
         (unless (= 1 (length args))
           (error "usage: void hub replay DELIVERY"))
         (def ident (first args))
         (def row (or (intake/find-delivery ident)
                      (errorf "no delivery %s — `void hub replay` takes the sender's delivery id or the row id"
                              ident)))
         (printf "replaying %s — %s %s%s, %d bytes"
                 (row :delivery-id) (row :source) (row :event)
                 (if-let [repo (row :repo)] (string " on " repo) "")
                 (row :size))
         # one notification per matching rule, one result per channel of
         # each: what the request path does, printed
         (def outs (mapcat |(get $ :results [])
                           (with-dyns [jobs/queue-dyn queue] (intake/replay! row))))
         (cond
           (empty? outs)
           (print "no rule covers it — nothing was sent, which is a rule question, not a failure")

           (do
             (each out outs
               (printf "  %-10s %s%s"
                       (string (out :channel)) (string (out :status)) (outcome-of out)))
             (when (some |(= :queued ($ :status)) outs)
               (print "run `void jobs work` to deliver it")))))})
