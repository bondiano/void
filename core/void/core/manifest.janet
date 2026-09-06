### void/core/manifest — what a plugin declares about itself.
###
### Owns the manifest: the frozen struct a plugin package exports —
### :void-api, :version, :requires, :config-key/-schema/-defaults,
### :when, :components, :contributes, :extension-points, :hooks,
### :on-load, :source — every option checked and normalized at
### definition time so that boot reads one shape; the process-wide
### registry that resolves a keyword :plugins entry; and `defplugin`,
### the module sugar that folds the extension collector's queue into
### the manifest and registers it. The seam is here because a manifest
### is data about one plugin, complete before any boot exists: it
### leans on semver (are the :requires constraints well-formed) and on
### extension (is this a point contract) but knows nothing of phases,
### config loading or the component graph, which read it later.

(import ./init :as core)
(import ./schema :as schema)
(import ./util :as util)
(import ./semver :as semver)
(import ./extension :as extension)

(def- allowed-manifest-keys
  {:name true :doc true :void-api true :version true :requires true
   :config-key true :config-schema true :config-defaults true
   :when true :components true :contributes true :extension-points true
   :hooks true :on-load true :source true})

(defn- plugin-name
  "The plugin's name as a keyword: `defplugin` passes the bare symbol
  a module writes (`void/redis`), `manifest` callers may pass either."
  [name]
  (cond
    (keyword? name) name
    (symbol? name) (keyword name)
    (errorf "plugin name must be a symbol or keyword, got %q" name)))

(defn- normalize-requires
  "Normalize :requires to a frozen {plugin-keyword constraint-or-true}:
  nil is no requirements, a tuple of names means any version, and a
  dictionary's constraint strings are parsed now so a typo in
  \">=0.x\" fails where the plugin is defined, not at boot."
  [name requires]
  (defn req-key [k]
    (cond
      (keyword? k) k
      (symbol? k) (keyword k)
      (errorf "plugin %q: :requires key must be a keyword or symbol, got %q" name k)))
  (cond
    (nil? requires) {}

    (dictionary? requires)
    (do
      (def out @{})
      (eachp [k v] requires
        (def rk (req-key k))
        (cond
          (= v true) (put out rk true)
          (string? v)
          (do
            (each tok (filter |(not (empty? $)) (string/split " " v))
              (semver/parse-constraint tok))
            (put out rk v))
          (errorf "plugin %q: :requires %q must be a semver constraint string or true, got %q"
                  name rk v)))
      (freeze out))

    (indexed? requires)
    (freeze (tabseq [k :in requires] (req-key k) true))

    (errorf "plugin %q: :requires must be a dictionary {plugin \"constraint\"} or a tuple of plugin names, got %q"
            name requires)))

(defn- normalize-components
  "Check :components is a tuple of component definitions (a :key and
  a callable :start, see system/component) and stamp each with
  :plugin — the attribution `why` and the graph errors report — unless
  the definition names one already."
  [name components]
  (unless (indexed? components)
    (errorf "plugin %q: :components must be a tuple of component definitions, got %q"
            name components))
  (tuple
    ;(seq [c :in components]
       (do
         (unless (and (dictionary? c) (keyword? (get c :key)) (util/callable? (get c :start)))
           (errorf "plugin %q: :components entries must be component definitions (see system/component), got %q"
                   name c))
         (if (get c :plugin)
           c
           (table/to-struct (merge-into @{} c {:plugin name})))))))

(defn- normalize-contributes
  "Check :contributes is {point-keyword [contribution ...]} and freeze
  it; the contributions themselves are validated against the point's
  schema in bootstrap phase 4, when the point is known."
  [name contributes]
  (unless (dictionary? contributes)
    (errorf "plugin %q: :contributes must be a dictionary point -> contributions, got %q"
            name contributes))
  (def out @{})
  (eachp [k v] contributes
    (unless (keyword? k)
      (errorf "plugin %q: :contributes keys must be extension-point keywords, got %q" name k))
    (unless (indexed? v)
      (errorf "plugin %q: :contributes %q must be a tuple of contributions, got %q" name k v))
    (put out k (tuple ;v)))
  (freeze out))

(defn- normalize-points
  "Check :extension-points is {name point}: a built point must be
  stored under its own name; an options dictionary is built into one
  with `extension-point` here, so a manifest can be written as plain
  data."
  [name points]
  (unless (dictionary? points)
    (errorf "plugin %q: :extension-points must be a dictionary name -> point, got %q"
            name points))
  (def out @{})
  (eachp [k v] points
    (unless (keyword? k)
      (errorf "plugin %q: :extension-points keys must be keywords, got %q" name k))
    (put out k
         (cond
           (extension/point? v)
           (do (unless (= (v :name) k)
                 (errorf "plugin %q: extension point %q is stored under key %q" name (v :name) k))
               v)
           (dictionary? v) (extension/extension-point k ;(mapcat identity (pairs v)))
           (errorf "plugin %q: extension point %q must be built with extension-point or given as an options dictionary, got %q"
                   name k v))))
  (freeze out))

