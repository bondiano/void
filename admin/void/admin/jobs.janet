### void/admin-jobs — where the back office and the queue meet
###.
###
### A separate plugin for the reason every other `-jobs` plugin in this
### repository is one: an admin with no queue must not drag one into
### the process. Compose it and two things arrive together, because
### they are the same seam and have the same two dependencies:
###
### **The heavy half of a bulk action.** An action declared with
### `:job` — or a selection over `[:admin :bulk :inline-limit]` — runs
### in the background and the confirmation becomes a progress page;
### leave the plugin out and `void/admin` says so **at start**, naming
### it, rather than at the moment somebody presses the button.
###
### **A section that shows the queue.** Horizon and Sidekiq-web, at the
### scale of what `:void/jobs-backend` already answers: queues and
### their depth, the records of one filter, one record in full, and
### retry/discard for the dead letter queue. It is a `:void.admin/page`
### and not a `defresource-admin` because a queue is not an entity —
### there is no table, no primary key and no schema to project. What
### stands in for the declaration is the contract itself, and it grew
### nothing for this: `counts`, `list`, `fetch`, `retry!`, `remove!`,
### `clear!` are all of it.
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
### composition whose queue backend is per-process (`capabilities` says
### `:shared false`) and whose deployment says `:fleet` is refused at
### start — the same check, in the same words, as everything else that
### would work on one machine and lie on two.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/authz :as authz)
(import void/authz/policy :as policy)
(import void/db :as db)
(import void/html :as html)
(import void/http/errors :as errors)
(import void/jobs :as jobs)
(import ./action :as act)
(import ./context :as ctx)
(import ./jobs-view :as jview)
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

# -- the dashboard -------------------------------------------------------
#
# Horizon and Sidekiq-web. The pages are ordinary `:void.admin/page`
# contributions, so they are ordinary routes under the admin prefix with
# the admin's own shut-by-default gate, and the two actions are ordinary
# admin actions with policies of their own — `:admin.jobs/retry` and
# `:admin.jobs/discard`, narrowed by a `defpolicy` of that name and
# nothing else, exactly as an action of a resource is.
#
# The queue is not an entity, so this is not a `defresource-admin`:
# there is no table, no primary key and no schema to project. What
# stands in for the declaration is `:void/jobs-backend` itself — the
# depth table is `counts`, the listing is `list`, a record is `fetch`,
# and the actions are `retry!`, `remove!` and `clear!`. The contract
# grew nothing, which is the point: a dashboard is a reader.

(def section
  ``The name the section's policies are written under:
  `:admin.jobs/index`, `:admin.jobs/show`, `:admin.jobs/retry`,
  `:admin.jobs/discard` — `res/policy-name`, so a queue action and a
  resource action are named by one function and read as one listing in
  `void authz routes`.``
  :jobs)

(def section-actions
  "What an operator can ask of a queue: see it, see one record, put
  one back, drop one."
  [:index :show :retry :discard])

(defn- policy-of [action] (res/policy-name section action))

(def bulk-cap
  ``How many records one press of Retry all moves — the ten thousand
  `void jobs retry --state dead` stops at. A bulk that walked a queue
  of any depth would hold a request open for as long as the queue is
  deep; the operator presses it again, and the depth table says
  whether it is worth pressing.``
  10_000)

(def- state-set (tabseq [s :in jobs/record-states] s true))

(defn- param
  "One filter, from the query of a GET or the body of the confirmed
  POST — the confirmation carries the selection as hidden fields, and
  both roads describe the same listing."
  [req k]
  (def v (or (get-in req [:query k]) (get-in req [:form k])))
  (when (and (string? v) (not (empty? v))) v))

(defn- listing-state
  ``The listing the URL describes: {:queue :state :job :limit}, each
  nil for "any". A state that is not one of the five is dropped rather
  than passed on — the filter panel cannot produce one, and a hand-typed
  URL gets the honest "no record matches" instead of a page of nothing
  with a lie in the select.``
  [req]
  (def dflt (ctx/setting :per-page 25))
  (def asked (when-let [v (param req "limit")] (scan-number v)))
  (def limit (if (number? asked) (math/floor asked) dflt))
  {:queue (when-let [v (param req "queue")] (keyword v))
   :state (when-let [v (param req "state")
                     s (keyword v)]
            (when (in state-set s) s))
   :job (when-let [v (param req "job")] (keyword v))
   :limit (max 1 (min 1000 limit))
   :default-limit dflt})

