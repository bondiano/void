### void/admin — the back office as a projection of what the
### application already declared (SPEC.md §5.21, ADR-0029).
###
### The promise of §5.21 in one line: the admin is *another projection
### of the schema layer*, the way OpenAPI is. Everything it needs was
### written by wave 4 and already describes the domain — `defentity`
### knows the table, the primary key, the columns and the relations
### (ADR-0009); `void/core/schema` knows the types and the bounds
### (ADR-0008); `void/html/form` projects a map schema into controls;
### `void/authz` decides who may do what (ADR-0024); `void/htmx`
### answers with a fragment on the same route that answers with a page.
###
### So there is no code generation and no second model. A field added
### to `defentity` shows up in the form on the next request, because
### the page reads the descriptor when it renders. What the
### declaration adds is only what a schema cannot say.
###
### Four decisions are worth knowing before reading further:
###
### **The declaration is a value, not a function that builds routes.**
### `defresource-admin` registers a frozen descriptor; `./mount`
### projects the registry into routes and `void/admin-mcp` projects the
### same registry into tools and resources. Neither knows about the
### other, and there is one place a resource is described.
###
### **Every action is a real route** named `:admin.<resource>/<action>`
### — so `void routes`, `explain-route`, `:void.db/txn`, CSRF and the
### 403 renderers all work here without anybody teaching them about the
### admin (ADR-0028's shape, for ADR-0028's reason).
###
### **The gate is shut.** `[:authz :default]` is `:allow` for a good
### reason, and for a back office that reason does not apply. Every
### admin route carries `:void.admin/access`, which refuses until
### `[:admin :access]` names the application's policy. The failure is
### loud and immediate — the operator cannot get in — rather than
### quiet, which is what an admin open to the internet is.
###
### **The admin owns no table.** A change announces itself through the
### core hook `:void.admin/changed`; whoever wants a trail subscribes
### (`examples/blog` does it in one function over the audit trail it
### already had). No migration ships with this package.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/authz :as authz)
(import void/authz/policy :as policy)
(import ./context :as ctx)
(import ./mount :as mount)
(import ./resource :prefix "" :export true)
(import ./view :as view)
(import ./widget :as widget)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.admin")

# -- extension points ----------------------------------------------------

(plugin/defextension-point :void.admin/widget
  :doc "Widgets: {:name :money :types [:money]? :match (fn [field] bool)? :priority 100? :render (fn [ctx] hiccup) :display? :filter? :parse? :assets {:style :script}? :routes (fn [ctx] [route ...])? :encoding :multipart?}. :render is the only required half; each of the others answers a question that would otherwise be a special case inside the admin — :encoding says the control cannot ride a urlencoded form, so form-page flips the <form> to multipart and `submitted` hands :parse the request even when (req :form) never saw the field (the upload widget, ADR-0039 §6). :assets are concatenated into the admin's two served files (a fingerprinted .css and .js under the admin prefix) rather than written into a page, so a widget's style costs the application no `'unsafe-inline'`. Resolution runs once per field at mount, never per row — `void admin widgets` prints the result and why"
  :schema {:name :keyword
           :render :function
           :doc [:optional :string]
           :types [:optional [:vector :keyword]]
           :match [:optional :function]
           :priority [:optional :int]
           :display [:optional :function]
           :filter [:optional :function]
           :parse [:optional :function]
           :assets [:optional :dictionary]
           :routes [:optional :function]
           :encoding [:optional [:enum :multipart]]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (widget/normalize c)
                (when (in seen (c :name))
                  (errorf "duplicate admin widget %q" (c :name)))
                (put seen (c :name) true)))
  :reduce |(sorted-by |(- (get $ :priority 100)) $))

# The one route-metadata key this package declares. A widget may ask
# for routes of its own (`:void.admin/widget :routes`) — FK
# autocompletion is the first user of that seam — and they are marked
# so that `void routes` shows what a line under the admin prefix
# actually is: a widget's helper, not an action of a resource. It is
# declared here because a key nobody declared is a boot error, which is
# the rule that keeps route metadata a contract rather than a bag
# (CONTRACTS v1).
(plugin/contribute! :void.http/route-meta-key
  {:key :void.admin/widget-route
   :schema :boolean
   :doc "This route belongs to a widget (:void.admin/widget :routes), not to an action of a resource"
   :merge :replace})

