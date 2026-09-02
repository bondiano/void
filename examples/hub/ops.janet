### hub/ops — the commands an operator runs.
###
### `void hub work` exists because of something this application ran
### into on its first live delivery, and it is worth writing down.
###
### A CLI command starts the components it declares in `:needs` and
### nothing else — that is what lets `void jobs stats` answer without
### opening a port. `void jobs work` needs `:jobs/queue`, which is
### true of the worker and not of the **jobs**: this hub's job is a
### telegram delivery, telegram is https, and https is `:tls/lib` —
### a component the queue does not depend on. So the worker ran, the
### job failed five times with a clear message about libssl, and the
### notification died in the dead letter queue while `:void/tls` sat
### composed and unstarted in the very same process.
###
### The application knows what its jobs need, so the application says
### so: one command, the same worker, one more line in `:needs`.
### Whether the framework should learn this instead — a job declaring
### its own needs, or a notify channel declaring them — is a question
### for the wave (docs/ROADMAP.md), not something to paper over here
### with a `tls/load!` call that would ignore `[:tls]` config anyway.
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/jobs)
(import ./intake)

(def log-ns "hub.ops")

(plugin/contribute! :void.core/cli
  {:name :hub/work
   :read-only? false
   :doc "Run the worker with everything a delivery needs open: void hub work [--concurrency N]"
   # the order is the order the instances arrive in
   :needs [:jobs/queue :tls/lib]
   :fn (fn cli-work [queue _tls & args]
         (var concurrency nil)
         (var i 0)
         (while (< i (length args))
           (def arg (args i))
           (cond
             (= "--concurrency" arg)
             (do (set concurrency (scan-number (or (get args (inc i)) "")))
                 (+= i 2))
             (errorf "void hub work: unknown argument %q" arg)))
         (def w (jobs/make-worker queue
                                 (if concurrency {:concurrency concurrency} {})))
         (printf "working %s at concurrency %d — ^C to stop"
                 (string/join (map string (w :queues)) ", ")
                 (w :concurrency))
         (log/info "worker started with the TLS stack open" :ns log-ns)
         (with-dyns [jobs/queue-dyn queue]
           (jobs/run-worker! w)))})

# -- replay --------------------------------------------------------------
#
# `void hub replay <delivery>` is the other command, and it is the one
# that makes developing this application bearable. A webhook needs a
# public hostname to arrive at, so the usual way to change one line of
# ./route.janet is: a tunnel, a repository, and somebody to push to it.
# Replay says the bytes are already here — one real delivery, received
# once, routed again as many times as it takes (./intake.janet,
# `replay!`, for why it routes rather than receives).
#
# It starts three components and not the port: the database the row is
# in, the store the bytes are in, and the queue the notification goes
# on. Delivering it is the worker's job, which is why `:tls/lib` is not
# in this list — nothing here opens a socket to telegram.

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
               (print "run `void hub work` to deliver it")))))})

(plugin/defplugin hub/ops
  :doc "Operator commands: a worker that starts the components this application's jobs need, and a replay that routes a kept delivery again from the bytes it arrived as."
  :version "0.1.0"
  :requires {:void/jobs ">=0.0.1" :void/db ">=0.0.1" :void/storage ">=0.0.1"})