(defn- snapshot
  "Everything the head of the page shows, in the two calls that
  answer it."
  []
  (def counts (jobs/counts))
  (def s (jobs/stats))
  {:counts counts
   :backend (s :backend)
   :enqueued (get s :enqueued 0)
   :duplicates (get s :duplicates 0)
   :queues (sorted (distinct [;(keys counts)
                              ;(jobs/queue-names (jobs/active-queue))]))
   :jobs (jobs/job-definitions)})

(defn- rows-of [st]
  (jobs/list-jobs {:queue (st :queue) :state (st :state)
                   :job (st :job) :limit (st :limit)}))

(defn index
  "The section: the queues, their depth, and the records of one
  filter. htmx swaps the half that moves; a browser without it gets
  the whole page from the same URL."
  [req]
  (def st (listing-state req))
  (def snap (snapshot))
  (def rows (rows-of st))
  (def now (os/clock :realtime))
  (if (act/partial? req)
    (html/fragment (jview/body-fragment snap rows st now))
    (act/page req (jview/index-page snap rows st now))))

(defn record
  "One record, with everything the queue stores for it."
  [req]
  (def r (or (jobs/fetch (get-in req [:params :id])) (errors/abort 404)))
  (act/page req (jview/record-page r (os/clock :realtime))))

(defn- action-of
  ``Which action a URL names, with its policy enforced here rather
  than on the route: the action is part of the path, which is the same
  shape and the same reason as a resource's bulk.``
  [req]
  (def a (keyword (get-in req [:params :action])))
  (unless (in {:retry true :discard true} a) (errors/abort 404))
  (authz/ensure! (policy-of a) {:action a})
  a)

(defn- refusal
  ``A refusal, as a page: 422 and a sentence. The built-in error page
  is terse outside dev, and the reason is the whole of the answer here
  — neither of the two refusals below is an accident, and neither is
  reachable from a button.``
  [req message]
  (def resp (act/page req (jview/notice-page message)))
  (put resp :status 422)
  resp)

(defn- not-dead
  ``Retry is for the dead letter queue and nothing else. A `:pending`
  record is already going to run; a `:running` one is being run right
  now, and reviving it would run it twice — `revive!` resets the
  attempt and releases no claim.``
  [state]
  (string "Retry puts a dead record back in the queue, and this one is "
          (string state) ". A record that is not dead is either going to run or is "
          "running: reviving it would run it twice. Discard it instead, or wait for "
          "the queue to finish with it."))

(defn- announce!
  ``What an operator did to the queue, as a log record. Not
  `:void.admin/changed`: that hook is about the rows of a resource —
  a subscriber reads `:before` and `:after` of one — and a job is not
  one. The trail of "who emptied the dead letter queue" belongs where
  `void jobs retry` leaves the same trail.``
  [action & kvs]
  (log/info (string "admin jobs " action) :ns log-ns
            :subject (let [id (dyn authz/identity-dyn)]
                       (when (dictionary? id)
                         (or (get id :subject) (get id :id) (get id :email))))
            ;kvs))

(defn record-action
  "Retry or discard one record. Both answer with the listing: after a
  discard the record is not there to go back to, and after a retry the
  queue is what the operator was watching."
  [req]
  (def a (action-of req))
  (def id (get-in req [:params :id]))
  (def r (or (jobs/fetch id) (errors/abort 404)))
  (if (and (= :retry a) (not= :dead (get r :state)))
    (refusal req (not-dead (get r :state)))
    (do
      (if (= :retry a) (jobs/retry! id) (jobs/remove-job! id))
      (announce! a :job (get r :job) :queue (get r :queue) :id id)
      (act/redirect-back req (jview/url "" {"queue" (get r :queue)})))))

(defn- selection
  ``What a bulk acts on: queue and state, the two `counts` and
  `clear!` take. The job filter of the listing is not among them and
  is dropped from the link rather than silently ignored behind it.``
  [st]
  {:queue (st :queue) :state (st :state)})

(defn- bulk-refusal
  ``The response a bulk that will not be run answers with, or nil. A
  bulk with no state would mean "everything", including the records a
  worker is holding right now — the page never offers one, and a
  hand-typed URL is told why rather than obeyed.``
  [req a sel]
  (cond
    (nil? (sel :state))
    (refusal req (string "A bulk here selects by queue and state — the two the backend's "
                         "own counts and clear! take — and this one names no state. "
                         "Filter the listing to a state first."))
    (and (= :retry a) (not= :dead (sel :state)))
    (refusal req (not-dead (sel :state)))
    nil))

(defn- selected-count [sel]
  (def counts (jobs/counts))
  (if (sel :queue)
    (get-in counts [(sel :queue) (sel :state)] 0)
    (jview/total-of counts (sel :state))))

