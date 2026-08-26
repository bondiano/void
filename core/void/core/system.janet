### void/core/system — component system (SPEC.md §3.1, ADR-0001).
###
### System = map of components; a component is plain data with
### :start/:stop/:health functions. Registry -> graph validation
### (duplicate keys, missing deps, interface conflicts, cycles) ->
### topological sort -> start in dependency order, stop in reverse.
### All runtime state lives inside the system value itself, fully
### inspectable from the REPL (`pp sys`) — no hidden singletons.

(def- allowed-component-keys
  {:key true :doc true :plugin true :scope true
   :deps true :provides true :config true
   :start true :stop true :health true :suspend true :resume true})

(def- allowed-scopes {:singleton true :factory true})

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(defn- plugin-of [comp]
  (if-let [p (get comp :plugin)]
    (string/format "plugin %q" p)
    "<unknown plugin>"))

# -- component definitions ----------------------------------------------

(defn component
  ``Build and validate a component definition (a plain struct).

  Options:
    :deps     tuple of dependency refs — component keys or interfaces
    :provides tuple of interface keywords this component implements
    :config   {:key <config-key> :schema <optional validator>} — the
              component's slice of the config map, passed to :start
    :start    (fn [deps cfg] instance) — required; `deps` is a struct
              keyed by the refs from :deps
    :stop     (fn [inst]) — optional
    :health   (fn [inst] {:status :up ...}) — optional
    :suspend  (fn [inst]) / :resume (fn [inst deps cfg] instance) —
              optional pair used by `restart` on dependents: instead of
              a full stop/start the component is suspended and later
              resumed with freshly resolved deps
    :scope    :singleton (default) or :factory — factory components are
              not started with the system; dependents receive a nullary
              constructor returning a fresh instance per call
    :plugin   source plugin keyword, used in error messages
    :doc      docstring``
  [key & kvs]
  (unless (keyword? key)
    (errorf "component key must be a keyword, got %q" key))
  (when (odd? (length kvs))
    (errorf "component %q: expected key-value option pairs, got an odd number of arguments" key))
  (def opts (table ;kvs))
  (eachk k opts
    (unless (in allowed-component-keys k)
      (errorf "component %q: unknown option %q (allowed: %s)"
              key k
              (string/join (map |(string/format "%q" $)
                                (sorted (keys allowed-component-keys)))
                           " "))))
  (def scope (get opts :scope :singleton))
  (unless (in allowed-scopes scope)
    (errorf "component %q: :scope must be :singleton or :factory, got %q" key scope))
  (unless (callable? (get opts :start))
    (errorf "component %q: a :start function is required" key))
  (each fk [:stop :health :suspend :resume]
    (when-let [f (get opts fk)]
      (unless (callable? f)
        (errorf "component %q: %q must be a function, got %q" key fk f))))
  (when (not= (nil? (get opts :suspend)) (nil? (get opts :resume)))
    (errorf "component %q: :suspend and :resume must be declared together" key))
  (def deps (get opts :deps []))
  (unless (and (indexed? deps) (all keyword? deps))
    (errorf "component %q: :deps must be a tuple of keywords, got %q" key deps))
  (def provides (get opts :provides []))
  (unless (and (indexed? provides) (all keyword? provides))
    (errorf "component %q: :provides must be a tuple of keywords, got %q" key provides))
  (when-let [cfg-spec (get opts :config)]
    (unless (and (dictionary? cfg-spec) (keyword? (get cfg-spec :key)))
      (errorf "component %q: :config must be {:key <keyword> :schema <optional>}, got %q"
              key cfg-spec)))
  (table/to-struct
    (merge opts {:key key
                 :scope scope
                 :deps (tuple ;deps)
                 :provides (tuple ;provides)})))

# -- registry ------------------------------------------------------------

(def registry-dyn
  "Dynamic binding key: the registry `defcomponent` registers into
  (falls back to `default-registry` when unset)."
  :void.system/registry)

(defn registry
  "Create an empty component registry."
  []
  @{})

(def default-registry
  "Registry used by `defcomponent` when no `registry-dyn` dyn is set."
  (registry))

(defn register!
  "Put a component definition into a registry (default: the current
  `registry-dyn` registry). Re-registering a key replaces the previous
  definition — REPL-friendly; cross-plugin duplicate detection happens
  in `init` when definitions from several sources are combined."
  [comp &opt reg]
  (default reg (or (dyn registry-dyn) default-registry))
  (put reg (comp :key) comp)
  comp)

(defmacro defcomponent
  ``Declare a component and register it in the current registry.

      (defcomponent :db/pool
        :deps    [:config :metrics]
        :config  {:schema DbConfig :key :database}
        :start   (fn [deps cfg] ...)
        :stop    (fn [inst] ...)
        :health  (fn [inst] {:status :up}))

  See `component` for the full option contract.``
  [key & kvs]
  ~(,register! (,component ,key ,;kvs)))

