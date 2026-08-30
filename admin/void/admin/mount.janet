### void/admin/mount — the registry, projected into real routes
### (ADR-0029 §1, §2, §3).
###
### This is the projection the whole ADR turns on. Nothing here is a
### dispatcher: every action of every resource becomes an entry in the
### one route table, with its own name, its own metadata and its own
### policies. That is what buys the admin, for free and without knowing
### it, everything a route already has — `void routes` lists it line by
### line, `void authz routes` shows who may reach each line,
### `explain-route` explains its metadata, the transaction is declared
### rather than opened by hand, and void/security signs its forms.
###
### **The whole registry is mounted, never a list.** A list of
### resources kept somewhere else is a list that drifts, and the half
### that drifts first is the half the agent reads. A resource that
### wants a declaration without a section says `:mount false`.
###
### **The gate is on every route and it is shut.** `:void.admin/access`
### refuses until `[:admin :access]` names the application's policy;
### the action's own policy rides next to it and allows, so that
### "only the owner may delete" has a name already written on the
### route the day somebody needs it.
###
### Route order matters here and is deliberate: a literal `-` segment
### has to be offered to the matcher before `:id` gets a chance to
### swallow it.

(import void/core/log :as log)
(import void/http/router :as router)
(import ./action :as act)
(import ./context :as ctx)
(import ./resource :as res)
(import ./widget :as widget)

(def access-policy
  "The gate every admin route carries (ADR-0029 §3)."
  :void.admin/access)

(defn- meta-for
  "The metadata of one action's route: its name, the gate plus its own
  policy, and — on the routes that are about one row — the loader that
  hands that row to the policies."
  [desc action &opt extra]
  (merge
    {:name (res/route-name (desc :name) action)
     :void.authz/policy [access-policy (res/policy-name (desc :name) action)]}
    (or extra {})))

(def- txn {:void.db/txn true})

(defn- row-meta [desc action &opt extra]
  (meta-for desc action (merge {:void.authz/resource (act/row-loader desc)} (or extra {}))))

# -- widget routes -------------------------------------------------------

(defn- widget-routes
  ``The routes a widget asked for, mounted under `<resource>/-/w/<field>`
  with the same gate as everything else. FK autocompletion is the first
  user of this seam rather than a special case of the core — which is
  the whole reason the seam is in the contract (ADR-0029 §4).``
  [desc entries]
  (def out @[])
  (each fname (sorted (keys entries))
    (def entry (get entries fname))
    (when-let [f (get-in entry [:widget :routes])]
      (def decls (or (f {:field (entry :field) :resource desc}) []))
      (var i 0)
      (each d decls
        (unless (and (dictionary? d) (get d :route))
          (errorf "admin widget %q: :routes must return router/route values, got %q"
                  (get-in entry [:widget :name]) d))
        (++ i)
        (array/push out
                    (merge (table ;(mapcat identity (pairs d)))
                           {:pattern (string (desc :path) "/-/w/" fname (d :pattern))
                            :meta (merge {:name (keyword "admin." (desc :name)
                                                         "/w-" fname "-" i)
                                          :void.authz/policy [access-policy
                                                              (res/policy-name (desc :name) :index)]}
                                         (get d :meta {}))}))))
    nil)
  out)

# -- one resource --------------------------------------------------------