(defn manifest
  ``Build and validate a plugin manifest — a frozen struct that can be
  pp'd, diffed and serialized. `defplugin` is the module sugar over this.

  Options:
    :void-api         plugin protocol version (default: the host's)
    :version          semver string, default "0.0.0"
    :requires         {plugin "constraint"} (semver, see satisfies?) or
                      a tuple of plugin names (any version)
    :config-key       config slice owned by the plugin
    :config-schema    schema (or validator fn) for that slice, checked
                      in bootstrap phase 2 — batched across plugins
    :config-defaults  the plugin-defaults config layer for :config-key
    :when             (fn [config-values] bool) — conditional
                      activation, phase 3
    :components       tuple of component definitions (system/component)
    :contributes      {point [contribution ...]} into other plugins'
                      extension points
    :extension-points {name point} — this plugin's own points
    :hooks            tuple of the core-hook names this plugin *fires*
                      (hooks/run! on the boot registry, or its own walk
                      over hooks/handlers): the declaration that lets a
                      :void.core/hooks contribution for a misspelt name
                      be reported at boot, and a fire of an undeclared
                      name warn
    :on-load          (fn [ctx]) load-time hook (codegen etc.); ctx is
                      {:name :manifest :plugins :profile}
    :source           path of the defining file — `defplugin` fills it
                      from (dyn :current-file); void/dev uses it to map
                      changed files to components for auto-restart
    :doc              docstring``
  [name & kvs]
  (def pname (plugin-name name))
  (when (odd? (length kvs))
    (errorf "plugin %q: expected key-value option pairs" pname))
  (def opts (table ;kvs))
  (eachk k opts
    (unless (in allowed-manifest-keys k)
      (errorf "plugin %q: unknown option %q (allowed: %s)"
              pname k (util/names-str (keys allowed-manifest-keys)))))
  (def api (get opts :void-api core/void-api))
  (unless (and (number? api) (= api (math/trunc api)))
    (errorf "plugin %q: :void-api must be an integer, got %q" pname api))
  (def version (get opts :version "0.0.0"))
  (semver/parse-version version)
  (when-let [d (get opts :doc)]
    (unless (string? d)
      (errorf "plugin %q: :doc must be a string, got %q" pname d)))
  (each fk [:when :on-load]
    (when-let [f (get opts fk)]
      (unless (util/callable? f)
        (errorf "plugin %q: %q must be a function, got %q" pname fk f))))
  (when-let [ck (get opts :config-key)]
    (unless (keyword? ck)
      (errorf "plugin %q: :config-key must be a keyword, got %q" pname ck)))
  (each ck [:config-schema :config-defaults]
    (when (and (get opts ck) (nil? (get opts :config-key)))
      (errorf "plugin %q: %q requires :config-key" pname ck)))
  (when-let [cd (get opts :config-defaults)]
    (unless (dictionary? cd)
      (errorf "plugin %q: :config-defaults must be a dictionary, got %q" pname cd)))
  (when-let [cs (get opts :config-schema)]
    (unless (util/callable? cs)
      (def [ok e] (protect (schema/normalize cs)))
      (unless ok
        (errorf "plugin %q: invalid :config-schema: %s" pname (util/err-str e)))))
  (when-let [src (get opts :source)]
    (unless (string? src)
      (errorf "plugin %q: :source must be a string, got %q" pname src)))
  (def fired (get opts :hooks []))
  (unless (and (indexed? fired) (all keyword? fired))
    (errorf "plugin %q: :hooks must be a tuple of keywords, got %q" pname fired))
  (freeze
    {:name pname
     :doc (get opts :doc)
     :void-api api
     :version version
     :requires (normalize-requires pname (get opts :requires))
     :config-key (get opts :config-key)
     :config-schema (get opts :config-schema)
     :config-defaults (get opts :config-defaults)
     :when (get opts :when)
     :components (normalize-components pname (get opts :components []))
     :contributes (normalize-contributes pname (get opts :contributes {}))
     :extension-points (normalize-points pname (get opts :extension-points {}))
     :hooks (tuple ;fired)
     :on-load (get opts :on-load)
     :source (get opts :source)}))

# -- registry + defplugin -------------------------------------------------

(def manifest-registry
  "Manifests registered by `defplugin`, keyed by plugin name; bootstrap
  resolves keyword :plugins entries here."
  @{})

(defn register-manifest!
  "Register a manifest for keyword lookup in :plugins (re-registering
  replaces — REPL-friendly). Returns the manifest."
  [m]
  (put manifest-registry (m :name) m)
  m)

(defn- merge-collected
  "Fold the module-level contribute!/defextension-point queue into
  a manifest and clear the queue."
  [m]
  (def {:points queued-points :contributes queued} (extension/drain-collected!))
  (if (and (empty? queued-points) (empty? queued))
    m
    (do
      (def contributes (merge-into @{} (m :contributes)))
      (eachp [k vals] queued
        (put contributes k (tuple ;(get contributes k []) ;vals)))
      (def points (merge-into @{} (m :extension-points)))
      (eachp [k p] queued-points
        (when (in points k)
          (errorf "plugin %q: extension point %q is declared both in the manifest and via defextension-point"
                  (m :name) k))
        (put points k p))
      (freeze (merge-into @{} m {:contributes (freeze contributes)
                                 :extension-points (freeze points)})))))

(defmacro defplugin
  ``Define this module's plugin manifest and export it as `manifest`:

      (defplugin void/redis
        :version "0.3.0"
        :requires {void/core ">=0.1"}
        :config-key :redis
        :config-schema RedisConfig
        :components [redis-pool]
        :contributes {:void.core/health [redis-health]})

  Contributions and extension points declared earlier in the module via
  `contribute!` / `defextension-point` are folded in. The manifest
  is also registered in `manifest-registry`, so the project can list
  the plugin by keyword after requiring the module. The defining file
  is recorded as :source (overridable by passing :source explicitly).``
  [name & kvs]
  ~(def manifest
     (,register-manifest!
       (,merge-collected (,manifest ',name :source (,dyn :current-file) ,;kvs)))))
