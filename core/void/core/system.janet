### void/core/system — component system.
###
### System = map of components; a component is plain data with
### :start/:stop/:health functions. Registry -> graph validation
### (duplicate keys, missing deps, interface conflicts, cycles) ->
### topological sort -> start in dependency order, stop in reverse.
### All runtime state lives inside the system value itself, fully
### inspectable from the REPL (`pp sys`) — no hidden singletons.
###
### Two things here exist because "no hidden singletons" is a promise
### about *ownership*, not about reach. A component that needs the
### boot it was started in declares `:deps [:void/boot]` and is handed
### that boot — not the process's most recent one, which is a
### different value the moment a test bootstraps a second composition.
### And a package whose module-level functions must reach the running
### instance without being handed the system (`db/query`, `cache/fetch`)
### declares an `ambient`: one dyn, one cell the system fills at :start
### and empties at :stop, and one reader that says what is not started
### when neither is set. The reachability is the same as the eight
### hand-written `(var current-X)` it replaces; what changed is that
### the lifetime is the component's and no package writes the cell.

(import ./config :as config)
(import ./util :as util)

(def- allowed-component-keys
  {:key true :doc true :plugin true :ambient true
   :deps true :provides true :config true
   :start true :stop true :health true})

(def boot-ref
  ``The pseudo-dependency that hands a component its boot.

  `:deps [:void/boot]` puts the boot value in the deps struct under
  this key — the boot *this system* was attached to, which is the
  point: `plugin/last-boot` is the process's most recent bootstrap,
  and a component that reads it sees whichever composition happened
  to bootstrap last (a test bootstrap is untracked on purpose, so
  under a suite it sees the previous one, or none).

  It is not a component: nothing starts it, nothing may provide it,
  and it never enters the graph or the start order.``
  :void/boot)

(defn- plugin-of
  "The plugin a component definition came from, for a message; a
  component built outside a manifest has none."
  [comp]
  (if-let [p (get comp :plugin)]
    (string/format "plugin %q" p)
    "<unknown plugin>"))

# -- ambients ------------------------------------------------------------

(def- ambient-marker :void.system/ambient)

(defn ambient
  ``Declare an ambient value: what a running component holds, a dyn
  that overrides it for a scope, and a reader that explains the
  absence.

      (def pool (system/ambient :void.db/pool
                                :of "the database pool"
                                :from :void/db :component :db/pool))

      (system/current pool)   # the value in force, or nil
      (system/active pool)    # the value in force, or an error

  The component that owns it says so — `:ambient pool` in its
  definition — and the system fills the cell when it starts and empties
  it when it stops. Nothing else writes it: an ambient set by hand
  outlives the component that set it, and that is the whole class of
  bug this replaces.

  `of` names the value for the error message, `from` the plugin to add
  to :plugins and `component` the component that would have held it —
  the two halves of "why is this empty", since a plugin can be in the
  composition with its component left out of a subset start.

  The cell is a closure and the declaration itself is an immutable
  struct, because a component definition travels inside a manifest and
  `defplugin` freezes a manifest whole — a table here would arrive at
  :start as a struct nobody could write to.``
  [dyn-key &named of from component]
  (unless (keyword? dyn-key)
    (errorf "ambient: the dyn key must be a keyword, got %q" dyn-key))
  (var held nil)
  {ambient-marker true
   :dyn dyn-key
   :of (or of (string/format "%q" dyn-key))
   :from from
   :component component
   :held (fn held-value [] held)
   :hold (fn hold-value [v] (set held v) v)})

(defn ambient?
  "Is this an ambient declaration?"
  [a]
  (and (dictionary? a) (truthy? (get a ambient-marker))))

(defn current
  "The ambient value in force: the dyn override, else what the running
  component holds; nil when neither is set."
  [a]
  (def v (dyn (a :dyn)))
  (if (nil? v) ((a :held)) v))

