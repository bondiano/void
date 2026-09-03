### The projection into routes — and the gate.
###
### The claim under test is that the admin is not a dispatcher: every
### action is an entry in the one route table, with its own name, its
### own metadata and its own policies. If that is true, then `void
### routes` shows the admin line by line, `explain-route` explains it,
### and the gate can be a *route* concern rather than an admin one.
###
### The second claim is that the gate is shut. A composition that
### mounts the admin and says nothing else must refuse every admin
### request — and say which config key opens it.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/authz :as authz)
(import void/db :as db)
(import void/admin :as admin)
(import void/admin/mount :as mount)

(log/set-level! nil :error)

(db/defentity Note
  {:id [:int {:db/pk true}]
   :title [:string {:min 1 :max 60}]
   :body [:optional :string]
   :done :boolean}
  :db/table "notes")

(db/defentity Tag
  {:id [:int {:db/pk true}]
   :note-id [:int {:db/fk :Note}]
   :label [:string {:min 1 :max 30}]}
  :db/table "tags"
  :db/rels {:note [:belongs-to :Note :note-id]})

(admin/defresource-admin notes Note
  :list [:id :title :done]
  :search [:title]
  :filters [:done]
  :sortable [:id :title]
  :editable [:title]
  :actions {:finish {:label "Finish" :apply (fn [row req] nil)}})

(admin/defresource-admin tags Tag :mount false)

(def plugins
  ["void/http/init" "void/html/init" "void/htmx/init"
   "void/db/init" "void/db-sqlite/init" "void/db/http"
   "void/authz/init" "void/authz/http"
   "void/admin/init"])

(defn- boot
  ``The kernel only: the route table is built by the :before-start
  hooks either way, so the whole projection is on the table without a
  database anywhere near it.``
  [&opt cfg]
  (test/start!
    {:plugins plugins
     :profile :test
     :config {:env @{} :cli (merge {:http {:port 0}
                                            :db-sqlite {:path ":memory:"}}
                                           (or cfg {}))}
     :only [:http/kernel :authz/registry]}))

# -- the table -----------------------------------------------------------

(def b (boot))
(def table (http/routes-table))

(defn- entry [name] (get-in table [:by-name name]))

(each [name method pattern]
  [[:admin.notes/index :get "/admin/notes"]
   [:admin.notes/new :get "/admin/notes/new"]
   [:admin.notes/create :post "/admin/notes"]
   [:admin.notes/show :get "/admin/notes/:id"]
   [:admin.notes/edit :get "/admin/notes/:id/edit"]
   [:admin.notes/update :post "/admin/notes/:id"]
   [:admin.notes/destroy :delete "/admin/notes/:id"]
   [:admin.notes/bulk :get "/admin/notes/-/bulk/:action"]
   [:admin.notes/bulk-apply :post "/admin/notes/-/bulk/:action"]
   [:admin.notes/cell :patch "/admin/notes/:id/-/cell/:field"]
   [:admin/dashboard :get "/admin"]]
  (def e (entry name))
  (assert e (string "no route named " name))
  (assert (= method (e :method)) (string name " method"))
  (assert (= pattern (e :pattern)) (string name " pattern: " (e :pattern))))

# :mount false is a declaration without a section
(assert (nil? (entry :admin.tags/index)) ":mount false must not produce routes")
(assert (admin/lookup :tags) "...but it is still declared, which is what an inline target and an agent read")

# -- every route carries the gate, and its own policy --------------------

(each name [:admin.notes/index :admin.notes/create :admin.notes/destroy :admin/dashboard]
  (def ps (get-in (entry name) [:meta :void.authz/policy]))
  (assert (index-of :void.admin/access ps)
          (string name " must carry the gate")))

(assert (deep= [:void.admin/access :admin.notes/destroy]
               (tuple ;(get-in (entry :admin.notes/destroy) [:meta :void.authz/policy])))
        "the gate and the action's own policy — :concat already means AND")

# writers declare their transaction in metadata, not in a handler
(each name [:admin.notes/create :admin.notes/update :admin.notes/destroy
            :admin.notes/bulk-apply :admin.notes/cell]
  (assert (get-in (entry name) [:meta :void.db/txn])
          (string name " must declare :void.db/txn")))
