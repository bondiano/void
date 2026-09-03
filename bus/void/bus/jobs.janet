### void/bus-jobs — the queue's lifecycle events on the bus.
###
### One sentence says how the two layers meet: jobs publishes its
### lifecycle events (`:completed`, `:failed`) onto the bus **when there
### is one**. This plugin is that "when there is
### one", and it is a plugin rather than a line in void/jobs for the
### reason void/mail-jobs is one: void/jobs must not import void/bus,
### because then every application with a queue would carry a message
### bus it never asked for, and the dependency would run backwards
### from the layer that is optional to the layer that is not.
###
### void/jobs left the seam ready in wave 2 — `jobs/listen!`, whose
### docstring says in as many words that it is "for the code that has
### no manifest — a test, a REPL, and (wave 3) the bridge that
### forwards these into void/bus". This is that bridge, and it is
### eleven lines of work:
###
###     :enqueued  -> :jobs/enqueued
###     :started   -> :jobs/started
###     :completed -> :jobs/completed
###     :failed    -> :jobs/failed
###     :dead      -> :jobs/dead
###     :stalled   -> :jobs/stalled
###
### **The payload is the record's summary, not the record.** A job's
### arguments are the one part of it most likely to hold a password
### reset token, an email address or an amount of money, and a bridge
### that put them on a topic every consumer in the fleet subscribes to
### would be a data-flow decision made on the application's behalf. So
### what goes out is what an audit or a dashboard needs — which job,
### which queue, which attempt, how long, and the error when there was
### one — and a consumer that needs the arguments looks the job up by
### its id.
###
### **Nothing here may fail a job.** A publish that throws (a full
### buffer, a database that has gone away) is logged and swallowed:
### the queue's business is the work, and a bus that is having a bad
### afternoon must not turn a completed job into a failed one.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/jobs :as jobs)
(import ./state :as state)

(def log-ns "void.bus.jobs")

(def listener-name
  "The name this bridge registers under with `jobs/listen!` —
  re-registering replaces it, which is what makes a reload idempotent."
  :bus/forward)

(def topics
  "The bus topic each job lifecycle event goes out on."
  (tabseq [e :in jobs/events] e (keyword "jobs/" e)))

(defn summary
  ``What a job event carries: enough to audit, chart and alert on, and
  nothing that would put a job's arguments on a topic the whole fleet
  can read (see the module docstring).``
  [event r extra]
  (def now (os/clock :realtime))
  @{:event (string event)
    :id (get r :id)
    :job (string (get r :job))
    :queue (string (get r :queue))
    :state (string (get r :state))
    :attempt (get r :attempt 0)
    :max-attempts (get r :max-attempts)
    :enqueued-at (get r :enqueued-at)
    :started-at (get r :started-at)
    :finished-at (get r :finished-at)
    :duration (when (and (get r :started-at) (get r :finished-at))
                (- (get r :finished-at) (get r :started-at)))
    :error (get r :error)
    :at (get extra :at now)})

(defn forward
  "Publish one job lifecycle event. Never throws: see the module
  docstring."
  [payload]
  (def event (get payload :event))
  (def topic (or (get topics event) (keyword "jobs/" event)))
  (def r (get payload :job {}))
  (def [ok err]
    (protect
      (state/publish topic (summary event r payload)
                     # the job's id is the correlation of everything
                     # that happens to it, so a listener can follow one
                     # job from :enqueued to :dead with one filter
                     {:correlation-id (get r :id)})))
  (unless ok
    (log/warn "job event not published" :ns log-ns
              :event event :id (get r :id)
              :err (if (string? err) err (describe err))))
  nil)

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   # after :bus/consume (800): a process that both runs jobs and
   # consumes their events should have the consumer up before the
   # first event is published, or the first few would be published
   # into a bus nobody is reading yet
   :phase 900
   :name :bus-jobs/bridge
   :doc "Forward void/jobs lifecycle events onto the bus"
   :fn (fn install [_]
         (jobs/listen! listener-name forward)
         (log/info "job lifecycle events go onto the bus" :ns log-ns
                   :topics (sorted (values topics))))})

(plugin/contribute! :void.core/hooks
  {:hook :before-stop
   :phase 100
   :name :bus-jobs/unbridge
   :doc "Stop forwarding before the bus goes away"
   :fn (fn uninstall [_] (jobs/unlisten! listener-name))})

(plugin/defplugin void/bus-jobs
  :doc "void/jobs's lifecycle events on the bus: every :enqueued, :started, :completed, :failed, :dead and :stalled goes out on a :jobs/* topic, correlated by job id and carrying the record's summary rather than its arguments."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/bus ">=0.0.1" :void/jobs ">=0.0.1"})
