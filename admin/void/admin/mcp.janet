### void/admin-mcp — the same declarations, read by an agent.
###
### This is the payoff of deciding that a resource is a
### **value** and not a function that builds routes. Nothing here
### re-describes anything: the fields come from the descriptor, the
### input schema of `create` *is* `(desc :form-schema)` — the same
### value the HTML form validates against — the list is the same
### `./query` the list page pages through, and the authorization is
### the same two policies the routes carry, plus the same per-row
### policy on every single row.
###
### `void/admin` contains no line about MCP, and this plugin contains
### no second declaration. Adding a field to `defentity` adds it to
### the form, to the list, and to the tool an agent calls, in one
### edit.
###
### **The gate is the admin's gate.** An agent reaching a resource
### goes through `:void.admin/access` exactly as a browser does, so
### `[:admin :access]` closes both doors or neither. On top of it,
### `:void.mcp/tool`'s own gate applies: `list`, `get` and `describe`
### declare themselves read-only and are exposed; `create`, `update`,
### `delete` and every declared action do not, so an operator has to name
### them in `[:mcp :tools]` before an agent can call one. Silence means
### "unknown", and unknown is never offered.
###
### **`:mount false` is not `:hidden`.** A resource declared without
### top-level routes is still a resource here — that is the shape of a
### declaration written for the agent.

(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/schema :as schema)
(import void/authz :as authz)
(import void/db :as db)
(import void/admin/action :as act)
(import void/admin/context :as ctx)
(import void/admin/mount :as mount)
(import void/admin/query :as q)
(import void/admin/resource :as res)

# -- the request an agent does not have ----------------------------------

(defn- agent-request
  ``A `:scope` is `(fn [request] where)` and an agent's call is not an
  HTTP request. It gets one shaped like the ones a scope actually
  reads: the query parameters it was given, no params, and a marker
  saying where it came from. The identity is where it always is — the
  dyn key void/auth publishes — so a scope that narrows by tenant
  narrows the same way for a model as for a person. When no identity
  was published (a stdio transport, an HTTP gate below `:identity`), a
  scope that depends on one answers nil — and ./query narrows nil to
  no rows, so the call fails shut rather than wide.``
  [arguments]
  @{:method :get
    :path (ctx/prefix)
    :params @{}
    :query (tabseq [[k v] :pairs (get arguments :filters {})]
             (string k) (string v))
    :form @{}
    :void.admin/via :mcp})

(defn tool-key
  ``The keyword an admin tool is named by. `void/mcp` turns a slash
  into an underscore, and a model's tool name may hold nothing but
  `[a-z0-9_-]` — so the name is flat: `:admin-articles-list` becomes
  `admin-articles-list`, which reads as what it is.``
  [rname verb]
  (keyword "admin-" rname "-" verb))

(defn- all-optional
  "The same map schema with every entry optional — a patch names the
  fields it changes and nothing else."
  [sch]
  (def n (schema/normalize sch))
  (schema/merge {}
                (tabseq [[k sub] :in (n :children)]
                  k (if (= :optional (sub :type)) sub (schema/optional sub)))))

(defn- ensure!
  ``The gate and the action's own policy, exactly as the routes carry
  them. `decide` rather than `ensure!` for one reason: a refusal has to
  reach the model as a sentence, and `ensure!` raises the value the
  HTTP renderers turn into a 403 — a model handed that reads
  `<struct 0x…>`. The reason still goes only to the decision log
; what the agent is told is that it was refused, and by
  which named policy, which the declaration resource already tells it.``
  [desc action &opt row]
  (def names [mount/access-policy (res/policy-name (desc :name) action)])
  (def decision (authz/decide names (merge {:action action} (if row {:resource row} {}))))
  (unless (decision :allow)
    (errorf "forbidden: policy %q refused this call" (decision :policy)))
  decision)

(defn- row->data
  "One row as plain data — the declared detail fields, and nothing the
  declaration did not name."
  [desc row]
  (tabseq [f :in (desc :detail)] f (get row f)))

(defn- row->list-data
  ``One row as the *list* projects it — the `:list` columns that name a
  real field, and nothing else. The list page and the list tool must
  show the same columns: `:detail` is the show page's declaration, and
  a list tool that read it would hand an agent, two hundred rows at a
  time, the fields the declaration only meant for one row — or, when
  `:detail` was never declared, every column of the entity. A computed
  column (`:value` without a field) renders hiccup for a page and is
  skipped here.``
  [desc row]
  (tabseq [c :in (desc :list) :when (c :field)]
    (c :name) (get row (c :name))))

