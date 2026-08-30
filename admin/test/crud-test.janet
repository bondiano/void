### The admin, end to end, through the production stack (ADR-0017:
### routing, lifecycle stages, middleware, the :void.db/txn wrapper,
### CSRF, rendering, wire bytes — everything but the socket).
###
### The suite runs the same CRUD **twice**: once with no HX-* header
### anywhere, and once with them. That is not thoroughness for its own
### sake — ADR-0029 §9 claims that htmx makes the admin responsive and
### never makes it *work*, and a claim like that is either checked or
### false. The plain pass is the one that would break first, so it goes
### first.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/test :as test)
(import void/db :as db)
(import void/admin :as admin)
(import void/authz :as authz)

(log/set-level! nil :error)

# -- the application -----------------------------------------------------

(db/defentity Note
  {:id [:int {:db/pk true :db/type "integer"}]
   :owner [:string {:min 1 :max 30 :db/type "text"}]
   :title [:string {:min 1 :max 60 :db/type "text"}]
   :body [:optional [:string {:db/type "text"}]]
   :done [:boolean {:db/type "integer"}]
   :hits [:optional [:int {:db/type "integer"}]]}
  :db/table "notes"
  :db/rels {:tags [:has-many :Tag :note-id]})

(db/defentity Tag
  {:id [:int {:db/pk true :db/type "integer"}]
   :note-id [:int {:db/fk :Note :db/type "integer"}]
   :label [:string {:min 1 :max 30 :db/type "text"}]}
  :db/table "tags"
  :db/rels {:note [:belongs-to :Note :note-id]})

(def the-owner
  ``Who this request is for. A real application reads it off the
  identity; the point of the test is only that `:scope` gets a
  request and returns a where-clause.``
  (fn [req] (get-in req [:query "as"] "ada")))

(admin/defresource-admin notes Note
  :title "Notes"
  :list [:id :title :done :hits]
  :search [:title]
  :filters [:done]
  :sortable [:id :title]
  :editable [:title]
  :form [:title :body :done :hits]
  :readonly [:hits]
  :order-by [[:id :asc]]
  :per-page 2
  :scope (fn [req] [:= :owner (the-owner req)])
  :inlines {:tags {:style :table :fields [:label]}}
  :actions {:finish {:label "Finish"
                     :apply (fn [row req] (db/save! (put row :done true)))}})

(admin/defresource-admin tags Tag :mount false :form [:label])

(authz/defpolicy :staff "Everybody, in this test." [_] true)

(def plugins
  ["void/http/init" "void/html/init" "void/htmx/init"
   "void/db/init" "void/db-sqlite/init" "void/db/http"
   "void/crypto/init" "void/security/init"
   "void/authz/init" "void/authz/http"
   "void/admin/init"])

(def db-path
  (string (or (os/getenv "TMPDIR") "/tmp") "/void-admin-test-" (os/time) ".sqlite3"))

(def opts
  {:plugins plugins
   :profile :test
   :config {:env @{}
            :cli {:http {:port 0}
                  :db-sqlite {:path db-path}
                  :db {:n1-guard :off}
                  :security {:signing-key "0123456789abcdef0123456789abcdef"}
                  :admin {:access :staff}}}})

(defn- seed! []
  (db/execute-sql "DROP TABLE IF EXISTS tags" [] {:kind :write :prepared false})
  (db/execute-sql "DROP TABLE IF EXISTS notes" [] {:kind :write :prepared false})
  (db/execute-sql
    (string "CREATE TABLE notes (id integer primary key autoincrement, "
            "owner text not null default '', title text not null, body text, "
            "done integer not null default 0, hits integer default 0)")
    [] {:kind :write :prepared false})
  (db/execute-sql
    (string "CREATE TABLE tags (id integer primary key autoincrement, "
            "note_id integer not null, label text not null)")
    [] {:kind :write :prepared false})
  (each [owner title done] [["ada" "first" 0] ["ada" "second" 1] ["ada" "third" 0]
                            ["grace" "hers" 0]]
    (db/execute-sql "INSERT INTO notes (owner, title, done, hits) VALUES (?, ?, ?, 0)"
                    [owner title done] {:kind :write}))
  (db/execute-sql "INSERT INTO tags (note_id, label) VALUES (1, 'red')" [] {:kind :write}))

# -- helpers -------------------------------------------------------------

(defn- text [resp] (test/text resp))

(defn- done?
  ``Is the row marked done? sqlite hands a boolean column back as 0 or
  1, and 0 is truthy in Janet — an assertion written as `(row :done)`
  would pass whatever the value was.``
  [id]
  (def v (get (db/find Note id) :done))
  (or (true? v) (= 1 v)))

(defn- csrf-of [resp]
  (first (peg/match ~(* (thru `name="_csrf" value="`) (<- (to `"`))) (text resp))))

(defn- location [resp] (get-in resp [:headers "location"]))

(def kernel-only
  ``Everything the requests need and nothing that opens a port: the
  kernel, the pool the handlers write through and the policy registry
  the gate is in.``
  [:http/kernel :db/pool :authz/registry :crypto/lib])