(assert (nil? (get-in (entry :admin.notes/index) [:meta :void.db/txn]))
        "a read declares no transaction")

# the routes about one row hand that row to the policies
(each name [:admin.notes/show :admin.notes/edit :admin.notes/update :admin.notes/destroy]
  (assert (function? (get-in (entry name) [:meta :void.authz/resource]))
          (string name " must load its row for the policies")))
(assert (nil? (get-in (entry :admin.notes/index) [:meta :void.authz/resource]))
        "a list has no single row to decide about — that is what :scope is for")

# -- one policy per action, registered and allowing ----------------------

(each action [:index :new :create :show :edit :update :destroy :finish]
  (def p (authz/policy-of (admin/policy-name :notes action)))
  (assert p (string "no policy registered for " action))
  (assert ((p :fn) (authz/make-context {})) "the action's own policy allows until narrowed"))

# -- the gate is shut ----------------------------------------------------

(def gate (authz/policy-of :void.admin/access))
(def refusal ((gate :fn) (authz/make-context {})))
(assert (string? refusal) "with no [:admin :access] the gate must refuse")
(assert (string/find "[:admin :access]" refusal)
        "and the refusal must name the key that opens it")

(test/stop! b)

# -- ...and opens with one line of config --------------------------------

(authz/register-policy! {:name :staff :fn (fn [_] true)})
(def b2 (boot {:admin {:access :staff}}))
(def gate2 (authz/policy-of :void.admin/access))
(assert (true? ((gate2 :fn) (authz/make-context {})))
        "[:admin :access] names a policy, and the gate delegates to it")

# an application's own defpolicy wins over the generated allow-all
(test/stop! b2)
(authz/register-policy! {:name :admin.notes/destroy
                         :fn (fn [_] "only the owner may delete")})
(def b3 (boot {:admin {:access :staff}}))
(def own (authz/policy-of :admin.notes/destroy))
(assert (string? ((own :fn) (authz/make-context {})))
        "a policy the application defined is not replaced by the generated one")
(test/stop! b3)

# -- what the application says about its own admin's routes --------------
#
# `[:admin :route-meta]` rides on the group, so it reaches every
# projected route and a key the projection sets itself still wins. The
# case it exists for is an application that publishes an OpenAPI
# document: that document is a projection of the route table, and a
# back office is not part of a public API — `{:void.openapi/hidden
# true}` there is the whole of saying so (examples/shop).
(def b4 (boot {:admin {:access :staff :route-meta {:void.http/timeout 5}}}))
(def table4 (http/routes-table))
(each name [:admin/dashboard :admin.notes/index :admin.notes/destroy]
  (assert (= 5 (get-in table4 [:by-name name :meta :void.http/timeout]))
          (string name " must carry [:admin :route-meta]")))
(assert (deep= [:void.admin/access :admin.notes/destroy]
               (tuple ;(get-in table4 [:by-name :admin.notes/destroy
                                       :meta :void.authz/policy])))
        "and it adds to the metadata rather than replacing what the projection set")
(test/stop! b4)

# -- the routes a widget asks for ----------------------------------------
#
# A belongs-to whose target declares a `:search` is drawn by the link
# widget as an autocomplete, and an autocomplete needs a route to complete
# against. It is mounted under the resource's own `-/w/` namespace with
# the same gate — and it carries the one metadata key this package
# declares, which is what makes it distinguishable in `void routes` from
# an action of a resource.
(admin/defresource-admin note-tags Tag
  :list [:id :note-id :label]
  :form [:note-id :label])

(def b5 (boot {:admin {:access :staff}}))
(def wroute (get-in (http/routes-table) [:by-name :admin.note-tags/w-note-id-1]))
(assert wroute "the link widget's completion route must be on the table")
(assert (= "/admin/note-tags/-/w/note-id/complete" (wroute :pattern))
        (string "widget route pattern: " (wroute :pattern)))
(assert (true? (get-in wroute [:meta :void.admin/widget-route]))
        "and it must be marked as a widget's route, with a key void/admin declared")
(assert (index-of :void.admin/access (get-in wroute [:meta :void.authz/policy]))
        "the gate is on it like on everything else under the prefix")
(test/stop! b5)

(print "admin mount-test ok")
