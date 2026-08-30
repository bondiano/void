### void/admin-jobs — the heavy half of a bulk action (ADR-0029 §7,
### §10).
###
### A separate plugin for the reason every other `-jobs` plugin in this
### repository is one: an admin with no heavy action must not drag a
### queue into the process. Compose it and an action declared with
### `:job` — or a selection over `[:admin :bulk :inline-limit]` — runs
### in the background and the confirmation becomes a progress page;
### leave it out and `void/admin` says so **at start**, naming this
### plugin, rather than at the moment somebody presses the button.
###
### **Progress is the state of the record.** `:pending`, `:running`,
### `:completed`, `:dead` — what the queue backend already stores for
### every job it holds. A percentage would have meant a new column in
### the `:void/jobs-backend` contract: eight functions, three backends
### and one conformance suite, edited for a widget. An action that
### wants a bar leaves one behind itself and reads it with its own
### `:progress`.
###
### **The subject rides with the job.** A bulk is N policy decisions,
### one per row, and a decision needs somebody to decide *about*. The
### identity that pressed the button is captured at enqueue and bound
### again in the worker under the key void/auth publishes it under, so
### `:admin.<resource>/<action>` sees the same subject it would have
### seen inline.
###
### **A progress page on the second replica has to find the job.** So a
### composition whose queue backend is per-process (`capabilities`
### says `:shared false`) and whose deployment says `:fleet` is refused
### at start — the same check, in the same words, as everything else
### that would work on one machine and lie on two (ADR-0030).

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/authz :as authz)
(import void/db :as db)
(import void/jobs :as jobs)
(import ./action :as act)
(import ./query :as q)
(import ./resource :as res)

(def log-ns "void.admin.jobs")

(def job-name
  "The one job this plugin defines: it takes a resource, an action and
  a selection, and does per row what the inline path does per row."
  :void.admin/bulk)

(def batch-size
  "Rows loaded at a time. A bulk over forty thousand rows must not
  become forty thousand instances in one heap."
  200)

(defn- run-bulk
  ``The handler. Everything it needs travelled as data — the where
  clause the confirmation page counted with, the action's name and the
  subject who asked — because a job runs in a process that never saw
  the request.``
  [payload]
  (def desc (res/resource! (keyword (payload :resource))))
  (def aname (keyword (payload :action)))
  (def action (or (get-in desc [:custom-actions aname])
                  (when (= :destroy aname) {:name :destroy :label "Delete"})
                  (errorf "admin bulk: %q has no action %q" (desc :name) aname)))
  (def sel {:where (payload :where)})
  (with-dyns [authz/identity-dyn (payload :subject)]
    (var after nil)
    (var done 0)
    (forever
      (def rows (q/selected-rows desc sel batch-size after))
      (when (empty? rows) (break))
      (each r rows
        (authz/ensure! (res/policy-name (desc :name) aname)
                       {:resource r :action aname})
        (def id (get r (get-in desc [:entity :pk])))
        (def before (act/snapshot-of r))
        (set after id)
        (if (= :destroy aname)
          (do (db/delete! (desc :entity) id)
              (act/announce! nil desc :destroy id before nil))
          (do ((action :apply) r nil)
              (act/announce! nil desc aname id before
                             (act/snapshot-of (db/find (desc :entity) id)))))
        (++ done)))
    (log/info "admin bulk done" :ns log-ns
              :resource (desc :name) :action aname :rows done)
    {:rows done}))

(jobs/define-job! job-name
                  {:queue :default :max-attempts 1}
                  {:fn run-bulk
                   :doc "Apply one admin action to a selection, row by row"})

# -- the runner ----------------------------------------------------------

(defn- progress-of
  ``The state of the job, as the backend has it. A record the backend
  no longer holds is `:gone` and not `:pending`: it was purged, or the
  queue was disabled and the handler ran inline — either way it is not
  going to start, and a page that polled `:pending` forever would be
  lying with a spinner.``
  [job-id action]
  (def rec (jobs/fetch job-id))
  (def base (if rec
              {:state (get rec :state)}
              {:state :gone
               :label "the queue no longer holds this job — it finished, or it was never queued"}))
  (if-let [f (and action (get action :progress))]
    (merge base (or (f job-id) {}))
    base))

(plugin/contribute! :void.admin/bulk-runner
  {:name :void/admin-jobs
   :enqueue
   (fn enqueue-bulk [{:resource rname :action aname :selection sel :request req}]
     (def rec (jobs/enqueue job-name
                            {:resource (string rname)
                             :action (string aname)
                             :where (get sel :where)
                             :subject (dyn authz/identity-dyn)}))
     (get rec :id))
   :progress progress-of})

# -- the check that belongs at start -------------------------------------

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 140
   :name :admin-jobs/require-shared-backend
   :doc "Under [:deploy :shape] :fleet, a per-process queue backend cannot carry an admin progress page between replicas — refuse at start"
   :fn (fn check [boot]
         (when (= :fleet (get-in boot [:deploy :shape]))
           (def caps (jobs/backend-capabilities (jobs/active-backend)))
           (unless (caps :shared)
             (errorf (string "the admin runs heavy actions as jobs, and the %q queue "
                             "backend lives in one process: a progress page served by "
                             "another replica would not find the job. Use a shared "
                             "backend (:void/jobs-db, :void/jobs-redis) or say "
                             "[:deploy :shape] :single")
                     (caps :name)))))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/admin-jobs
  :doc "The heavy half of an admin bulk action: an action declared with :job — or a selection over [:admin :bulk :inline-limit] — is enqueued instead of run inline, the confirmation becomes a progress page over the job record's own state, and the identity that asked rides along so the per-row policies decide about the same subject they would have decided about inline (ADR-0029 §7)."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/admin ">=0.0.1" :void/jobs ">=0.0.1"})
