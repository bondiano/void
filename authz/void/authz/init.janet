### void/authz — ABAC: policies as pure functions, attributes on
### demand, decisions as values (SPEC.md §5.15, ADR-0024).
###
### RBAC breaks on the first real back-office requirement — "a manager
### sees orders of their own brand", "an author edits their own post" —
### because those are attributes of the subject and of the row, not
### roles. So the model here is ABAC, and the three things it is made
### of are:
###
###   a **policy**   — a pure function of one context, under a name
###   an **attribute** — pulled through a provider when a policy asks
###   a **decision** — a value with an explanation attached
###
### Two plugins:
###
###   void/authz       the registry, the context, the decision — core
###                    only, so a job or an RPC handler authorizes with
###                    the same policies
###   void/authz-http  the middleware and :void.authz/policy (./http)
###
### and **neither depends on `void/auth`**: the current identity is read
### from the `:void.auth/identity` dyn key, which is data. An
### application with its own authentication gets the same authorization
### by binding that key.
###
### What an application composes:
###
###     (void/run! {:plugins [:void/auth :void/auth-http
###                           :void/authz :void/authz-http ...]})
###     # config/prod.janet
###     {:authz {:default :deny
###              :roles {:admin [:*] :manager [:orders/read :orders/write]}}}
###
### With `:default :deny` a route that carries no policy is a **boot
### error**, not a 403 — the forgotten policy on a new route is the
### characteristic failure of this class of system, and the route table
### is the one place where catching it is free.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./policy :as policy)
(import ./context :as context)
(import ./decide :as decide)
(import ./rbac :as rbac)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.authz")

# -- extension points ----------------------------------------------------

(plugin/defextension-point :void.authz/provider
  :doc "Attribute providers (ADR-0024): {:name :orders/brand :for :subject|:resource|:env :keys [:subject/brand-id]? :fn (fn [ctx] attrs) :needs [component-keys]?}; called when a policy first asks for one of its keys, and memoized for the rest of that decision"
  :schema {:name :keyword
           :for [:enum :subject :resource :env]
           :keys [:optional [:vector :keyword]]
           :fn :function
           :needs [:optional [:vector :keyword]]
           :doc [:optional :string]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (when (in seen (c :name))
                  (errorf "duplicate attribute provider %q" (c :name)))
                (put seen (c :name) true)))
  :reduce |(sorted-by |($ :name) $))

(plugin/defextension-point :void.authz/policy
  :doc "Policies contributed by a plugin (ADR-0024): {:name :orders/read :fn (fn [ctx] bool|reason-string) :doc?}. An application usually writes `defpolicy` in its own module instead — this is for plugins that ship policies of their own"
  :schema {:name :keyword
           :fn :function
           :doc [:optional :string]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (when (in seen (c :name))
                  (errorf "duplicate policy %q" (c :name)))
                (put seen (c :name) true)))
  :reduce |(sorted-by |($ :name) $))

(plugin/contribute! :void.core/interface
  {:name :void/authz
   :doc "The authorization registry: the policies, the attribute providers and the role table this composition resolved."
   :methods {:policies "every registered policy name"
             :providers "attribute providers, in resolution order"
             :roles "the [:authz :roles] table"
             :default "what an unmarked route means: :allow or :deny"}})

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:authz] config slice."
  {:default [:optional [:enum :allow :deny]]
   :log [:optional [:enum :deny :all :none]]
   :roles [:optional :dictionary]})

(def defaults
  ``Defaults of the [:authz] slice.

  `:default :allow` — a route that says nothing about authorization is
  not checked, so adding this plugin to an existing application does
  not lock it out of itself. `:deny` is the posture an application
  takes deliberately, and then every route says what it needs (a route
  that is genuinely open says `{:void.authz/policy :public}`).

  `:log :deny` — allows are the overwhelming majority (a list of a
  hundred rows asks a hundred times) and logging them buries the
  denies. `:all` is for debugging a policy, `:none` for a hot path.``
  {:default :allow
   :log :deny
   :roles {}})

