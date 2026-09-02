### The admin-as-MCP promise (ADR-0029), checked: the same
### declarations become MCP tools and resources with the same ABAC
### policies, and `void/admin` does not carry a line about MCP to make
### it happen.
###
### Two claims are worth more than the rest here. First, the input
### schema of the create tool **is** the resource's form schema — not a
### copy that will drift, the same value. Second, the gate of ADR-0031
### applies unchanged: reading is exposed, writing waits for an
### operator to name it, and nothing about that is special-cased for
### the admin.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/test :as test)
(import void/db :as db)
(import void/admin :as admin)
(import void/admin/mcp :as admin-mcp)
(import void/mcp :as mcp)
(import void/mcp/registry :as registry)
(import void/authz :as authz)
(import spork/json)

(log/set-level! nil :error)

(db/defentity Note
  {:id [:int {:db/pk true :db/type "integer"}]
   :owner [:string {:min 1 :max 30 :db/type "text"}]
   :title [:string {:min 1 :max 60 :db/type "text"}]
   :done [:boolean {:db/type "integer"}]}
  :db/table "notes")

(admin/defresource-admin notes Note
  :list [:id :title :done]
  :form [:title :done]
  :search [:title]
  :scope (fn [req] [:= :owner "ada"])
  :actions {:finish {:label "Finish"
                     :apply (fn [row req] (db/save! (put row :done true)))}})

# a declaration written for the agent and for an inline: no section in
# the menu, and every bit of it still readable here (ADR-0029 §1)
(admin/defresource-admin hidden Note :mount false :form [:title])

# a scope that needs an identity the call may not carry — what a tenant
# scope looks like to a stdio transport nobody signed in through
(admin/defresource-admin mine Note
  :mount false
  :list [:id :title]
  :form [:title]
  :scope (fn [_req] (dyn :test/identity)))

(authz/defpolicy :staff "Everybody, in this test." [_] true)

(def db-path
  (string (or (os/getenv "TMPDIR") "/tmp") "/void-admin-mcp-" (os/time) ".sqlite3"))

(def base-config
  {:http {:port 0}
   :db-sqlite {:path db-path}
   :db {:n1-guard :off}
   :admin {:access :staff}})

(defn- boot [&opt mcp-config]
  (test/start!
    {:plugins ["void/http/init" "void/html/init" "void/htmx/init"
               "void/db/init" "void/db-sqlite/init" "void/db/http"
               "void/authz/init" "void/authz/http"
               "void/admin/init" "void/mcp/init" "void/admin/mcp"]
     :profile :test
     :config {:env @{}
              :cli (merge base-config (if mcp-config {:mcp mcp-config} {}))}
     :only [:http/kernel :db/pool :authz/registry]}))

(defn- seed! []
  (db/execute-sql "DROP TABLE IF EXISTS notes" [] {:kind :write :prepared false})
  (db/execute-sql
    (string "CREATE TABLE notes (id integer primary key autoincrement, "
            "owner text not null default '', title text not null, "
            "done integer not null default 0)")
    [] {:kind :write :prepared false})
  (each [owner title] [["ada" "first"] ["ada" "second"] ["grace" "hers"]]
    (db/execute-sql "INSERT INTO notes (owner, title, done) VALUES (?, ?, 0)"
                    [owner title] {:kind :write})))

# -- the gate of ADR-0031, unchanged -------------------------------------

(def b (boot))
(defer (test/stop! b)
  (seed!)
  (def server (mcp/server-value))
  (def names (map |($ :name) (server :tools)))

  (assert (index-of "admin-notes-list" names) "reading is exposed")
  (assert (index-of "admin-notes-get" names))
  (assert (index-of "admin-hidden-list" names)
          ":mount false is a declaration without a section, not a declaration withheld")
  (assert (nil? (index-of "admin-notes-create" names))
          "writing is withheld until an operator names it — silence means unknown")
  (assert (nil? (index-of "admin-notes-delete" names)))
  (assert (nil? (index-of "admin-notes-finish" names)))

  # the declaration is a resource, and it is the same value the pages
  # render from
  (def uris (map |($ :uri) (server :resources)))
  (assert (index-of "void://admin/notes" uris))
  (def decl (json/decode (((first (filter |(= "void://admin/notes" ($ :uri))
                                          (server :resources))) :read))
                         true))
  (assert (= "notes" (decl :name)))
  (assert (deep= @["id" "title" "done"] (decl :list)))
  (assert (= "admin.notes/destroy" (get-in decl [:policies :destroy]))
          "the agent is told the very policy names the routes carry")

  # ...and reading it passes the same two policies the index route
  # carries — a declaration names fields, actions and policies, and it
  # is not readable past the gate the pages answer to
  (authz/register-policy! {:name :admin.notes/index :fn (fn [_] "not staff here")})
  (def decl-res (first (filter |(= "void://admin/notes" ($ :uri)) (server :resources))))
  (def [readable refusal] (protect ((decl-res :read))))
  (assert (not readable) "the declaration resource is authorized like the index it describes")
  (assert (string/find "forbidden" (string refusal)))
  (authz/register-policy! {:name :admin.notes/index :fn (fn [_] true)})

  # -- and the tools run, through the same scope and the same policies ---
  (def list-tool (first (filter |(= "admin-notes-list" ($ :name)) (server :tools))))
  (assert (= "void/admin-mcp" (string (list-tool :plugin)))
          "a projected tool answers for its provenance with the projecting plugin")
  (def listed (json/decode (((list-tool :call) @{}) :text) true))
  (assert (= 2 (listed :total)) ":scope narrows for an agent exactly as it does for a person")
  (assert (deep= @["first" "second"] (sorted (map |($ :title) (listed :rows)))))
  (assert (deep= @[:done :id :title] (sorted (keys (first (listed :rows)))))
          (string "the list tool answers with the :list columns and nothing else — "
                  ":detail (and, undeclared, :detail is every column) belongs to get"))

  # an identity-dependent scope, on a call that carries no identity:
  # the scope answers nil, and nil narrows to no rows rather than to
  # the whole table
  (def mine-list (first (filter |(= "admin-mine-list" ($ :name)) (server :tools))))
  (def anon (json/decode (((mine-list :call) @{}) :text) true))
  (assert (= 0 (anon :total)) "no identity, no rows — a nil scope fails shut")
  (assert (empty? (anon :rows)))
  (def mine-get (first (filter |(= "admin-mine-get" ($ :name)) (server :tools))))
  (assert (((mine-get :call) @{:id 1}) :error?)
          "and a single row behind a nil scope is not found, not handed over")
  (with-dyns [:test/identity [:= :owner "ada"]]
    (def owned (json/decode (((mine-list :call) @{}) :text) true))
    (assert (= 2 (owned :total)) "with the identity, the same scope narrows as declared"))

  (def get-tool (first (filter |(= "admin-notes-get" ($ :name)) (server :tools))))
  (def outside ((get-tool :call) @{:id 3}))
  (assert (outside :error?) "a row outside the scope is not found, for the agent either")
  (assert (not (string/find "hers" (outside :text)))
          "and the refusal does not leak the row it is refusing")
  (assert (string/find "first" (((get-tool :call) @{:id 1}) :text))))