(defn- ok
  "A tool answers with a string. `json/encode` builds a buffer, and a
  buffer would reach the model as its printed representation."
  [value]
  (string (json/encode value)))

# -- tools ---------------------------------------------------------------

(defn- list-tool [desc]
  {:name (tool-key (desc :name) "list")
   :title (string "List " (desc :title))
   :doc (string "List rows of " (desc :title)
                ". Filters, search, sorting and paging are the ones the resource declared"
                (if (empty? (desc :search)) "" (string "; searched columns: "
                                                       (string/join (map string (desc :search)) ", ")))
                ". Returns {rows, total, page, per-page}.")
   :read-only? true
   :needs [:db/pool]
   :schema {:page [:optional [:int {:min 1}]]
            :per-page [:optional [:int {:min 1 :max 200}]]
            :q [:optional :string]
            :sort [:optional :keyword]
            :dir [:optional [:enum :asc :desc]]
            :filters [:optional :dictionary]}
   :fn (fn admin-list [_pool arguments]
         (def req (agent-request arguments))
         (each k [:page :per-page :q :sort :dir]
           (when-let [v (get arguments k)]
             (put (req :query) (string k) (string v))))
         (ensure! desc :index)
         (def st (q/state desc req {:per-page (ctx/setting :per-page 25)}))
         (ok {:rows (map |(row->list-data desc $) (q/rows desc req st))
              :total (q/total desc req st)
              :page (st :page)
              :per-page (st :per-page)}))})

(defn- get-tool [desc]
  {:name (tool-key (desc :name) "get")
   :title (string "Get one " (desc :singular))
   :doc (string "One row of " (desc :title) " by primary key, inside the same scope a person sees.")
   :read-only? true
   :needs [:db/pool]
   :schema {:id :any}
   :fn (fn admin-get [_pool arguments]
         (def req (agent-request arguments))
         (def row (q/find-scoped desc req (string (get arguments :id))))
         (unless row (errorf "%q %q not found" (desc :name) (get arguments :id)))
         (ensure! desc :show row)
         (ok (row->data desc row)))})

(defn- create-tool [desc]
  {:name (tool-key (desc :name) "create")
   :title (string "Create a " (desc :singular))
   :doc (string "Create one row of " (desc :title)
                ". The input schema is the resource's form schema — the very value "
                "the HTML form validates against, so a field the admin will not let a "
                "person write is a field this tool does not have.")
   :read-only? false
   :needs [:db/pool]
   :schema (desc :form-schema)
   :fn (fn admin-create [_pool arguments]
         (def req (agent-request {}))
         (ensure! desc :create)
         (def row (db/insert! (desc :entity) (act/with-defaults desc req arguments)))
         (act/announce! req desc :create (get row (get-in desc [:entity :pk]))
                        nil (act/snapshot-of row))
         (ok (row->data desc row)))})

(defn- update-tool [desc]
  {:name (tool-key (desc :name) "update")
   :title (string "Update a " (desc :singular))
   :doc (string "Patch one row of " (desc :title)
                " by primary key. Only the fields the form declares may be written.")
   :read-only? false
   :needs [:db/pool]
   :schema (schema/merge {:id :any} (all-optional (desc :form-schema)))
   :fn (fn admin-update [_pool arguments]
         (def req (agent-request {}))
         (def row (q/find-scoped desc req (string (get arguments :id))))
         (unless row (errorf "%q %q not found" (desc :name) (get arguments :id)))
         (ensure! desc :update row)
         (def before (act/snapshot-of row))
         (each fd (desc :form-fields)
           (when (in arguments (fd :name))
             (put row (fd :name) (get arguments (fd :name)))))
         (db/save! row)
         (act/announce! req desc :update (get arguments :id) before (act/snapshot-of row))
         (ok (row->data desc row)))})

(defn- delete-tool [desc]
  {:name (tool-key (desc :name) "delete")
   :title (string "Delete a " (desc :singular))
   :doc (string "Delete one row of " (desc :title) " by primary key.")
   :read-only? false
   :needs [:db/pool]
   :schema {:id :any}
   :fn (fn admin-delete [_pool arguments]
         (def req (agent-request {}))
         (def row (q/find-scoped desc req (string (get arguments :id))))
         (unless row (errorf "%q %q not found" (desc :name) (get arguments :id)))
         (ensure! desc :destroy row)
         (def before (act/snapshot-of row))
         (db/delete! (desc :entity) (get row (get-in desc [:entity :pk])))
         (act/announce! req desc :destroy (get arguments :id) before nil)
         (ok {:deleted (get arguments :id)}))})