(defn- conf
  # `conf`, not `slice`: this module's `defpolicy` macro uses janet's
  # own `slice`, and a module-level binding of that name shadows it
  [cfg]
  (merge defaults (or cfg {})))

# -- built-in policies ---------------------------------------------------

(def builtin-policies
  ``The two policies every application ends up writing, so it does not
  have to: `:public` allows anybody (and is how a route stays open
  under `:default :deny` while *saying* that it is open), and
  `:authenticated` allows anybody the request could name.``
  [{:name :public
    :doc "Open to everybody — the explicit form of \"no policy\", so that a deny-by-default composition can tell an open route from a forgotten one"
    :fn (fn public-policy [_] true)}
   {:name :authenticated
    :doc "Anybody with an identity, whoever they are"
    :fn (fn authenticated-policy [ctx]
          (or (not (nil? (context/subject ctx)))
              "no identity on this request"))}])

# -- public surface (re-exports) -----------------------------------------

(def register-policy! "See policy/register!." policy/register!)
(def deregister-policy! "See policy/deregister!." policy/deregister!)
(def policy-of "See policy/lookup." policy/lookup)
(def policies "See policy/policies — every registered name." policy/policies)
(def describe-policies "See policy/describe." policy/describe)
(defmacro defpolicy
  ``See policy/defpolicy — define and register a policy:

      (defpolicy :orders/read "docstring" [ctx] body)``
  [name & body]
  ~(,policy/register! {:name ,name
                       :doc ,(when (string? (first body)) (first body))
                       :fn (fn ,(symbol "policy" (string name))
                             ,(if (string? (first body)) (in body 1) (first body))
                             ,;(tuple ;(slice body (if (string? (first body)) 2 1))))}))

(def make-context "See context/make." context/make)
(def attr "See context/attr — one attribute, resolved on first use." context/attr)
(def used-attributes "See context/used." context/used)
(def register-provider! "See context/register-provider!." context/register-provider!)
(def deregister-provider! "See context/deregister-provider!." context/deregister-provider!)
(def providers "See context/provider-names." context/provider-names)
(def identity-dyn "See context/identity-dyn — the key void/auth publishes, read without importing it." context/identity-dyn)

(def decide "See decide/decide — the decision value." decide/decide)
(def can? "See decide/can? — the boolean projection." decide/can?)
(def ensure! "See decide/ensure! — allow, or raise a 403." decide/ensure!)
(def explain "See decide/explain — every policy, for a human." decide/explain)
(def print-explanation "See decide/print-explanation." decide/print-explanation)
(def decision-hook "See decide/decision-hook — the core hook every decision passes through." decide/decision-hook)
(def listen! "See decide/listen! — hear decisions without a manifest." decide/listen!)
(def unlisten! "See decide/unlisten!." decide/unlisten!)

(def has-role? "See rbac/has-role?." rbac/has-role?)
(def roles-of "See rbac/roles-of." rbac/roles-of)
(def permitted? "See rbac/permitted?." rbac/permitted?)
(def role-policy "See rbac/role-policy — a ready policy for a route that only needs a role." rbac/role-policy)
(def permission-policy "See rbac/permission-policy." rbac/permission-policy)

# -- the component -------------------------------------------------------

(var contributions
  ``What the extension points resolved to, captured at :before-start —
  `plugin/current-boot` is not set on the inject path (ADR-0017), so a
  component that read it would register nothing under a test.``
  @{})

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 400
   :name :authz/collect-extensions
   :doc "Capture the resolved :void.authz/* contributions and the hook registry before components start"
   :fn (fn collect [boot]
         (each point [:void.authz/provider :void.authz/policy]
           (put contributions point
                (or (get-in boot [:extensions point :resolved]) [])))
         (set decide/hook-registry (get boot :hooks)))})