# -- graph validation ----------------------------------------------------

(defn- collect-components [components]
  (cond
    (indexed? components)
    (do
      (def out @{})
      (each c components
        (unless (and (dictionary? c) (keyword? (get c :key)))
          (errorf "expected a component definition, got %q" c))
        (def k (c :key))
        (when-let [prev (get out k)]
          (errorf "duplicate component %q (%s and %s)"
                  k (plugin-of prev) (plugin-of c)))
        (put out k c))
      out)

    (dictionary? components)
    (do
      (def out @{})
      (eachp [k c] components (put out k c))
      out)

    (errorf "components must be a registry table or a list of definitions, got %q"
            components)))

(defn- interface-providers [comps]
  (def out @{})
  (each k (sorted (keys comps))
    (each iface (get-in comps [k :provides] [])
      (put out iface (array/push (get out iface @[]) k))))
  out)

(defn- resolve-ref
  "Resolve a dependency ref (component key or interface) to a component
  key. `who` describes the depending side for error messages."
  [comps providers config who ref]
  (cond
    (in comps ref) ref

    (in providers ref)
    (do
      (def cands (providers ref))
      (if (= 1 (length cands))
        (first cands)
        (do
          (def choice (get-in config [ref :impl]))
          (cond
            (nil? choice)
            (errorf
              (string "interface %q is provided by multiple components: %s; "
                      "select one in config: {%q {:impl <key>}}")
              ref
              (string/join
                (map |(string/format "%q (%s)" $ (plugin-of (comps $))) cands)
                ", ")
              ref)

            (nil? (index-of choice cands))
            (errorf "config selects %q as the %q implementation, but candidates are: %s"
                    choice ref
                    (string/join (map |(string/format "%q" $) cands) ", "))

            choice))))

    (errorf "%s depends on %q which is neither a component nor a provided interface"
            who ref)))

(defn- topo-sort [comps resolution]
  (def order @[])
  (def state @{})
  (def path @[])
  (defn visit [k]
    (case (get state k)
      :done nil
      :visiting
      (do
        (def i (index-of k path))
        (def cycle (array/concat (array/slice path i) @[k]))
        (errorf "dependency cycle: %s"
                (string/join (map |(string/format "%q" $) cycle) " -> ")))
      (do
        (put state k :visiting)
        (array/push path k)
        (each rk (sorted (values (get resolution k {})))
          (visit rk))
        (array/pop path)
        (put state k :done)
        (array/push order k))))
  (each k (sorted (keys comps))
    (visit k))
  order)

(defn init
  ``Validate component definitions and build a system value.

  `components` is a registry table (key -> definition) or an indexed
  collection of definitions; `config` is the application config map.
  Fails fast on duplicate keys, missing dependencies, unresolved
  interface conflicts and dependency cycles — before anything starts.

  The returned system is plain data:
    :components  key -> definition
    :providers   interface -> keys of implementations
    :resolution  key -> {dep-ref resolved-key}
    :order       topological start order
    :config      the config map
    :instances   key -> running instance
    :states      key -> :running | :suspended | :stopped``
  [components &opt config]
  (default config {})
  (def comps (collect-components components))
  (def providers (interface-providers comps))
  (def resolution @{})
  (each k (sorted (keys comps))
    (def comp (comps k))
    (def res @{})
    (each ref (get comp :deps [])
      (put res ref
           (resolve-ref comps providers config
                        (string/format "component %q (%s)" k (plugin-of comp))
                        ref)))
    (put resolution k res))
  (def order (topo-sort comps resolution))
  @{:components comps
    :providers providers
    :resolution resolution
    :order order
    :config config
    :instances @{}
    :states @{}})

# -- lifecycle -----------------------------------------------------------

(defn- component-config [comp config]
  (when-let [spec (get comp :config)]
    (def cfg (get config (spec :key)))
    (when-let [schema (get spec :schema)]
      (when (callable? schema)
        (def ok
          (try (schema cfg)
            ([e] (errorf "component %q: config %q failed schema validation: %s"
                         (comp :key) (spec :key) (describe e)))))
        (when (= ok false)
          (errorf "component %q: config %q failed schema validation"
                  (comp :key) (spec :key)))))
    cfg))

(defn- resolved-deps
  "Build the deps struct passed to :start/:resume. Factory dependencies
  become nullary constructors producing a fresh instance per call."
  [sys k]
  (def out @{})
  (eachp [ref rk] (get-in sys [:resolution k] {})
    (def target (get-in sys [:components rk]))
    (put out ref
         (if (= :factory (get target :scope))
           (fn factory []
             ((target :start) (resolved-deps sys rk)
                              (component-config target (sys :config))))
           (get-in sys [:instances rk]))))
  (table/to-struct out))