(defn- run-suite [label hx]
  (def note (fn [msg] (print "  [" label "] " msg)))
  (def boot (test/start! (merge opts {:only kernel-only})))
  (defer (test/stop! boot)
    (seed!)
    (def c (test/client boot))
    (defn get* [uri &opt spec]
      (test/inject c (merge {:uri uri :headers (if hx {"hx-request" "true"} {})}
                            (or spec {}))))
    (defn post [uri token spec]
      (test/inject c (merge {:method :post :uri uri
                             :headers (merge {"x-csrf-token" token}
                                             (if hx {"hx-request" "true"} {})
                                             (get spec :headers {}))}
                            (let [s (merge {} spec)] (put s :headers nil) s))))

    # -- the list ---------------------------------------------------------
    (def listing (get* "/admin/notes"))
    (assert (= 200 (listing :status)) "the list answers")
    (def body (text listing))
    (assert (string/find "first" body) "ada's rows are there")
    (assert (not (string/find "hers" body))
            ":scope keeps another owner's row off the page entirely")
    (if hx
      (assert (not (string/find "<html" body))
              "an HX-Request gets the rows and no frame")
      (assert (string/find "<html" body) "a browser gets a whole page"))
    (assert (string/find "3 rows" body)
            "the count is the scoped count, not the table's")
    (note "list scoped and counted")

    # pagination counts what it shows: :per-page 2 over three scoped rows
    (assert (string/find "page 1 of 2" body) "two pages")
    (def page2 (get* "/admin/notes?page=2"))
    (assert (string/find "third" (text page2)) "the second page has the third row")

    # search and filter narrow both the rows and the count
    (def searched (get* "/admin/notes?q=sec"))
    (assert (string/find "second" (text searched)))
    (assert (not (string/find "first" (text searched))))
    (assert (string/find "1 row" (text searched)) "the count follows the search")
    (def filtered (get* "/admin/notes?done=true"))
    (assert (string/find "1 row" (text filtered)) "and the filter")
    (note "search, filter and pagination agree with the count")

    # sorting only on a declared column; anything else is ignored, not
    # compiled into SQL
    (assert (= 200 ((get* "/admin/notes?sort=owner&dir=asc") :status))
            "a column that is not :sortable is ignored, never injected")

    # -- create -----------------------------------------------------------
    (def form (get* "/admin/notes/new" {:headers {}}))
    (assert (= 200 (form :status)))
    (def token (csrf-of form))
    (assert token "the form carries the CSRF token void/security put in the slot")

    (def bad (post "/admin/notes" token {:form {:title "" :done "false"}}))
    (assert (= 422 (bad :status)) "the entity's own bounds are the form's")
    (assert (string/find "field-invalid" (text bad)) "and they are shown on the field")

    (def made (post "/admin/notes" token
                    {:form {:title "fourth" :body "b" :done "false" :hits "999"}}))
    (assert (or (= 303 (made :status)) (= 204 (made :status)))
            (string "create redirects, got " (made :status)))
    (def created (db/one Note {:where [:= :title "fourth"]}))
    (assert created "the row is in the database")
    (assert (= 0 (or (created :hits) 0))
            ":readonly is not decoration: the submitted value never reached the write")
    (note "create validates, writes, and refuses a read-only field")

    # the owner is not a form field here, so the new row has none — which
    # is exactly why it is invisible to the scope
    (assert (not (string/find "fourth" (text (get* "/admin/notes"))))
            "a row outside the scope does not appear")

    # -- read one ---------------------------------------------------------
    (assert (= 200 ((get* "/admin/notes/1") :status)))
    (assert (string/find "red" (text (get* "/admin/notes/1")))
            "the inline shows the child rows")
    (assert (= 404 ((get* "/admin/notes/4") :status))
            "another owner's row is not found — the same answer as one that does not exist")
    (note "detail scoped, inline rendered")

    # -- update -----------------------------------------------------------
    (def edit (get* "/admin/notes/1/edit" {:headers {}}))
    (def etoken (csrf-of edit))
    (def saved (post "/admin/notes/1" etoken {:form {:title "renamed" :done "true"}}))
    (assert (or (= 303 (saved :status)) (= 204 (saved :status))))
    (assert (= "renamed" ((db/find Note 1) :title)))
    # the first echelon: the scope never loads the row, so it is not
    # found — the same answer a row that does not exist gets
    (def stolen (post "/admin/notes/4" etoken {:form {:title "stolen"}}))
    (assert (= 404 (stolen :status)) (string "another owner's row: " (stolen :status)))
    (assert (= "hers" ((db/find Note 4) :title)) "and it is untouched")

    # the second echelon: a policy of the action's own name, with the
    # loaded row in :resource. This is what turns a *bug* in a scope
    # into a 403 instead of somebody else's row (ADR-0029 §3)
    (authz/register-policy!
      {:name :admin.notes/update
       :fn (fn [c] (or (= "renamed" (authz/attr c :resource/title))
                       "not this row"))})
    (assert (= 403 ((post "/admin/notes/2" etoken {:form {:title "nope"}}) :status))
            "the row-level policy sees the row it is deciding about")
    (assert (< ((post "/admin/notes/1" etoken {:form {:title "renamed" :done "true"}}) :status) 400)
            "...and the row that satisfies it still saves")
    # put the allowing one back — the rest of the suite is not about this
    (authz/register-policy! {:name :admin.notes/update :fn (fn [_] true)})
    (note "update writes, inside the scope and past the row's own policy")

    # -- a cell -----------------------------------------------------------
    (def cell (test/inject c {:method :patch :uri "/admin/notes/1/-/cell/title"
                              :headers {"x-csrf-token" etoken "hx-request" "true"}
                              :form {:title "celled"}}))
    (assert (= 200 (cell :status)) "the cell answers with itself")
    (assert (= "celled" ((db/find Note 1) :title)))
    (assert (= 404 ((test/inject c {:method :patch :uri "/admin/notes/1/-/cell/body"
                                    :headers {"x-csrf-token" etoken}
                                    :form {:body "no"}}) :status))
            "a column that is not :editable has no cell route to speak of")
    (note "cell edit")

    # -- inlines ----------------------------------------------------------
    (def added (post "/admin/notes/1/-/inline/tags" etoken {:form {:label "blue"}}))
    (assert (< (added :status) 400) (string "inline create: " (added :status)))
    (def blue (db/one Tag {:where [:= :label "blue"]}))
    (assert blue "the child row exists")
    (assert (= 1 (blue :note-id))
            "and its parent came from the URL — the form never carried the key")
    (def gone (test/inject c {:method :delete
                              :uri (string "/admin/notes/1/-/inline/tags/" (blue :id))
                              :headers (merge {"x-csrf-token" etoken}
                                              (if hx {"hx-request" "true"} {}))}))
    (assert (< (gone :status) 400))
    (assert (nil? (db/find Tag (blue :id))))
    (note "inline create and delete, parent from the URL")

    # -- bulk ---------------------------------------------------------------
    (def confirm (get* "/admin/notes/-/bulk/destroy?ids=2,3" {:headers {}}))
    (assert (= 200 (confirm :status)))
    (assert (string/find ">2</span>" (text confirm))
            "the confirmation names the number of rows, counted on the server")
    (def btoken (csrf-of confirm))

    # a number the client sends means nothing: ?all=1 is recounted here
    (def all (get* "/admin/notes/-/bulk/destroy?all=1&done=true" {:headers {}}))
    (def expected (db/count Note {:where [:and [:= :owner "ada"] [:= :done true]]}))
    (assert (pos? expected))
    (assert (string/find (string ">" expected "</span>") (text all))
            "\"every row the filter matches\" is the filter and the scope, re-run here")

    (def applied (post "/admin/notes/-/bulk/finish" btoken {:form {:ids "2,3"}}))
    (assert (< (applied :status) 400) (string "bulk apply: " (applied :status)))
    (assert (done? 3) "the action ran on every selected row")
    (note "bulk confirms with a server-side count, then applies")

    (def deleted (post "/admin/notes/-/bulk/destroy" btoken {:form {:ids "3"}}))
    (assert (< (deleted :status) 400))
    (assert (nil? (db/find Note 3)))

    # a forged identifier selects a row the scope never allowed
    (def forged (post "/admin/notes/-/bulk/destroy" btoken {:form {:ids "4"}}))
    (assert (< (forged :status) 400))
    (assert (db/find Note 4) "another owner's row survives a forged selection")
    (note "a forged identifier selects nothing")

    # -- delete one, the way a page without htmx does it -------------------
    (def dtoken (csrf-of (get* "/admin/notes/1/edit" {:headers {}})))
    (def dropped (test/inject c {:method :post :uri "/admin/notes/1?_method=delete"
                                 :headers (merge {"x-csrf-token" dtoken}
                                                 (if hx {"hx-request" "true"} {}))}))
    (assert (< (dropped :status) 400) (string "destroy: " (dropped :status)))
    (assert (nil? (db/find Note 1)))
    # ...and never out of a GET: the override is ignored, the request
    # stays the read it was, and the row is still there. A link that
    # changes state is a link the browser prefetches
    (assert (= 200 ((get* "/admin/notes/2?_method=delete") :status)))
    (assert (db/find Note 2) "a GET carrying ?_method=delete deletes nothing")
    (note "destroy through the verb an HTML form cannot send")

    (print "  [" label "] ok")))

(run-suite "plain" false)
(run-suite "htmx" true)

# -- the gate, from the outside -----------------------------------------

(def shut
  (test/start! (merge opts
                      {:only kernel-only
                       :config (merge (opts :config)
                                      {:cli (merge (get-in opts [:config :cli])
                                                   {:admin {}})})})))
(defer (test/stop! shut)
  (def c (test/client shut))
  (assert (= 403 ((test/inject c {:uri "/admin/notes"}) :status))
          "with no [:admin :access] every admin route refuses")
  (assert (= 403 ((test/inject c {:uri "/admin"}) :status))
          "including the dashboard"))

(os/rm db-path)
(print "admin crud-test ok")
