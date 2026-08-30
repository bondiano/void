### The wave-4 half of the demo (ROADMAP 4.4, exit criterion 1): a back
### office over the entities this application already had, scoped per
### author, and the same declarations reachable by an agent through MCP
### under the same policies.
###
### What is being tested is mostly *absence*. ./admin.janet has no
### handlers and no templates, and this suite drives a full CRUD
### through pages that nobody in this repository wrote for the blog:
### they are a projection of `defentity` (ADR-0029). The pieces that
### did have to be written are one policy, one `:scope` and one
### function turning `:void.admin/changed` into a bus message — and the
### last of those is why the admin's edits land in the audit trail wave
### 3.6 built, next to the edits the application's own routes make.

(import ../test-support/paths)
(import ../test-support/postgres :as pg)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/init :as http)
(import void/db :as db)
(import void/auth :as auth)
(import void/authz :as authz)
(import void/admin :as admin)
(import ../main)
(import ../entities :as e)
(import ../audit :as audit)
(import void/bus :as bus)
(import void/mcp :as mcp)
(import spork/json)
(import void/bus/db :as busdb)
(import void/bus/state :as bus-state)

(def sqlite-path
  (string (or (os/getenv "TMPDIR") "/tmp") "/void-blog-admin-" (os/time) ".sqlite3"))

(def engines
  (filter identity
    [{:label "sqlite" :database :sqlite :config {:db-sqlite {:path sqlite-path}}}
     (when (pg/available?)
       {:label "postgres" :database :postgres
        :config {:db-postgres (pg/config)
                 :jobs-db {:table "blog_admin_test_jobs"}}})]))

(def app-tables
  ["audit_events" "comments" "articles" "authors"
   "auth_challenges" "auth_tokens" "schema_migrations"])

(defn- drop-app-tables! []
  (each t app-tables
    (db/execute-sql (string "DROP TABLE IF EXISTS " t) [] {:kind :write :prepared false})))

(defn- text [resp] (test/text resp))

(defn- settle
  ``Forward the outbox and let the consumer catch up. In a deployment
  this is the `:bus.db/forwarder` component and the consumer's own
  poll; here it is a call and a sleep, so what is asserted is the
  trail rather than the timing (the same helper ./audit-test uses).``
  []
  (busdb/forward-once! (bus-state/active-backend) 100)
  (ev/sleep 0.3))

(defn- token-of [resp]
  (first (peg/match ~(* (thru `name="_csrf" value="`) (<- (to `"`))) (text resp))))