(defn bulk-confirm
  "The page a bulk goes through: what it will do, how many records,
  and a sample — counted on the server, as every admin bulk is."
  [req]
  (def a (action-of req))
  (def sel (selection (listing-state req)))
  (or (bulk-refusal req a sel)
      (act/page req
                (jview/confirm-page a sel (selected-count sel)
                                    (jobs/list-jobs {:queue (sel :queue) :state (sel :state)
                                                     :limit 5})
                                    (os/clock :realtime)))))

(defn bulk-apply
  "The bulk itself. Discard is one `clear!`; retry is `bulk-cap`
  records at most, because there is no bulk revive in the contract and
  there is no reason to grow one for a button."
  [req]
  (def a (action-of req))
  (def sel (selection (listing-state req)))
  (or (bulk-refusal req a sel)
      (let [n (if (= :retry a)
                (do
                  (var moved 0)
                  (each r (jobs/list-jobs {:queue (sel :queue) :state :dead :limit bulk-cap})
                    (when (jobs/retry! (r :id)) (++ moved)))
                  moved)
                (jobs/clear! {:queue (sel :queue) :state (sel :state)}))]
        (announce! (string a " bulk") :queue (sel :queue) :state (sel :state) :records n)
        (act/redirect-back req (jview/url "" {"queue" (sel :queue)
                                              "state" (when (= :retry a) (sel :state))})))))

# -- the section, as contributions ---------------------------------------

(plugin/contribute! :void.admin/page
  {:name :jobs :label jview/title :path jview/path :method :get
   :handler index :policies [(policy-of :index)]})

(plugin/contribute! :void.admin/page
  {:name :jobs/bulk :path (string jview/path "/-/bulk/:action") :method :get
   :handler bulk-confirm})

(plugin/contribute! :void.admin/page
  {:name :jobs/bulk-apply :path (string jview/path "/-/bulk/:action") :method :post
   :handler bulk-apply})

(plugin/contribute! :void.admin/page
  {:name :jobs/record :path (string jview/path "/:id") :method :get
   :handler record :policies [(policy-of :show)]})

(plugin/contribute! :void.admin/page
  {:name :jobs/record-action :path (string jview/path "/:id/-/:action") :method :post
   :handler record-action})

(plugin/contribute! :void.admin/menu
  {:name :jobs :label jview/title :path jview/path})

(plugin/contribute! :void.admin/dashboard-widget
  {:name :jobs/queues
   :label jview/title
   :render (fn tile [_req]
             (def counts (jobs/counts))
             [:p
              [:a {:href (jview/url)}
               (string (jview/total-of counts :pending) " pending, "
                       (jview/total-of counts :running) " running, "
                       (jview/total-of counts :dead) " dead")]])})

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 430
   :name :admin-jobs/policies
   :doc "Register the section's four policies where the application has not — the name is on the route from the first boot, so narrowing 'who may empty the dead letter queue' is a defpolicy and nothing else"
   :fn (fn register [_boot]
         (each a section-actions
           (def name (policy-of a))
           (unless (policy/lookup name)
             (policy/register!
               {:name name
                :doc (string "Admin jobs " a
                             " — allows; define a policy of this name to narrow it")
                :fn (fn admin-jobs-policy [_] true)}))))})

# -- the check that belongs at start -------------------------------------

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 140
   :name :admin-jobs/require-shared-backend
   :doc "Under [:deploy :shape] :fleet, a per-process queue backend cannot carry an admin progress page between replicas, and the Jobs section would show whichever replica answered — refuse at start"
   :fn (fn check [boot]
         (when (= :fleet (get-in boot [:deploy :shape]))
           (def caps (jobs/backend-capabilities (jobs/active-backend)))
           (unless (caps :shared)
             (errorf (string "the admin runs heavy actions as jobs, and the %q queue "
                             "backend lives in one process: a progress page served by "
                             "another replica would not find the job, and the Jobs "
                             "section would show the queue of whichever replica "
                             "answered. Use a shared backend (:void/jobs-db, "
                             ":void/jobs-redis) or say [:deploy :shape] :single")
                     (caps :name)))))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/admin-jobs
  :doc "The back office and the queue, joined: an action declared with :job — or a selection over [:admin :bulk :inline-limit] — is enqueued instead of run inline, the confirmation becomes a progress page over the job record's own state, and the identity that asked rides along so the per-row policies decide about the same subject they would have decided about inline; and a Jobs section under the admin prefix shows the queues, their depth, the records of one filter and one record in full, with retry and discard for the dead letter queue as ordinary admin actions under :admin.jobs/retry and :admin.jobs/discard. Both halves are readers of the eight functions :void/jobs-backend already answers — the contract grew nothing for either."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/admin ">=0.0.1" :void/jobs ">=0.0.1"})
