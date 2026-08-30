### void/authz-http — enforcement from route metadata (ADR-0024 §5, §6).
###
### The half of void/authz that needs the HTTP kernel: two metadata
### keys and one middleware in the reserved phase **5000** — after auth
### (4000), so the identity the policies read is already bound, and
### before validation (6000), so a request nobody is allowed to make is
### refused before its body is checked.
###
###     (defroutes admin {:void.authz/policy :admin}
###       [:get "/orders" list-orders {:void.authz/policy :orders/read}]
###       [:get "/health" health {:void.authz/policy :public}])
###
### `:void.authz/policy` merges with `:concat`, and **every** policy in
### the merged list has to allow: the group's `:admin` *and* the
### route's `:orders/read`. There is no "or" — a disjunction belongs
### inside one policy, where a reader can see it.
###
### **The 403 goes out through the error renderers**, not by raising
### past them: `authz/ensure!` raises a value carrying `:http/status
### 403`, and this wrapper catches it to answer with the renderers the
### composition has (problem+json under void/rest, the dev page in dev).
### The reason never reaches the body (ADR-0024 §3).
###
### **`:void.authz/resource` is a function, not a symbol.** ADR-0024
### wrote "symbol" for late binding (ADR-0002), and that turned out to
### be unimplementable at this seam: a route entry does not carry the
### environment of the module that declared it, so a bare symbol has
### nothing to resolve against at request time. The value is a
### `(fn [req] resource)`, and the dev watcher rebuilds the route table
### on reload anyway, so a redefinition still takes effect. Row-level
### checks that need the row itself stay where they always belonged —
### in the handler, next to the query that loaded it:
###
###     (defn edit [req]
###       (def post (db/find! Post (get-in req [:params :id])))
###       (authz/ensure! :posts/edit {:resource post})
###       ...)
###
### **Deny by default is a boot check, not a runtime one.** With
### `[:authz :default :deny]`, a route that carries no policy fails the
### *table build* with the list of offenders. A forgotten policy is the
### characteristic mistake of this class of system, and the only place
### where catching it costs nothing is where the table is assembled.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http :as http)
(import ./decide :as decide)
(import ./context :as context)
(import ./policy :as policy)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.authz.http")

(def Config
  "Schema of the [:authz-http] config slice."
  {:status [:optional [:int {:min 400 :max 499}]]
   :message [:optional :string]})

(def defaults
  ``Defaults of the [:authz-http] slice. 403 rather than 404: hiding
  the existence of a resource behind a "not found" is a real tactic,
  but it belongs to an application that decided on it per resource,
  not to a framework that would then lie about every route.``
  {:status 403
   :message "forbidden"})

(var settings
  "The [:authz-http] slice, read at :before-start."
  defaults)

(var default-access
  "The [:authz :default] posture, read at :before-start: :allow or
  :deny."
  :allow)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :authz-http/capture-config
   :doc "Read the [:authz-http] and [:authz :default] slices once, before the route table is built"
   :fn (fn capture [boot]
         (set settings (merge defaults (or (get-in boot [:config :values :authz-http]) {})))
         (set default-access (get-in boot [:config :values :authz :default] :allow)))})

# -- route metadata ------------------------------------------------------

(plugin/contribute! :void.http/route-meta-key
  {:key :void.authz/policy
   :schema [:or :keyword [:vector :keyword]]
   :doc "Policy (or policies) enforced before the handler (SPEC part II §2.5). :concat — a group's policy and a route's are both enforced, and every one of them must allow"
   :merge :concat})

(plugin/contribute! :void.http/route-meta-key
  {:key :void.authz/resource
   :schema :function
   :doc "(fn [request] resource) — what the policies of this route decide about. Without one the resource is nil and the policies see only the subject and the environment; a row-level check belongs in the handler, next to the query that loaded the row"
   :merge :replace})

# -- deny by default, checked at build time ------------------------------

(def unguarded
  "Routes with no policy, collected during the table build so the
  error can name all of them at once."
  @[])