(defn run-suite [engine]
  (def label (engine :label))
  (defn note [msg] (print "  [" label "] " msg))

  (def opts
    {:plugins (main/plugins (engine :database))
     :profile :test
     :config {:env @{}
              :cli (merge {:db {:n1-guard :strict :migrations {:dir "db/migrations"}}
                           :cache {:prefix (string "blog-admin-" label ":")}
                           :auth {:scrypt {:ln 10}}
                           :crypto {:kdf {:in-thread false}}
                           :mail {:transport :memory}
                           :bus-db {:poll-interval 0.05
                                    :forwarder {:enabled false}}}
                          (engine :config))}})

  (test/with-http [c (merge opts {:only [:http/kernel :cache/store :jobs/queue
                                         :crypto/lib :auth/registry :authz/registry
                                         :bus/broker :bus.db/schema]})]
    (drop-app-tables!)
    (db/migrate-up! {:dir "db/migrations"})

    # -- the admin is in the one route table -----------------------------
    #
    # Under [:authz :default :deny] the boot would have failed if any of
    # these carried no policy, so their presence here is already the
    # proof; naming them says which they are.
    (def table (http/routes-table))
    (each name [:admin/dashboard :admin.articles/index :admin.articles/edit
                :admin.articles/update :admin.articles/destroy
                :admin.authors/index :admin.audit-events/index]
      (assert (get-in table [:by-name name]) (string "no route named " name)))
    (assert (nil? (get-in table [:by-name :admin.comments/index]))
            "comments are declared for the inline and for an agent, not as a section")
    (assert (nil? (get-in table [:by-name :admin.authors/destroy]))
            ":only [:index :show] is a declaration, and it is the route table that shows it")
    (note "every action is a route, and the ones nobody declared are not there")

    # -- shut, until somebody signs in ------------------------------------

    (assert (= 403 ((test/inject c {:uri "/admin"}) :status))
            "the gate is a policy, and a visitor does not pass it")

    (assert (= 302 ((test/inject c {:uri "/register"
                                    :form {:name "Ada" :email "ada@example.com"
                                           :password "correct horse battery"}})
                    :status)))
    (def ada (db/one e/Author {:where [:= :email "ada@example.com"]}))
    (assert (= 200 ((test/inject c {:uri "/admin"}) :status))
            "...and a signed-in author does")
    (note "the gate opens for staff and for nobody else")

    # -- the list is scoped, and so is its count --------------------------

    (def home (test/inject c {:uri "/"}))
    (def token (token-of home))
    (each title ["ada one" "ada two"]
      (assert (< ((test/inject c {:uri "/articles"
                                  :headers {"x-csrf-token" token}
                                  :form {:title title :body "body of the article"}})
                  :status)
                 400)))
    # a second author's article, written straight to the table: this
    # suite is about what the admin *shows*, not about how it got there
    (def grace (db/insert! e/Author {:name "Grace" :email "grace@example.com"}))
    (db/insert! e/Article {:author-id (grace :id) :title "hers"
                           :body "not ada's" :created-at (e/now)})

    (def listing (test/inject c {:uri "/admin/articles"}))
    (assert (= 200 (listing :status)))
    (assert (string/find "ada one" (text listing)))
    (assert (not (string/find "hers" (text listing)))
            ":scope keeps another author's row off the page")
    (assert (string/find "2 rows" (text listing))
            "and off the count, which is the half a list gets wrong")
    (note "row-level scoping: the query and the count are one clause")

    # a search is the same clause plus a LIKE, and it counts too
    (def searched (test/inject c {:uri "/admin/articles?q=two"}))
    (assert (string/find "ada two" (text searched)))
    (assert (string/find "1 row" (text searched)))

    # -- editing through pages nobody wrote -------------------------------

    (def mine (db/one e/Article {:where [:= :title "ada one"]}))
    (def form (test/inject c {:uri (string "/admin/articles/" (mine :id) "/edit")}))
    (assert (= 200 (form :status)))
    (assert (string/find "field-title" (text form))
            "the form is a projection of the entity, so the column is a control")
    (def etoken (token-of form))
    (def saved (test/inject c {:method :post
                               :uri (string "/admin/articles/" (mine :id))
                               :headers {"x-csrf-token" etoken}
                               :form {:title "ada renamed" :body (mine :body)}}))
    (assert (< (saved :status) 400) (string "admin update: " (saved :status)))
    (assert (= "ada renamed" ((db/find e/Article (mine :id)) :title)))

    # another author's row is not editable from here, and it is not a
    # 403 with the row in the body — it was never loaded
    (def hers (db/one e/Article {:where [:= :title "hers"]}))
    (assert (= 404 ((test/inject c {:uri (string "/admin/articles/" (hers :id) "/edit")})
                    :status)))
    (assert (= "hers" ((db/find e/Article (hers :id)) :title)))
    (note "CRUD through a projection, inside the scope")

    # -- the comments of an article, on the article's page ----------------

    (def detail (test/inject c {:uri (string "/admin/articles/" (mine :id))}))
    (assert (string/find "Comments" (text detail)) "the inline is on the detail page")
    (def dtoken (token-of detail))
    (def added (test/inject c {:method :post
                               :uri (string "/admin/articles/" (mine :id) "/-/inline/comments")
                               :headers {"x-csrf-token" dtoken}
                               :form {:author-name "Reader" :body "nice one"}}))
    (assert (< (added :status) 400) (string "inline: " (added :status)))
    # not `comment`: that is a macro in Janet core, and `(comment x)`
    # would quietly become nil
    (def posted (db/one e/Comment {:where [:= :author-name "Reader"]}))
    (assert posted)
    (assert (= (mine :id) (posted :article-id))
            "the link to the article came from the URL — the form never carried it")
    (note "inline comments, with the foreign key out of reach of a forged POST")

    # -- the trail this application already kept --------------------------

    (settle)
    (def trail (audit/trail {:limit 50}))
    (def admin-lines (filter |(string/has-prefix? "admin/" ($ :topic)) trail))
    (assert (not (empty? admin-lines))
            "the admin announced its changes, and ./audit wrote them down")
    (assert (some |(string/find "ada renamed" ($ :detail)) admin-lines)
            "including what the row became")
    (assert (some |(= "author:" (string/slice ($ :actor) 0 7)) admin-lines)
            "and who did it")
    # nothing in this repository migrated a table for that: the trail is
    # the one wave 3.6 built, and the admin does not know it exists
    (assert (some |(not (string/has-prefix? "admin/" ($ :topic))) trail)
            "next to the lines the application's own routes wrote")
    (note "changes announced, not written: the trail is the application's")

    # -- deleting says how many, before it does anything ------------------

    (def confirm (test/inject c {:uri (string "/admin/articles/-/bulk/destroy?ids=" (mine :id))}))
    (assert (= 200 (confirm :status)))
    (assert (string/find ">1</span>" (text confirm))
            "the number of rows is counted on the server and said out loud")
    (assert (string/find "comments" (text confirm))
            "and so is what would go with them")
    (def ctoken (token-of confirm))
    (assert (< ((test/inject c {:method :post :uri "/admin/articles/-/bulk/destroy"
                                :headers {"x-csrf-token" ctoken}
                                :form {:ids (string (mine :id))}})
                :status)
               400))
    (assert (nil? (db/find e/Article (mine :id))))
    (assert (db/find e/Article (hers :id)) "and only that one")
    (note "a confirmation page with a server-side count")

    # -- and the same declarations, read by an agent ----------------------
    #
    # ROADMAP 4.4's last line and wave 4's first exit criterion: the
    # back office and the agent are two projections of one registry, so
    # there is nowhere for them to disagree. Nothing in ./admin.janet
    # mentions MCP, and nothing in void/admin does either.
    (def server (mcp/server-value))
    (def tools (map |($ :name) (server :tools)))
    (each name ["admin-articles-list" "admin-articles-get"
                "admin-authors-list" "admin-audit-events-list"
                # a resource with no section is still a resource here
                "admin-comments-list"]
      (assert (index-of name tools) (string "no tool named " name)))
    (each name ["admin-articles-create" "admin-articles-delete"]
      (assert (nil? (index-of name tools))
              (string name " writes, and writing waits for [:mcp :tools] to name it")))

    (def decl-res (first (filter |(= "void://admin/articles" ($ :uri))
                                 (server :resources))))
    (assert decl-res "the declaration is published as a resource")
    (def declared (json/decode ((decl-res :read)) true))
    (assert (= "admin.articles/destroy" (get-in declared [:policies :destroy]))
            "the agent is handed the very policy names the routes carry")
    (assert (deep= @["id" "title" "comment-count" "created-at"] (declared :list))
            "and the very columns the page shows")

    (def list-tool (first (filter |(= "admin-articles-list" ($ :name)) (server :tools))))

    # the gate is the admin's gate: an agent with no identity is refused
    # by `:blog/staff`, exactly as a browser with no cookie is
    (def anonymous ((list-tool :call) @{}))
    (assert (anonymous :error?) "no identity, no rows — the gate does not know who is asking")

    # with one, the tool runs through the same :scope as the page
    (def listed
      (with-dyns [authz/identity-dyn (auth/identity (string "author:" (ada :id)))]
        (json/decode (((list-tool :call) @{}) :text) true)))
    (assert (= 1 (listed :total))
            "one article is left after the delete above, and it is ada's")
    (assert (not (some |(= "hers" ($ :title)) (listed :rows)))
            "the other author's row is as invisible to the agent as it is to the page")
    (note "the same declarations, the same policies, for an agent")

    (print "  [" label "] ok")))

(each engine engines (run-suite engine))
(unless (pg/available?)
  (print "blog admin-test: SKIPPED the Postgres pass (set VOID_TEST_PG to a conninfo or a postgres:// url)"))
(os/rm sqlite-path)
(print "blog admin-test ok (" (string/join (map |($ :label) engines) ", ") ")")