(defn- start-instance [sys k]
  (def comp (get-in sys [:components k]))
  ((comp :start) (resolved-deps sys k)
                 (component-config comp (sys :config))))

(defn- stop-instance [sys k]
  (def comp (get-in sys [:components k]))
  (when-let [stop-fn (get comp :stop)]
    (stop-fn (get-in sys [:instances k])))
  (put (sys :instances) k nil)
  (put (sys :states) k :stopped))

(defn start
  "Start all singleton components in dependency order. If a component
  fails to start, the ones already started are stopped in reverse order
  (best effort) and the error is rethrown. Returns the system."
  [sys]
  (each k (sys :order)
    (def comp (get-in sys [:components k]))
    (when (and (= :singleton (get comp :scope))
               (not= :running (get-in sys [:states k])))
      (try
        (do
          (put (sys :instances) k (start-instance sys k))
          (put (sys :states) k :running))
        ([e f]
          (each j (reverse (sys :order))
            (when (= :running (get-in sys [:states j]))
              (try (stop-instance sys j)
                ([_]
                  (put (sys :instances) j nil)
                  (put (sys :states) j :stopped)))))
          (propagate e f)))))
  sys)

(defn stop
  "Stop running components in reverse dependency order. A stop error
  does not prevent the remaining components from stopping; failures are
  collected and rethrown as one error at the end. Returns the system."
  [sys]
  (def failures @[])
  (each k (reverse (sys :order))
    (when (= :running (get-in sys [:states k]))
      (try (stop-instance sys k)
        ([e]
          (put (sys :instances) k nil)
          (put (sys :states) k :stopped)
          (array/push failures (string/format "%q: %s" k (describe e)))))))
  (unless (empty? failures)
    (errorf "errors while stopping components: %s" (string/join failures "; ")))
  sys)

(defn- dependents-of
  "Transitive dependents of `k`, in start (topological) order."
  [sys k]
  (def rdeps @{})
  (eachp [c res] (sys :resolution)
    (each rk (values res)
      (put rdeps rk (array/push (get rdeps rk @[]) c))))
  (def affected @{})
  (defn visit [j]
    (each d (get rdeps j @[])
      (unless (in affected d)
        (put affected d true)
        (visit d))))
  (visit k)
  (filter |(in affected $) (sys :order)))

(defn restart
  "Stop component `k` and its transitive dependents, then start them
  again — the reloaded workflow. Dependents declaring :suspend/:resume
  are suspended instead of stopped and resumed with freshly resolved
  deps, keeping their instance alive across the restart."
  [sys k]
  (def comp (get-in sys [:components k]))
  (unless comp
    (errorf "unknown component %q" k))
  (when (= :factory (get comp :scope))
    (errorf "component %q has :factory scope — its instances are not managed by the system" k))
  (def affected
    (filter |(= :running (get-in sys [:states $])) (dependents-of sys k)))
  (each j (reverse affected)
    (def c (get-in sys [:components j]))
    (if (get c :suspend)
      (do
        ((c :suspend) (get-in sys [:instances j]))
        (put (sys :states) j :suspended))
      (stop-instance sys j)))
  (when (= :running (get-in sys [:states k]))
    (stop-instance sys k))
  (put (sys :instances) k (start-instance sys k))
  (put (sys :states) k :running)
  (each j affected
    (def c (get-in sys [:components j]))
    (if (= :suspended (get-in sys [:states j]))
      (put (sys :instances) j
           ((c :resume) (get-in sys [:instances j])
                        (resolved-deps sys j)
                        (component-config c (sys :config))))
      (put (sys :instances) j (start-instance sys j)))
    (put (sys :states) j :running))
  sys)

# -- inspection ----------------------------------------------------------

(defn health
  "Aggregate component health: {:status :up|:down :components {...}}.
  A running component without a :health function reports {:status :up};
  the aggregate is :down if any component reports :down."
  [sys]
  (def out @{})
  (each k (sys :order)
    (def comp (get-in sys [:components k]))
    (case (get-in sys [:states k])
      :running (put out k (if-let [h (get comp :health)]
                            (h (get-in sys [:instances k]))
                            {:status :up}))
      :suspended (put out k {:status :suspended})
      nil))
  {:status (if (some |(= :down (get $ :status)) (values out)) :down :up)
   :components (table/to-struct out)})

(defn instance
  "Return the running instance for a component key or interface ref.
  For :factory components a fresh instance is created on every call."
  [sys ref]
  (def comps (sys :components))
  (def k (if (in comps ref)
           ref
           (resolve-ref comps (sys :providers) (sys :config)
                        "instance lookup" ref)))
  (if (= :factory (get-in comps [k :scope]))
    (start-instance sys k)
    (get-in sys [:instances k])))