(plugin/defextension-point :void.admin/page
  :doc "Arbitrary admin pages: {:name :reports :label \"Reports\" :path \"/reports\" :method :get? :handler (fn [req] response) :policies [...]? :meta {}?}. The page is mounted as an ordinary route under the admin prefix with the same gate — Django's admin_view, with a route table entry"
  :schema {:name :keyword
           :path :string
           :handler :function
           :label [:optional :string]
           :method [:optional :keyword]
           :policies [:optional [:vector :keyword]]
           :meta [:optional :dictionary]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (when (in seen (c :name))
                  (errorf "duplicate admin page %q" (c :name)))
                (unless (string/has-prefix? "/" (c :path))
                  (errorf "admin page %q: :path must start with /" (c :name)))
                (put seen (c :name) true)))
  :reduce |(sorted-by |($ :name) $))

(plugin/defextension-point :void.admin/dashboard-widget
  :doc "Tiles on the admin index: {:name :orders/today :label \"Orders today\" :render (fn [request] hiccup)}"
  :schema {:name :keyword
           :render :function
           :label [:optional :string]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (when (in seen (c :name)) (errorf "duplicate dashboard widget %q" (c :name)))
                (put seen (c :name) true)))
  :reduce |(sorted-by |($ :name) $))

(plugin/defextension-point :void.admin/menu
  :doc "Extra items in the admin navigation: {:name :docs :label \"Docs\" :href \"/admin/reports\"}. A link to a page inside the admin says :path instead — {:name :jobs :label \"Jobs\" :path \"/jobs\"} — and it is resolved against [:admin :prefix] when the navigation renders: a contribution is a value frozen at load, so a plugin that mounts a :void.admin/page cannot write down where its own page will be. Exactly one of the two"
  :schema {:name :keyword :label :string
           :href [:optional :string]
           :path [:optional :string]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (when (in seen (c :name)) (errorf "duplicate admin menu item %q" (c :name)))
                (when (= (nil? (get c :href)) (nil? (get c :path)))
                  (errorf (string "admin menu item %q: name the link once — :href for a URL "
                                  "of its own, :path for one under [:admin :prefix]")
                          (c :name)))
                (when-let [p (get c :path)]
                  (unless (string/has-prefix? "/" p)
                    (errorf "admin menu item %q: :path must start with /" (c :name))))
                (put seen (c :name) true)))
  :reduce |(sorted-by |($ :name) $))

(plugin/defextension-point :void.admin/history
  :doc "Where the history tab of a row comes from: {:name :fn (fn [{:resource :id :request}] [{:at :actor :detail} ...])}. Nobody contributes one by default, so there is no history tab by default — the admin announces changes (:void.admin/changed) and does not keep them (ADR-0029 §8)"
  :cardinality :single
  :schema {:name :keyword :fn :function :doc [:optional :string]}
  :reduce first)

(plugin/defextension-point :void.admin/bulk-runner
  :doc "How a bulk too big to run inline is run: {:name :enqueue (fn [{:resource :action :selection :request}] job-id) :progress (fn [job-id action] {:state :percent? :label?})}. void/admin-jobs contributes one; without it, an action that declares :job — or a selection over [:admin :bulk :inline-limit] — is a start-time error naming the plugin rather than a surprise at the moment somebody presses the button"
  :cardinality :single
  :schema {:name :keyword :enqueue :function :progress :function}
  :reduce first)

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:admin] config slice."
  {:prefix [:optional :string]
   :title [:optional :string]
   :access [:optional :keyword]
   :per-page [:optional [:int {:min 1 :max 1000}]]
   :select-limit [:optional [:int {:min 0}]]
   :route-meta [:optional :dictionary]
   :stylesheet [:optional :string]
   :layout [:optional :function]
   :htmx-src [:optional :string]
   :bulk [:optional {:inline-limit [:optional [:int {:min 1}]]}]})

(def defaults
  ``Defaults of the [:admin] slice.

  `:access` is deliberately absent: its absence is what keeps the gate
  shut, and a default value here would be the vulnerability this
  design exists to avoid.``
  {:prefix "/admin"
   :title "Admin"
   :per-page 25
   :select-limit 100
   :bulk {:inline-limit 500}})

# -- the gate ------------------------------------------------------------