(defn- action-tool [desc action]
  {:name (tool-key (desc :name) (string (action :name)))
   :title (string (get action :label (string (action :name))) " — " (desc :title))
   :doc (or (get action :doc)
            (string "Run the " (action :name) " action of " (desc :title)
                    " over the given rows. Every row passes the action's own policy."))
   :read-only? false
   :needs [:db/pool]
   :schema {:ids [:vector :any]}
   :fn (fn admin-action [_pool arguments]
         (def req (agent-request {}))
         (var n 0)
         (each id (get arguments :ids [])
           (def row (q/find-scoped desc req (string id)))
           (when row
             (ensure! desc (action :name) row)
             ((action :apply) row req)
             (act/announce! req desc (action :name) id
                            (act/snapshot-of row)
                            (act/snapshot-of (db/find (desc :entity)
                                                      (get row (get-in desc [:entity :pk])))))
             (++ n)))
         (ok {:applied n :asked (length (get arguments :ids []))}))})

(defn tools-for
  "Every tool one resource projects."
  [desc]
  (def out @[(list-tool desc) (get-tool desc)])
  (when (in (desc :action-set) :create) (array/push out (create-tool desc)))
  (when (in (desc :action-set) :update) (array/push out (update-tool desc)))
  (when (in (desc :action-set) :destroy) (array/push out (delete-tool desc)))
  (each aname (sorted (keys (desc :custom-actions)))
    (def a (get-in desc [:custom-actions aname]))
    (when (get a :apply) (array/push out (action-tool desc a))))
  out)

# -- resources -----------------------------------------------------------

(defn declaration
  ``The declaration itself, as data. An agent that can read this does
  not have to guess what it may filter on, sort by or write — and what
  it reads is the same value the pages render from, so the two cannot
  disagree.``
  [desc]
  {:name (desc :name)
   :title (desc :title)
   :entity (get-in desc [:entity :name])
   :mounted (desc :mount)
   :url (when (desc :mount) (ctx/base desc))
   :actions [;(desc :actions) ;(sorted (keys (desc :custom-actions)))]
   :list (map |($ :name) (desc :list))
   :detail (desc :detail)
   :form (desc :form)
   :readonly (desc :readonly)
   :search (desc :search)
   :sortable (desc :sortable)
   :filters (map |($ :name) (desc :filters))
   :inlines (sorted (keys (desc :inlines)))
   :policies (tabseq [a :in [;(desc :actions) ;(sorted (keys (desc :custom-actions)))]]
               a (res/policy-name (desc :name) a))})

(defn resources-for
  ``The one resource each declaration publishes: itself. Reading it
  passes the same two policies the index route carries — the gate and
  `:index` — because a declaration names fields, actions and policy
  names, and "the gate is the admin's gate" (the header's promise)
  covers what an agent may learn as much as what it may list.``
  [desc]
  [{:name (tool-key (desc :name) "declaration")
    :uri (string "void://admin/" (desc :name))
    :title (string (desc :title) " (admin declaration)")
    :doc (string "The admin declaration of " (desc :title)
                 ": its fields, actions, filters and policy names")
    :mime-type "application/json"
    :read (fn read-declaration []
            (ensure! desc :index)
            (json/encode (declaration desc)))}])

# -- the projection ------------------------------------------------------

(plugin/contribute! :void.mcp/tool
  {:name :void/admin-mcp
   :doc "Every declared admin resource, as tools"
   :expand (fn expand-tools [_boot]
             (mapcat |(tools-for (res/lookup $)) (res/resources)))})

(plugin/contribute! :void.mcp/resource
  {:name :void/admin-mcp
   :doc "Every declared admin resource's declaration, as a resource"
   :expand (fn expand-resources [_boot]
             (mapcat |(resources-for (res/lookup $)) (res/resources)))})

(plugin/defplugin void/admin-mcp
  :doc "The admin's declarations, projected into MCP tools and resources with the same ABAC policies: list/get/describe are read-only and exposed, create/update/delete and every declared action are not, so an operator names them in [:mcp :tools] before an agent may call one. The input schema of create is the resource's form schema — one value, two readers."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/admin ">=0.0.1" :void/mcp ">=0.0.1"})