(defn- resolved [name]
  (get contributions name []))

(def registry-component
  (system/component :authz/registry
    :doc "What this composition authorizes with: the built-in policies,
    every :void.authz/policy contribution, every attribute provider and
    the role table. Registration happens at :start so that a policy a
    plugin ships and one an application wrote with `defpolicy` are the
    same kind of thing."
    :provides [:void/authz]
    :config {:key :authz :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (conf cfg0))
      (set rbac/roles (get cfg :roles {}))
      (set decide/log-mode (get cfg :log :deny))
      (each p builtin-policies (policy/register! p))
      (each p (resolved :void.authz/policy) (policy/register! p))
      (each p (resolved :void.authz/provider) (context/register-provider! p))
      (log/info "authz ready" :ns log-ns
                :policies (policy/policies)
                :providers (context/provider-names)
                :roles (sorted (keys (get cfg :roles {})))
                :default (cfg :default)
                :log (cfg :log))
      {:policies (policy/policies)
       :providers (context/provider-names)
       :roles (get cfg :roles {})
       :default (cfg :default)})
    :health
    (fn health [value]
      {:status :up
       :policies (length (value :policies))
       :providers (value :providers)
       :default (value :default)})))

(plugin/contribute! :void.core/health
  {:name :authz/registry
   :fn (fn authz-health []
         (if (empty? (policy/policies))
           {:status :down :reason "void/authz is not started"}
           {:status :up :policies (length (policy/policies))
            :providers (context/provider-names)}))})

# -- CLI -----------------------------------------------------------------

(defn print-policies
  "Print the policy registry — the body of `void authz policies`."
  []
  (def rows (policy/describe))
  (if (empty? rows)
    (print "no policies registered")
    (each r rows
      (printf "%-28s %s" (string (r :name)) (or (r :doc) "")))))

(plugin/contribute! :void.core/cli
  {:name :authz/policies
   :read-only? true
   :doc "List the policies in this composition: void authz policies"
   :needs [:authz/registry]
   :fn (fn cli-policies [_ & args]
         (unless (empty? args)
           (errorf "void authz policies takes no arguments (got %q)"
                   (string/join args " ")))
         (print-policies))})

(plugin/contribute! :void.core/cli
  {:name :authz/explain
   :read-only? true
   :doc "Why a policy allows or denies: void authz explain <policy> [subject] [role=... attr=...]"
   :needs [:authz/registry]
   :fn (fn cli-explain [_ & args]
         (when (empty? args)
           (error "usage: void authz explain <policy> [subject] [key=value ...]"))
         (def name (keyword (first args)))
         (def rest (drop 1 args))
         (def subject (when (and (first rest) (not (string/find "=" (first rest))))
                        (first rest)))
         (def pairs (filter |(string/find "=" $) rest))
         (def attrs @{})
         (def claims @{})
         (defn- parse-value [text]
           # a command line has only strings, and a policy comparing a
           # brand id against 3 would never match "3" — so numbers are
           # numbers and :keywords are keywords
           (cond
             (string/has-prefix? ":" text) (keyword (string/slice text 1))
             (= "true" text) true
             (= "false" text) false
             (if-let [n (scan-number text)] n text)))
         (each p pairs
           (def i (first (string/find-all "=" p)))
           (def key (string/slice p 0 i))
           (def value (parse-value (string/slice p (inc i))))
           (if (string/find "/" key)
             (put attrs (keyword key) value)
             (put claims (keyword key) value)))
         (decide/print-explanation
           (decide/explain name
                           {:subject (when subject
                                       {:subject subject :claims (freeze claims)})
                            :attrs attrs})))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/authz
  :doc "ABAC: policies as pure functions registered under names, attributes pulled through providers only when a policy asks for them, decisions as values that explain themselves, roles as sugar over the same machinery, and a decision hook void/bus turns into an audit trail."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :authz
  :config-schema Config
  :config-defaults defaults
  :components [registry-component])