(def access-policy
  "The policy every admin route carries."
  mount/access-policy)

(def gate
  ``Closed by default (ADR-0029 §3). Until `[:admin :access]` names a
  policy, this one refuses everybody and the refusal says which config
  key opens it. It is a policy name and not a boolean on purpose: the
  line an application writes to open the admin is the line that says
  who may come in.``
  {:name access-policy
   :doc "The admin gate: refuses until [:admin :access] names the application's policy"
   :fn (fn admin-access [c]
         (if-let [name (get (or ctx/current {}) :access)]
           (let [p (policy/policy! name)] ((p :fn) c))
           (string "the admin is shut: [:admin :access] has not named a policy. "
                   "Set it to the policy that decides who is an operator — "
                   "{:admin {:access :staff}} — and define that policy with defpolicy")))})

(plugin/contribute! :void.authz/policy gate)

(defn- register-action-policies!
  ``One allowing policy per action of every resource, registered only
  where the application has not defined one. It exists so the *name*
  is already on the route: narrowing an action later is a `defpolicy`
  and nothing else — no change to the declaration, no change to the
  routes (ADR-0029 §3).``
  []
  (def added @[])
  (each rname (resources)
    (def desc (lookup rname))
    (each action [;(desc :actions) ;(sorted (keys (desc :custom-actions)))]
      (def pname (policy-name rname action))
      (unless (policy/lookup pname)
        (policy/register!
          {:name pname
           :doc (string "Admin " rname " " action
                        " — allows; define a policy of this name to narrow it")
           :fn (fn admin-action-policy [_] true)})
        (array/push added pname))))
  added)

# -- the context ---------------------------------------------------------

(defn build-context
  "Assemble the admin context from a boot value: the [:admin] slice,
  the four contribution points, the hook registry, and the widget
  resolution of every declared resource. Normally called by the
  :before-start hook."
  [boot]
  (defn resolved [name] (or (get-in boot [:extensions name :resolved]) []))
  (def cfg (merge defaults (or (get-in boot [:config :values :admin]) {})))
  (def widgets (resolved :void.admin/widget))
  # the widget resolution first, because the asset bundle is a
  # projection of it: what ./mount serves and what ./view links are two
  # reads of this one value
  (def resolved-widgets (mount/resolve-widgets widgets))
  (set ctx/current
       @{:config cfg
         :prefix (cfg :prefix)
         :title (cfg :title)
         :access (cfg :access)
         :per-page (cfg :per-page)
         :select-limit (cfg :select-limit)
         :route-meta (get cfg :route-meta {})
         :inline-limit (get-in cfg [:bulk :inline-limit] 500)
         :stylesheet (cfg :stylesheet)
         :layout (cfg :layout)
         :htmx-src (get cfg :htmx-src "https://unpkg.com/htmx.org@4.0.0")
         :widgets widgets
         :pages (resolved :void.admin/page)
         :dashboard (resolved :void.admin/dashboard-widget)
         :menu (resolved :void.admin/menu)
         :history (get-in boot [:extensions :void.admin/history :resolved])
         :bulk-runner (get-in boot [:extensions :void.admin/bulk-runner :resolved])
         :hooks (get boot :hooks)
         :resolved resolved-widgets
         :assets (view/asset-bundle (cfg :stylesheet) resolved-widgets)})
  (def added (register-action-policies!))
  (log/info "admin ready" :ns log-ns
            :prefix (cfg :prefix)
            :resources (resources)
            :mounted (mounted)
            :access (or (cfg :access) :closed)
            :policies (length added))
  ctx/current)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 420
   :name :admin/build-context
   :doc "Resolve the admin config, widgets and policies before the route table is built"
   :fn (fn build! [boot] (build-context boot))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 120
   :name :admin/warn-when-shut
   :doc "Say once, at start, that the admin is mounted and refusing everybody"
   :fn (fn warn [_boot]
         (when (and ctx/current (nil? (ctx/current :access)) (not (empty? (mounted))))
           (log/warn (string "the admin is mounted and refuses every request: "
                             "[:admin :access] names no policy")
                     :ns log-ns :prefix (ctx/current :prefix))))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 130
   :name :admin/require-bulk-runner
   :doc "A resource with a :job action needs somebody to run it — say so at start, not at the button"
   :fn (fn check [_boot]
         (def offenders @[])
         (each rname (resources)
           (def desc (lookup rname))
           (eachp [aname a] (desc :custom-actions)
             (when (get a :job)
               (array/push offenders (string/format "%q %q" rname aname)))))
         (when (and (not (empty? offenders)) (nil? (ctx/setting :bulk-runner)))
           (errorf (string "action%s %s declare%s :job, and nothing contributed "
                           ":void.admin/bulk-runner — compose :void/admin-jobs "
                           "(it also checks that the queue backend is shared, which a "
                           "progress page read on a second replica needs)")
                   (if (= 1 (length offenders)) "" "s")
                   (string/join (sorted offenders) ", ")
                   (if (= 1 (length offenders)) "s" ""))))})

