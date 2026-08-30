### The heavy half of a bulk (ADR-0029 §7, §10).
###
### Three claims. An action declared with `:job` — or a selection over
### `[:admin :bulk :inline-limit]` — does not run in the request. The
### page it answers with is a progress page over the job record's own
### state, so nothing about the `:void/jobs-backend` contract had to
### change for it. And a composition that declares such an action
### without composing `:void/admin-jobs` does not start, because the
### moment to find that out is not the moment somebody presses the
### button.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/test :as test)
(import void/db :as db)
(import void/jobs :as jobs)
(import void/admin :as admin)
(import void/authz :as authz)

(log/set-level! nil :error)

(db/defentity Note
  {:id [:int {:db/pk true :db/type "integer"}]
   :title [:string {:min 1 :max 60 :db/type "text"}]
   :done [:boolean {:db/type "integer"}]}
  :db/table "notes")

(admin/defresource-admin notes Note
  :list [:id :title :done]
  :form [:title :done]
  :order-by [[:id :asc]]
  :actions {:finish {:label "Finish"
                     :job true
                     :apply (fn [row req] (db/save! (put row :done true)))}
            :touch {:label "Touch"
                    :apply (fn [row req] (db/save! (put row :done true)))}})

(authz/defpolicy :staff "Everybody, in this test." [_] true)

(def db-path
  (string (or (os/getenv "TMPDIR") "/tmp") "/void-admin-jobs-" (os/time) ".sqlite3"))

(def core-plugins
  ["void/http/init" "void/html/init" "void/htmx/init"
   "void/db/init" "void/db-sqlite/init" "void/db/http"
   "void/authz/init" "void/authz/http" "void/admin/init"])

(defn- config [&opt extra]
  {:env @{}
   :cli (merge {:http {:port 0}
                :db-sqlite {:path db-path}
                :db {:n1-guard :off}
                # the queue runs the handler inline, right here — the
                # switch void/jobs ships for exactly this (state/enqueue-with)
                :jobs {:enabled false}
                :admin {:access :staff :bulk {:inline-limit 2}}}
               (or extra {}))})

(defn- done?
  ``Is the row marked done? sqlite hands a boolean column back as 0 or
  1, and 0 is truthy in Janet — an assertion written as `(row :done)`
  would pass whatever the value was.``
  [id]
  (def v (get (db/find Note id) :done))
  (or (true? v) (= 1 v)))

(defn- seed! []
  (db/execute-sql "DROP TABLE IF EXISTS notes" [] {:kind :write :prepared false})
  (db/execute-sql
    (string "CREATE TABLE notes (id integer primary key autoincrement, "
            "title text not null, done integer not null default 0)")
    [] {:kind :write :prepared false})
  (each t ["a" "b" "c" "d"]
    (db/execute-sql "INSERT INTO notes (title, done) VALUES (?, 0)" [t] {:kind :write})))

# -- without the plugin, the composition does not start ------------------

(def [ok err]
  (protect (test/start! {:plugins core-plugins
                         :profile :test
                         :config (config)
                         :only [:http/kernel :db/pool :authz/registry]})))
(assert (not ok) "a :job action with nothing to run it must fail the boot")
(assert (string/find "void/admin-jobs" (string err))
        "and the message must name the plugin that would run it")
(assert (string/find "notes" (string err)) "...and the action that asked")

# -- with it, the bulk goes to the queue ---------------------------------

(def boot
  (test/start!
    {:plugins [;core-plugins "void/jobs/init" "void/admin/jobs"]
     :profile :test
     :config (config)
     :only [:http/kernel :db/pool :authz/registry :jobs/queue]}))

(defer (test/stop! boot)
  (seed!)
  (def c (test/client boot))
  (defn csrf [resp]
    (first (peg/match ~(* (thru `name="_csrf" value="`) (<- (to `"`)))
                      (test/text resp))))

  # no void/security here, so the slot renders nothing and no token is
  # needed — the admin's forms do not depend on it being composed
  (def confirm (test/inject c {:uri "/admin/notes/-/bulk/finish?ids=1,2"}))
  (assert (= 200 (confirm :status)))
  (assert (string/find ">2</span>" (test/text confirm)))

  (def applied (test/inject c {:method :post :uri "/admin/notes/-/bulk/finish"
                               :form {:ids "1,2"}}))
  (assert (= 200 (applied :status)) (string "bulk: " (applied :status)))
  (def page (test/text applied))
  (assert (string/find "admin-progress" page)
          "an action declared with :job answers with a progress page, not a redirect")
  (assert (string/find "/-/progress/" page) "and the page names the job it is watching")

  # [:jobs :enabled] false runs the handler inline, so by now the work is
  # done — which is what makes this assertion about the *runner* and not
  # about the queue's own timing
  (assert (done? 1) "the job did the work")
  (assert (done? 2))
  (assert (not (done? 3)) "and only to the selected rows")

  # the fragment the page polls is the record's state, and nothing else
  (def job-id
    (first (peg/match ~(* (thru "/-/progress/") (<- (to `"`))) page)))
  (def tick (test/inject c {:uri (string "/admin/notes/-/progress/" job-id)}))
  (assert (= 200 (tick :status)))
  # [:jobs :enabled] false means nothing was ever stored, so the record
  # is not there — and a record the backend does not hold stops the
  # polling instead of spinning on :pending forever
  (assert (string/find "gone" (test/text tick))
          "progress is the job record's own state — no contract grew a column for it")
  (assert (not (string/find "hx-trigger" (test/text tick)))
          "and a terminal state stops the page asking again")

  # an action with no :job still goes to the queue once the selection is
  # over [:admin :bulk :inline-limit]
  (def small (test/inject c {:method :post :uri "/admin/notes/-/bulk/touch"
                             :form {:ids "3"}}))
  (assert (= 303 (small :status)) "one row under the limit runs here and redirects")
  (def big (test/inject c {:method :post :uri "/admin/notes/-/bulk/touch"
                           :form {:ids "1,2,3,4"}}))
  (assert (string/find "admin-progress" (test/text big))
          "four rows over an inline-limit of two go to the queue")
  (assert (done? 4)))

# -- a per-process queue cannot carry a progress page across replicas ----

(def [fleet-ok fleet-err]
  (protect (test/start!
             {:plugins [;core-plugins "void/jobs/init" "void/admin/jobs"]
              :profile :test
              :config (config {:deploy {:shape :fleet}})
              :only [:http/kernel :db/pool :authz/registry :jobs/queue]})))
(assert (not fleet-ok) "under :fleet an in-heap queue must stop the boot")
(assert (or (string/find "one process" (string fleet-err))
            (string/find "in the heap" (string fleet-err))
            (string/find "shared" (string fleet-err)))
        (string "and say why: " (string fleet-err)))

(os/rm db-path)
(print "admin jobs-test ok")