# -- the operator opens the writing half, by name ------------------------

(def b2 (boot {:tools [(admin-mcp/tool-key :notes "create")
                       (admin-mcp/tool-key :notes "finish")]}))
(defer (test/stop! b2)
  (seed!)
  (def server (mcp/server-value))
  (def names (map |($ :name) (server :tools)))
  (assert (index-of "admin-notes-create" names)
          "[:mcp :tools] opens one tool by name, and only that one")
  (assert (nil? (index-of "admin-notes-delete" names)))

  (def create (first (filter |(= "admin-notes-create" ($ :name)) (server :tools))))
  # the input schema of create *is* the form schema — one value, and the
  # proof is that the read-only field of the resource is absent from both
  (def props (get-in (create :input-schema) ["properties"]))
  (assert (get props "title"))
  (assert (nil? (get props "owner"))
          "a column the form does not name is a column the tool does not have")

  (def made (json/decode (((create :call) @{:title "third" :done false}) :text) true))
  (assert (= "third" (made :title)))
  (assert (db/one Note {:where [:= :title "third"]}) "the row is really there")
  # ...and it lands outside the scope, because :owner is not a field the
  # form declares — an agent cannot write what a person cannot write

  (def finish (first (filter |(= "admin-notes-finish" ($ :name)) (server :tools))))
  (def applied (json/decode (((finish :call) @{:ids [1 3]}) :text) true))
  (assert (= 1 (applied :applied))
          "a declared action is a tool, and it is the same per-row policy and the same scope")
  (assert ((db/find Note 1) :done)))

# -- a policy narrowed for the browser narrows for the agent -------------

(authz/register-policy! {:name :admin.notes/show :fn (fn [_] "tenant mismatch")})
(def b3 (boot))
(defer (test/stop! b3)
  (seed!)
  (def server (mcp/server-value))
  (def get-tool (first (filter |(= "admin-notes-get" ($ :name)) (server :tools))))
  (def out ((get-tool :call) @{:id 1}))
  (assert (get out :error?) "the action's own policy decides for the agent too")
  (assert (string/find "forbidden" (string/ascii-lower (get out :text)))
          "a refusal reaches the model as a sentence, not as a struct address")
  (assert (string/find "admin.notes/show" (get out :text))
          "and it names the policy the declaration already published")
  (assert (not (string/find "tenant mismatch" (get out :text)))
          "the *reason* is for the decision log, never for the caller (ADR-0024 §3)"))
(authz/register-policy! {:name :admin.notes/show :fn (fn [_] true)})

# -- the start-time warning about a derived projection -------------------
#
# A hash column added to an entity for the writes silently joins a
# *derived* :list and :detail — and from there the show page and both
# read tools. The heuristic warns; it never refuses to boot, and it
# never second-guesses a projection somebody spelled out.

(db/defentity Cred
  {:id [:int {:db/pk true :db/type "integer"}]
   :name [:string {:db/type "text"}]
   :api-token [:optional [:string {:db/type "text"}]]}
  :db/table "creds")

(admin/defresource-admin creds Cred :mount false :form [:name])
(def warned (admin/secret-projection-warnings))
(assert (some |(and (= :creds ($ :resource)) (= :detail ($ :projection))) warned)
        "a derived :detail over a secret-looking column is warned about")
(assert (some |(and (= :creds ($ :resource)) (= :list ($ :projection))) warned)
        "and so is a derived :list — the list tool reads it two hundred rows at a time")
(admin/defresource-admin creds Cred :mount false :form [:name]
  :list [:id :name] :detail [:id :name])
(assert (not (some |(= :creds ($ :resource)) (admin/secret-projection-warnings)))
        "a projection the declaration spelled out is trusted as written")
(admin/deregister! :creds)

(os/rm db-path)
(print "admin mcp-test ok")