(defn active
  "The ambient value in force, or an error naming what is not running
  — `current` for the callers who cannot go on without it."
  [a]
  (or (current a)
      (errorf "%s is not available%s%s (or bind %q for a scope)"
              (a :of)
              (if-let [p (a :from)]
                (string/format " — %q is not started" p)
                "")
              (if-let [c (a :component)]
                (string/format ", no %q component" c)
                "")
              (a :dyn))))

(defn hold!
  "Put a value in the ambient. The system does this for a component's
  `:ambient`; a REPL or a test standing a value up without a system is
  the only other caller."
  [a value]
  ((a :hold) value))

(defn release!
  "Empty the ambient — the counterpart of `hold!`."
  [a]
  ((a :hold) nil))

(defmacro with-ambient
  ``Run the body with the ambient bound to `value` for this scope — the
  dyn override, so it is per-fiber and it nests:

      (system/with-ambient pool other-pool
        (db/query ...))``
  [a value & body]
  (with-syms [$a]
    ~(let [,$a ,a]
       (with-dyns [(,$a :dyn) ,value] ,;body))))

# -- component definitions -----------------------------------------------

(defn component
  ``Build and validate a component definition (a plain struct).

  Options:
    :deps     tuple of dependency refs — component keys, interfaces, or
              `:void/boot` (see `boot-ref`), which is not a component
              and is handed over as the boot this system is attached to
    :provides tuple of interface keywords this component implements
    :config   {:key <config-key>} — the component's slice of the
              config map, passed to :start. A :schema here is
              deprecated (ADR-0046): it is still validated by `init`,
              through config/validate like a manifest's, but a
              plugin's slice belongs in the manifest's :config-schema,
              where bootstrap checks it in phase 2 with every other
    :start    (fn [deps cfg] instance) — required; `deps` is a struct
              keyed by the refs from :deps
    :stop     (fn [inst]) — optional
    :health   (fn [inst] {:status :up ...}) — optional
    :ambient  an `ambient` this component owns: the system holds the
              instance in it while the component runs and releases it
              after :stop, so the package's module-level functions
              reach the running instance and nothing reaches a stopped
              one
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
  (unless (util/callable? (get opts :start))
    (errorf "component %q: a :start function is required" key))
  (each fk [:stop :health]
    (when-let [f (get opts fk)]
      (unless (util/callable? f)
        (errorf "component %q: %q must be a function, got %q" key fk f))))
  (when-let [a (get opts :ambient)]
    (unless (ambient? a)
      (errorf "component %q: :ambient must be a `system/ambient` declaration, got %q" key a)))
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

(defn- collect-components
  "Component definitions -> key -> definition, refusing a duplicate key
  and naming both plugins; a dictionary is taken as already keyed."
  [components]
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

(defn- interface-providers
  "Interface -> the keys of the components that :provide it, in key
  order."
  [comps]
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

(defn- topo-sort
  "The start order: a depth-first walk over the resolved dependencies,
  keys visited in sorted order so the result is stable; a cycle is an
  error printing the path around it."
  [comps resolution]
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

(defn- check-component-config
  "Validate every component's deprecated `:config :schema` against its
  slice of `config` — all of them, one error listing every failure —
  through config/validate, the same call bootstrap makes for a
  manifest's :config-schema; a system built outside a boot has no
  manifest, so this is where its schemas are honoured."
  [comps config]
  (def specs
    (seq [k :in (sorted (keys comps))
          :let [c (comps k)]
          :when (get-in c [:config :schema])]
      {:component k
       :plugin (get c :plugin)
       :key (get-in c [:config :key])
       :schema (get-in c [:config :schema])}))
  (def errors (config/validate {:values config} specs))
  (unless (empty? errors)
    (errorf "component config failed schema validation:\n  - %s"
            (string/join errors "\n  - "))))

(defn init
  ``Validate component definitions and build a system value.

  `components` is a registry table (key -> definition) or an indexed
  collection of definitions; `config` is the application config map.
  Fails fast on duplicate keys, missing dependencies, unresolved
  interface conflicts, dependency cycles and a config slice failing a
  component's (deprecated) :config :schema — before anything starts.

  The returned system is plain data:
    :components  key -> definition
    :providers   interface -> keys of implementations
    :resolution  key -> {dep-ref resolved-key}
    :order       topological start order
    :config      the config map
    :instances   key -> running instance
    :states      key -> :running | :stopped
    :boot        the boot value, once `attach-boot!` gave it one``
  [components &opt config]
  (default config {})
  (def comps (collect-components components))
  # `:void/boot` is a ref the graph never resolves; a component wearing
  # the name would be resolvable by it, and then nobody could say which
  # of the two a `:deps [:void/boot]` meant
  (when (in comps boot-ref)
    (errorf "%q is reserved — it is the boot pseudo-dependency, not a component (%s)"
            boot-ref (plugin-of (comps boot-ref))))
  (def providers (interface-providers comps))
  (when-let [ps (get providers boot-ref)]
    (errorf "component %q (%s) provides %q, which is reserved for the boot pseudo-dependency"
            (first ps) (plugin-of (comps (first ps))) boot-ref))
  # >1 implementation demands an explicit config {:impl ...} choice even
  # when nothing depends on the interface yet — instance lookup by
  # interface must never be ambiguous.
  (each iface (sorted (keys providers))
    (when (> (length (providers iface)) 1)
      (resolve-ref comps providers config "interface" iface)))
  (def resolution @{})
  (each k (sorted (keys comps))
    (def comp (comps k))
    (def res @{})
    (each ref (get comp :deps [])
      # the boot is handed over at :start, not resolved here: it is not
      # a node, so it stays out of the order and out of the closure
      # `needed-keys` walks
      (unless (= ref boot-ref)
        (put res ref
             (resolve-ref comps providers config
                          (string/format "component %q (%s)" k (plugin-of comp))
                          ref))))
    (put resolution k res))
  (def order (topo-sort comps resolution))
  (check-component-config comps config)
  @{:components comps
    :providers providers
    :resolution resolution
    :order order
    :config config
    :instances @{}
    :states @{}})

# -- lifecycle -----------------------------------------------------------

(defn- component-config
  "The config slice a component declared with :config {:key}; nil for
  a component without one. Validated already — by `init` for a
  deprecated :config :schema, by bootstrap phase 2 for the manifest's."
  [comp config]
  (when-let [spec (get comp :config)]
    (get config (spec :key))))

(defn- resolved-deps
  "Build the deps struct passed to :start. Every ref is the instance of
  the component it resolved to, except `boot-ref`, which is the boot
  the system was attached to — a system started outside a bootstrap has
  none, and a component that asked for one says so rather than
  receiving nil."
  [sys k]
  (def out @{})
  (eachp [ref rk] (get-in sys [:resolution k] {})
    (put out ref (get-in sys [:instances rk])))
  (when (index-of boot-ref (get-in sys [:components k :deps] []))
    (put out boot-ref
         (or (get sys :boot)
             (errorf (string "component %q depends on %q, but this system has no boot "
                             "— it was built by system/init and never attached to one "
                             "(plugin/start! and test/start! do that; system/attach-boot! is the seam)")
                     k boot-ref))))
  (table/to-struct out))

(defn- start-instance
  "Call the component's :start with its resolved deps and config slice,
  put the instance in the component's `:ambient` when it declares one,
  and return it."
  [sys k]
  (def comp (get-in sys [:components k]))
  (def inst ((comp :start) (resolved-deps sys k)
                           (component-config comp (sys :config))))
  (when-let [a (get comp :ambient)] (hold! a inst))
  inst)

(defn- forget-instance
  "Drop what the system remembers about a stopped component: the
  instance, the state, and the `:ambient` cell — the last one because a
  package's module-level functions read it, and an ambient left full
  after :stop is a pool that answers queries on closed connections."
  [sys k]
  (when-let [a (get-in sys [:components k :ambient])] (release! a))
  (put (sys :instances) k nil)
  (put (sys :states) k :stopped))

(defn- stop-instance
  "Call the component's :stop with its instance, when it declares one —
  the ambient is still full while it runs, since a :stop that closes
  what it built often goes through the package's own functions — then
  forget the instance and mark it :stopped."
  [sys k]
  (def comp (get-in sys [:components k]))
  (defer (forget-instance sys k)
    (when-let [stop-fn (get comp :stop)]
      (stop-fn (get-in sys [:instances k])))))

(defn needed-keys
  "Expand a set of component keys to their transitive dependency
  closure — the minimal subset that can start on its own (the CLI
  bootstraps command :needs through this). Unknown keys are an error."
  [sys ks]
  (def wanted @{})
  (defn visit [k]
    (unless (get-in sys [:components k])
      (errorf "unknown component %q (known: %s)"
              k (string/join (map |(string/format "%q" $)
                                  (sorted (keys (sys :components))))
                             " ")))
    (unless (in wanted k)
      (put wanted k true)
      (each rk (sorted (values (get-in sys [:resolution k] {})))
        (visit rk))))
  (each k ks (visit k))
  wanted)

(defn start
  ``Start components in dependency order — all of them, or, with
  `subset` (component keys), only those plus their transitive
  dependencies (partial bootstrap for CLI commands and fixtures).

  If a component fails to start, **this call's** work is undone: the
  components it started are stopped in reverse order (best effort) and
  the error is rethrown. What was already running when the call began
  is left running, which is the difference that matters on the subset
  path — `void jobs work` starts its queue, then starts what the jobs
  need, and a missing library in the second call used to take the
  first one's pool down with it.

  Returns the system.``
  [sys &opt subset]
  (def wanted (when subset (needed-keys sys subset)))
  (def started @[])
  (each k (sys :order)
    (when (and (or (nil? wanted) (in wanted k))
               (not= :running (get-in sys [:states k])))
      (try
        (do
          (put (sys :instances) k (start-instance sys k))
          (put (sys :states) k :running)
          (array/push started k))
        ([e f]
          (each j (reverse started)
            (try (stop-instance sys j) ([_] (forget-instance sys j))))
          (propagate e f)))))
  sys)

(defn stop
  "Stop running components in reverse dependency order. With `timeout`
  (seconds) each component's :stop runs under ev/with-deadline — a hung
  stop is cancelled and reported instead of blocking shutdown. A stop
  error does not prevent the remaining components from stopping;
  failures are collected and rethrown as one error at the end. Returns
  the system."
  [sys &opt timeout]
  (def failures @[])
  (each k (reverse (sys :order))
    (when (= :running (get-in sys [:states k]))
      (try (if timeout
             (ev/with-deadline timeout (stop-instance sys k))
             (stop-instance sys k))
        ([e]
          (forget-instance sys k)
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

(defn stop-key
  ``Stop component `k` and its transitive dependents, in reverse
  dependency order — the counterpart of a subset `start`, and what a
  caller needs when it opened part of the graph for one piece of work
  and that work is done. Nothing else is touched. A stop error is
  collected and rethrown at the end, as in `stop`. Returns the
  system.``
  [sys k]
  (unless (get-in sys [:components k])
    (errorf "unknown component %q%s" k (util/suggest k (keys (sys :components)))))
  (def failures @[])
  # [k ;dependents] is start order — a dependent starts after what it
  # depends on — so the reverse is the order to stop them in
  (each j (reverse [k ;(dependents-of sys k)])
    (when (= :running (get-in sys [:states j]))
      (try (stop-instance sys j)
        ([e]
          (forget-instance sys j)
          (array/push failures (string/format "%q: %s" j (describe e)))))))
  (unless (empty? failures)
    (errorf "errors while stopping %q: %s" k (string/join failures "; ")))
  sys)

(defn restart
  ``Stop component `k` and its transitive dependents, then start them
  again — the reloaded workflow.

  A restart that fails half-way (the new :start throws — a port in
  TIME_WAIT, code that does not compile) does not lose what it took
  down: the components it left stopped are remembered on the system as
  :restart-pending, and the next `restart` of `k` picks them up again —
  so a dev-server restart that failed once recovers on the next attempt
  instead of staying down.``
  [sys k]
  (unless (get-in sys [:components k])
    (errorf "unknown component %q" k))
  (def pending (get sys :restart-pending {}))
  (def affected
    (filter |(or (= :running (get-in sys [:states $])) (in pending $))
            (dependents-of sys k)))
  # a dependent a previous failed restart already stopped is left as it
  # is — it only needs the start half below
  (each j (reverse affected)
    (when (= :running (get-in sys [:states j]))
      (stop-instance sys j)))
  (when (= :running (get-in sys [:states k]))
    (stop-instance sys k))
  (try
    (do
      (each j [k ;affected]
        (put (sys :instances) j (start-instance sys j))
        (put (sys :states) j :running))
      (put sys :restart-pending nil))
    ([e f]
      (def left @{})
      (each j [k ;affected]
        (unless (= :running (get-in sys [:states j]))
          (put left j true)))
      (put sys :restart-pending left)
      (propagate e f)))
  sys)

# -- inspection ----------------------------------------------------------

(defn health
  ``Aggregate component health: {:status :up|:down :components {...}}.
  A running component without a :health function reports {:status :up};
  the aggregate is :down if any component reports :down.

  A :health function that throws is `{:status :down :reason <the
  throw>}`, not a throw out of here: the one caller that matters is an
  endpoint answering "is this process healthy?", and a check that
  failed is the answer, not an accident. `plugin/health` folds the
  contributed checks the same way.``
  [sys]
  (def out @{})
  (each k (sys :order)
    (def comp (get-in sys [:components k]))
    (when (= :running (get-in sys [:states k]))
      (put out k (if-let [h (get comp :health)]
                   (let [[ok v] (protect (h (get-in sys [:instances k])))]
                     (if ok v {:status :down :reason (util/err-str v)}))
                   {:status :up}))))
  {:status (if (some |(= :down (get $ :status)) (values out)) :down :up)
   :components (table/to-struct out)})

(defn instance
  "Return the running instance for a component key or interface ref."
  [sys ref]
  (def comps (sys :components))
  (def k (if (in comps ref)
           ref
           (resolve-ref comps (sys :providers) (sys :config)
                        "instance lookup" ref)))
  (get-in sys [:instances k]))

# -- the boot a system belongs to ----------------------------------------

(def running-boot
  ``The boot the system in this process is running: `attach-boot!` puts
  it there, `detach-boot!` takes it away, and the dyn `:void/boot`
  overrides it for a scope.

  This is what a package's module-level functions read when they need
  the hook registry, a resolved extension point or a config slice and
  have no system in hand — `plugin/boot`. It is not
  `plugin/last-boot`: that one is the most recent *bootstrap*, which is
  a different value under a test suite (test bootstraps are untracked)
  and under any process that bootstraps twice.``
  (ambient boot-ref :of "the running boot" :from :void/core))

(defn attach-boot!
  ``Give `sys` its boot and make it the process's running boot.

  Two things at once, because they are one fact: from here until
  `detach-boot!`, this boot is the one in force. Components declaring
  `:deps [:void/boot]` receive it at :start; module-level code reads it
  through `running-boot`. `plugin/start!` and `test/start!` call this
  before starting the graph — a bootstrap that never starts is not
  running anything, so `plugin/bootstrap` and `dry-run` do not.``
  [sys boot]
  (put sys :boot boot)
  (hold! running-boot boot)
  sys)

(defn detach-boot!
  "Release the process's running boot — what `plugin/shutdown!` and
  `test/stop!` do after the graph is down. The system keeps its own
  `:boot`, so a stopped system can still be inspected."
  [sys]
  (release! running-boot)
  sys)