# -- the verb an HTML form cannot send -----------------------------------

(def- overridable {"patch" :patch "delete" :delete "put" :put})

(plugin/contribute! :void.http/edge
  {:name :void.admin/method-override
   :phase 100
   :doc "Under the admin prefix, a POST carrying ?_method=patch|delete|put is dispatched as that verb — the only way a <form> reaches a route whose verb HTML cannot send. Never out of a GET: a link that changes state is a link the browser prefetches"
   :wrap (fn wrap-override [handler]
           (fn method-override [req]
             (when (and (= :post (req :method))
                        ctx/current
                        (string/has-prefix? (ctx/prefix) (or (req :path) "")))
               (when-let [verb (get overridable
                                    (string/ascii-lower
                                      (string (get-in req [:query "_method"] ""))))]
                 (put req :method verb)))
             (handler req)))})

# -- CLI -----------------------------------------------------------------

(defn print-resources
  "The body of `void admin resources`."
  []
  (if (empty? (resources))
    (print "no admin resources declared")
    (each rname (resources)
      (def d (lookup rname))
      (printf "%-18s %-14s %-22s %s"
              (string rname)
              (string (get-in d [:entity :name]))
              (if (d :mount) (string (ctx/prefix) (d :path)) "(not mounted)")
              (string/join (map string [;(d :actions)
                                        ;(sorted (keys (d :custom-actions)))]) " ")))))

(defn print-widgets
  ``The body of `void admin widgets`: which widget draws which field,
  and why it was the one. "Why is this field drawn like that" has to
  be answerable by a command, not by reading sources.``
  []
  (def resolved (ctx/setting :resolved {}))
  (if (empty? resolved)
    (print "no admin resources declared")
    (each rname (sorted (keys resolved))
      (print (string rname))
      (def entries (get resolved rname))
      (each fname (sorted (keys entries))
        (def e (get entries fname))
        (printf "  %-18s %-24s %s"
                (string fname)
                (string (get-in e [:widget :name]))
                (case (e :why)
                  :declared "named on the field"
                  :contributed "matched :void.admin/widget"
                  :relation "the column is a foreign key"
                  "projected from the schema"))))))

(plugin/contribute! :void.core/cli
  {:name :admin/resources
   :read-only? true
   :doc "Print the declared admin resources: void admin resources"
   :fn (fn cli-resources [& _] (print-resources))})

(plugin/contribute! :void.core/cli
  {:name :admin/widgets
   :read-only? true
   :doc "Print which widget draws which field, and why: void admin widgets"
   :fn (fn cli-widgets [& _] (print-widgets))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/admin
  :doc "The back office as a projection of the entity and schema layers (ADR-0029): defresource-admin registers a frozen declaration, every action becomes a real route named :admin.<resource>/<action> with the shut-by-default :void.admin/access gate plus its own policy, lists filter/search/sort/page through the URL, bulk actions go through a confirmation page that counts the rows on the server, inlines are guarded by the child's own policies, and changes are announced through :void.admin/changed rather than written to a table this package would have had to migrate."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1" :void/html ">=0.0.1"
             :void/htmx ">=0.0.1" :void/db ">=0.0.1" :void/db-http ">=0.0.1"
             :void/authz ">=0.0.1" :void/authz-http ">=0.0.1"}
  :config-key :admin
  :config-schema Config
  :config-defaults defaults
  :contributes
  {:void.http/route-source
   [{:name :void/admin
     # a function, not a value: the registry this projects is filled by
     # the application's own modules, long after this manifest froze
     # (see :void.http/route-source in void/http)
     :routes (fn admin-routes [_boot] (mount/routes))}]})