(defn resource-routes
  "Every route of one resource, in matcher order."
  [desc entries]
  (def base (desc :path))
  (def on (desc :action-set))
  (def out @[])
  (defn add [r] (array/push out r))

  # static first — they are a table lookup, and `new` must not be an :id
  (when (in on :index)
    (add (router/GET base (act/index desc) (meta-for desc :index))))
  (when (in on :new)
    (add (router/GET (string base "/new") (act/new desc) (meta-for desc :new))))
  (when (in on :create)
    (add (router/POST base (act/create desc) (meta-for desc :create txn))))

  # the `-` namespace, before :id can claim the segment
  (when (or (in on :destroy) (not (empty? (desc :custom-actions))))
    (add (router/GET (string base "/-/bulk/:action") (act/bulk-confirm desc)
                     {:name (keyword "admin." (desc :name) "/bulk")
                      :void.authz/policy [access-policy]}))
    (add (router/POST (string base "/-/bulk/:action") (act/bulk-apply desc)
                      (merge {:name (keyword "admin." (desc :name) "/bulk-apply")
                              :void.authz/policy [access-policy]}
                             txn)))
    (add (router/GET (string base "/-/progress/:job") (act/progress desc)
                     {:name (keyword "admin." (desc :name) "/progress")
                      :void.authz/policy [access-policy]})))
  (each w (widget-routes desc entries)
    (add (router/route (w :method) (w :pattern) (w :handler) (w :meta))))

  # then the row
  (when (in on :show)
    (add (router/GET (string base "/:id") (act/show desc) (row-meta desc :show))))
  (when (in on :edit)
    (add (router/GET (string base "/:id/edit") (act/edit desc) (row-meta desc :edit))))
  (when (in on :update)
    (add (router/POST (string base "/:id") (act/update desc) (row-meta desc :update txn))))
  (when (in on :destroy)
    (add (router/DELETE (string base "/:id") (act/destroy desc) (row-meta desc :destroy txn))))
  (unless (empty? (desc :editable))
    (add (router/PATCH (string base "/:id/-/cell/:field") (act/cell desc)
                       (row-meta desc :update
                                 (merge txn {:name (keyword "admin." (desc :name) "/cell")})))))
  (unless (empty? (desc :inlines))
    (add (router/POST (string base "/:id/-/inline/:rel") (act/inline-create desc)
                      (row-meta desc :show
                                (merge txn {:name (keyword "admin." (desc :name) "/inline-create")}))))
    (add (router/POST (string base "/:id/-/inline/:rel/:child") (act/inline-update desc)
                      (row-meta desc :show
                                (merge txn {:name (keyword "admin." (desc :name) "/inline-update")}))))
    (add (router/DELETE (string base "/:id/-/inline/:rel/:child") (act/inline-destroy desc)
                        (row-meta desc :show
                                  (merge txn {:name (keyword "admin." (desc :name) "/inline-destroy")})))))
  out)

# An inline route is guarded by all three policies of ADR-0029 §5. Two
# of them are on the route above — the gate and the parent's `:show`.
# The third is the child's own action policy, and it is enforced in the
# handler (`action/ensure-child!`) rather than here, because it decides
# about a row that only the handler has loaded.

# -- the whole thing -----------------------------------------------------

(defn- page-routes []
  (seq [p :in (ctx/setting :pages [])]
    (router/route (get p :method :get)
                  (p :path)
                  (p :handler)
                  (merge {:name (keyword "admin.page/" (p :name))
                          :void.authz/policy [access-policy ;(get p :policies [])]}
                         (get p :meta {})))))

(defn resolve-widgets
  "Resolve every field of every declared resource once — the table
  `void admin widgets` prints and the handlers read."
  [contribs]
  (freeze (tabseq [rname :in (res/resources)]
            rname (widget/resolve-all (res/lookup rname) contribs))))

(defn routes
  ``The route source: the whole registry plus the admin's own pages,
  under `[:admin :prefix]`. Called once per route-table build, so a
  resource added in a REPL and a `http/rebuild!` are enough to see it.``
  []
  (def prefix (ctx/prefix))
  (def resolved (ctx/setting :resolved {}))
  (def children @[])
  (array/push children
              (router/GET "/" act/dashboard
                          {:name :admin/dashboard
                           :void.authz/policy [access-policy]}))
  (each r (page-routes) (array/push children r))
  (each rname (res/mounted)
    (def desc (res/lookup rname))
    (each r (resource-routes desc (get resolved rname {}))
      (array/push children r)))
  (log/debug "admin routes projected" :ns "void.admin"
             :resources (length (res/mounted)) :routes (length children))
  (router/routes {}
    (router/group prefix {} ;children)))