(plugin/contribute! :void.core/hooks
  {:hook :void.http/route-added
   :name :authz-http/require-policy
   :doc "Under [:authz :default :deny], collect routes that carry no :void.authz/policy"
   :fn (fn require-policy [_boot entry]
         (when (= :deny default-access)
           (when (empty? (get-in entry [:meta :void.authz/policy] []))
             (array/push unguarded (entry :name)))))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 100
   :name :authz-http/deny-by-default
   :doc "Under [:authz :default :deny], refuse to start with routes that carry no policy"
   :fn (fn deny-by-default [_boot]
         (unless (empty? unguarded)
           (def names (sorted (map string unguarded)))
           (array/clear unguarded)
           (errorf (string "[:authz :default :deny] and %d route(s) carry no "
                           ":void.authz/policy: %s. A route that is genuinely "
                           "open says so with {:void.authz/policy :public}")
                   (length names) (string/join names " "))))})

# -- enforcement ---------------------------------------------------------

(defn- policies-of [rmeta]
  (def declared (get rmeta :void.authz/policy))
  (cond
    (nil? declared) []
    (keyword? declared) [declared]
    declared))

(defn forbidden
  ``The response for a decision that said no: the configured status
  through the error renderers. The decision rides along on the error
  value for a custom renderer to read, and never reaches the body.``
  [req decision]
  (http/render-error {:http/status (settings :status)
                      :message (settings :message)
                      :void.authz/decision decision}
                     req (settings :status)))

(plugin/contribute! :void.http/middleware
  {:name :void.authz/enforce
   # the reserved phase 5000: after auth (4000) binds the identity,
   # before validation (6000) spends anything on a request that is not
   # going to be served
   :phase 5000
   :doc "Enforce :void.authz/policy — every policy on the merged metadata must allow, or the request is answered 403 through the error renderers"
   # evaluated once, at table-build time: a route with no policy has no
   # wrapper at all and cannot cost anything on the hot path
   :when (fn [rmeta] (not (empty? (get rmeta :void.authz/policy []))))
   :wrap
   (fn [handler]
     (fn authz-enforce [req]
       (def rmeta (get-in req [:void/route :meta] {}))
       (def names (policies-of rmeta))
       (def resource-fn (get rmeta :void.authz/resource))
       (def decision
         (decide/decide names
                        {:action (get rmeta :name)
                         :resource (when resource-fn (resource-fn req))
                         :env {:ip (get req :remote-address)
                               :method (get req :method)
                               :path (get req :path)}}))
       (if (decision :allow)
         (handler req)
         (do
           (log/debug "route denied" :ns log-ns
                      :route (get rmeta :name)
                      :policy (decision :policy)
                      :subject (decision :subject))
           (forbidden req decision)))))})

# -- CLI -----------------------------------------------------------------

(defn print-routes
  "Print route -> policies — the body of `void authz routes`."
  []
  # routes-table hands back the table, whose :routes are the entries
  (def rows (sorted-by |[($ :pattern) (string ($ :method))]
                       ((http/routes-table) :routes)))
  (printf "%-28s %-8s %-28s %s" "route" "method" "path" "policies")
  (each r rows
    (def names (policies-of (get r :meta {})))
    (printf "%-28s %-8s %-28s %s"
            (string (r :name))
            (string/ascii-upper (string (r :method)))
            (r :pattern)
            (if (empty? names)
              (if (= :deny default-access) "— (DENY by default)" "—")
              (string/join (map string names) " ")))))

(plugin/contribute! :void.core/cli
  {:name :authz/routes
   :read-only? true
   :doc "Show which policy guards which route: void authz routes"
   :needs [:http/kernel]
   :fn (fn cli-routes [_ & args]
         (unless (empty? args)
           (errorf "void authz routes takes no arguments (got %q)"
                   (string/join args " ")))
         (print-routes))})

(plugin/defplugin void/authz-http
  :doc "Authorization for void/http: :void.authz/policy on a route (group and route policies both enforced), the resource resolved by :void.authz/resource, a 403 through the error renderers, and a deny-by-default mode in which a route without a policy fails the boot rather than the request."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/authz ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :authz-http
  :config-schema Config
  :config-defaults defaults)
