### void/core/plugin — plugin API.
###
### Plugin = a janet package exporting a manifest: a frozen struct with
### :void-api, :version, :requires (semver), :config-key/-schema,
### :when, :components, :contributes, :extension-points and :on-load.
### Extension point = a named contract: contribution schema +
### :cardinality (:many/:single/:single-required) + a :reduce fold +
### optional cross-checks. Bootstrap runs seven phases, all before
### anything opens a port: load -> config -> conditional -> extension
### resolution -> graph -> start -> ready; every phase collects its
### errors and fails in one batch naming the source plugin. `dry-run`
### executes phases 1-5 only — full validation of a system
### configuration in CI in milliseconds. REPL tools: (plugin/inspect),
### (plugin/why :key), (plugin/extension :point).

(import ./init :as core)
(import ./system :as system)
(import ./config :as config)
(import ./schema :as schema)
(import ./hooks :as hooks)
(import ./log :as log)
(import ./deploy :as deploy)

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(defn- err-str [e]
  (if (string? e) e (describe e)))

(defn- names-str [names]
  (string/join (map |(string/format "%q" $) (sorted names)) " "))

# -- did-you-mean --------------------------------------------------------

(defn- levenshtein [a b]
  (def lb (length b))
  (var prev (seq [j :range [0 (inc lb)]] j))
  (for i 1 (inc (length a))
    (def cur @[i])
    (for j 1 (inc lb)
      (array/push cur
                  (min (inc (cur (dec j)))
                       (inc (prev j))
                       (+ (prev (dec j))
                          (if (= (a (dec i)) (b (dec j))) 0 1)))))
    (set prev cur))
  (prev lb))

(defn- suggest [name candidates]
  (def s (string name))
  (var best nil)
  (var best-d math/inf)
  (each c (sorted candidates)
    (def d (levenshtein s (string c)))
    (when (< d best-d) (set best-d d) (set best c)))
  (if (and best (<= best-d 3) (< best-d (length s)))
    (string/format " — did you mean %q?" best)
    ""))

# -- semver --------------------------------------------------------------

(defn parse-version
  "Parse \"1.2.3\" (also \"v1.2\", \"0.1\", prerelease tail ignored)
  into a [major minor patch] tuple; missing parts default to 0."
  [s]
  (unless (string? s)
    (errorf "version must be a string, got %q" s))
  (def src (if (string/has-prefix? "v" s) (string/slice s 1) s))
  (def parts (string/split "." (first (string/split "-" src))))
  (when (or (empty? parts) (> (length parts) 3))
    (errorf "cannot parse version %q" s))
  (def nums
    (map (fn [p]
           (def n (scan-number p))
           (unless (and n (>= n 0) (= n (math/trunc n)))
             (errorf "cannot parse version %q" s))
           n)
         parts))
  [(get nums 0 0) (get nums 1 0) (get nums 2 0)])

(defn- vcmp [a b]
  (var r 0)
  (loop [i :range [0 3] :while (zero? r)]
    (set r (cmp (a i) (b i))))
  r)

(defn- caret-upper [v]
  (cond
    (pos? (v 0)) [(inc (v 0)) 0 0]
    (pos? (v 1)) [0 (inc (v 1)) 0]
    [0 0 (inc (v 2))]))

(defn- parse-constraint [tok]
  (def [op rest]
    (cond
      (string/has-prefix? ">=" tok) [:>= (string/slice tok 2)]
      (string/has-prefix? "<=" tok) [:<= (string/slice tok 2)]
      (string/has-prefix? ">" tok) [:> (string/slice tok 1)]
      (string/has-prefix? "<" tok) [:< (string/slice tok 1)]
      (string/has-prefix? "=" tok) [:= (string/slice tok 1)]
      (string/has-prefix? "^" tok) [:caret (string/slice tok 1)]
      (string/has-prefix? "~" tok) [:tilde (string/slice tok 1)]
      [:= tok]))
  [op (parse-version rest)])

(defn satisfies?
  ``True when a version satisfies a constraint string: space-separated
  comparators, all of which must hold — ">=0.1 <0.5", "^1.2" (same
  major, or same minor while major is 0), "~1.2" (same minor),
  "1.2.3" (exact).``
  [version constraint]
  (def v (if (string? version) (parse-version version) version))
  (all (fn [tok]
         (def [op c] (parse-constraint tok))
         (case op
           :>= (>= (vcmp v c) 0)
           :<= (<= (vcmp v c) 0)
           :> (> (vcmp v c) 0)
           :< (< (vcmp v c) 0)
           := (zero? (vcmp v c))
           :caret (and (>= (vcmp v c) 0) (neg? (vcmp v (caret-upper c))))
           :tilde (and (>= (vcmp v c) 0)
                       (neg? (vcmp v [(c 0) (inc (c 1)) 0])))))
       (filter |(not (empty? $)) (string/split " " constraint))))

# -- extension points ----------------------------------------------------

(def- allowed-point-keys
  {:name true :doc true :schema true :cardinality true
   :reduce true :validate true :aliases true})

(def- cardinalities {:many true :single true :single-required true})

(defn extension-point
  ``Build a named extension-point contract:

      (plugin/extension-point :void.http/middleware
        :doc "HTTP middleware registered by plugins"
        :schema {:name :keyword :phase [:int {:min 0 :max 10000}]
                 :wrap :function}
        :cardinality :many
        :reduce (fn [contribs] (sorted-by |($ :phase) contribs)))

  Options:
    :schema       schema every contribution is validated against
    :cardinality  :many (default) | :single | :single-required
    :reduce       (fn [contributions] resolved) — how the host folds
                  the contributions of all active plugins; defaults to
                  the tuple of contributions (:many) / the single
                  contribution (:single, :single-required)
    :validate     (fn [contributions]) — optional cross-checks (name
                  conflicts etc.), failure = throw
    :aliases      deprecated former names of this point: contributions addressed to an alias fold into
                  this point with a deprecation warning — renaming a
                  point is new-point + alias, never mutation
    :doc          docstring``
  [name & kvs]
  (unless (keyword? name)
    (errorf "extension point name must be a keyword, got %q" name))
  (when (odd? (length kvs))
    (errorf "extension point %q: expected key-value option pairs" name))
  (def opts (table ;kvs))
  (eachk k opts
    (unless (in allowed-point-keys k)
      (errorf "extension point %q: unknown option %q (allowed: %s)"
              name k (names-str (keys allowed-point-keys)))))
  (def card (get opts :cardinality :many))
  (unless (in cardinalities card)
    (errorf "extension point %q: :cardinality must be :many, :single or :single-required, got %q"
            name card))
  (each fk [:reduce :validate]
    (when-let [f (get opts fk)]
      (unless (callable? f)
        (errorf "extension point %q: %q must be a function, got %q" name fk f))))
  (when-let [d (get opts :doc)]
    (unless (string? d)
      (errorf "extension point %q: :doc must be a string, got %q" name d)))
  (def aliases (get opts :aliases []))
  (unless (and (indexed? aliases) (all keyword? aliases))
    (errorf "extension point %q: :aliases must be a tuple of keywords, got %q"
            name aliases))
  (when (index-of name aliases)
    (errorf "extension point %q: cannot alias itself" name))
  (def sch
    (when-let [s (get opts :schema)]
      (def [ok n] (protect (schema/normalize s)))
      (unless ok
        (errorf "extension point %q: invalid :schema: %s" name (err-str n)))
      n))
  # :schema-source keeps the author's shorthand — the contract docs
  # (scripts/gen-contracts.janet) render it, :schema is the normalized
  # validator input
  (freeze (merge-into @{} opts {:name name :cardinality card :schema sch
                                :aliases (tuple ;aliases)
                                :schema-source (get opts :schema)})))

(defn- point? [x]
  (and (dictionary? x)
       (keyword? (get x :name))
       (in cardinalities (get x :cardinality))))

# -- module-level collector (contribute! / defextension-point) -----------

(def- collected @{:points @{} :contributes @{}})

(defn contribute!
  ``Contribute a value to another plugin's extension point:

      (contribute! :void.http/middleware
        {:name :redis-session :phase 3000 :wrap wrap-redis-session})

  The contribution lands in the manifest defined later in this module
  with `defplugin` and is validated against the point's schema during
  bootstrap phase 4. Returns the contribution.``
  [point-name value]
  (unless (keyword? point-name)
    (errorf "contribution target must be an extension-point keyword, got %q" point-name))
  (def arr (or (get-in collected [:contributes point-name])
               (let [a @[]]
                 (put-in collected [:contributes point-name] a)
                 a)))
  (array/push arr value)
  value)

(defn declare-point!
  "Queue an extension point for the `defplugin` manifest of the module
  being loaded (the macro `defextension-point` is sugar for building +
  queueing). Returns the point."
  [point]
  (unless (point? point)
    (errorf "expected an extension point (see extension-point), got %q" point))
  (when (get-in collected [:points (point :name)])
    (errorf "extension point %q is declared twice before defplugin" (point :name)))
  (put-in collected [:points (point :name)] point)
  point)

(defmacro defextension-point
  "Declare an extension point owned by the plugin defined later in this
  module with `defplugin`. See `extension-point` for options."
  [name & kvs]
  ~(,declare-point! (,extension-point ,name ,;kvs)))

# -- manifests -----------------------------------------------------------

(def- allowed-manifest-keys
  {:name true :doc true :void-api true :version true :requires true
   :config-key true :config-schema true :config-defaults true
   :when true :components true :contributes true :extension-points true
   :hooks true :on-load true :source true})

(defn- plugin-name [name]
  (cond
    (keyword? name) name
    (symbol? name) (keyword name)
    (errorf "plugin name must be a symbol or keyword, got %q" name)))

(defn- normalize-requires [name requires]
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
              (parse-constraint tok))
            (put out rk v))
          (errorf "plugin %q: :requires %q must be a semver constraint string or true, got %q"
                  name rk v)))
      (freeze out))

    (indexed? requires)
    (freeze (tabseq [k :in requires] (req-key k) true))

    (errorf "plugin %q: :requires must be a dictionary {plugin \"constraint\"} or a tuple of plugin names, got %q"
            name requires)))

(defn- normalize-components [name components]
  (unless (indexed? components)
    (errorf "plugin %q: :components must be a tuple of component definitions, got %q"
            name components))
  (tuple
    ;(seq [c :in components]
       (do
         (unless (and (dictionary? c) (keyword? (get c :key)) (callable? (get c :start)))
           (errorf "plugin %q: :components entries must be component definitions (see system/component), got %q"
                   name c))
         (if (get c :plugin)
           c
           (table/to-struct (merge-into @{} c {:plugin name})))))))

(defn- normalize-contributes [name contributes]
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

(defn- normalize-points [name points]
  (unless (dictionary? points)
    (errorf "plugin %q: :extension-points must be a dictionary name -> point, got %q"
            name points))
  (def out @{})
  (eachp [k v] points
    (unless (keyword? k)
      (errorf "plugin %q: :extension-points keys must be keywords, got %q" name k))
    (put out k
         (cond
           (point? v)
           (do (unless (= (v :name) k)
                 (errorf "plugin %q: extension point %q is stored under key %q" name (v :name) k))
               v)
           (dictionary? v) (extension-point k ;(mapcat identity (pairs v)))
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
              pname k (names-str (keys allowed-manifest-keys)))))
  (def api (get opts :void-api core/void-api))
  (unless (and (number? api) (= api (math/trunc api)))
    (errorf "plugin %q: :void-api must be an integer, got %q" pname api))
  (def version (get opts :version "0.0.0"))
  (parse-version version)
  (when-let [d (get opts :doc)]
    (unless (string? d)
      (errorf "plugin %q: :doc must be a string, got %q" pname d)))
  (each fk [:when :on-load]
    (when-let [f (get opts fk)]
      (unless (callable? f)
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
    (unless (callable? cs)
      (def [ok e] (protect (schema/normalize cs)))
      (unless ok
        (errorf "plugin %q: invalid :config-schema: %s" pname (err-str e)))))
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
  (if (and (empty? (collected :points)) (empty? (collected :contributes)))
    m
    (do
      (def contributes (merge-into @{} (m :contributes)))
      (eachp [k vals] (collected :contributes)
        (put contributes k (tuple ;(get contributes k []) ;vals)))
      (def points (merge-into @{} (m :extension-points)))
      (eachp [k p] (collected :points)
        (when (in points k)
          (errorf "plugin %q: extension point %q is declared both in the manifest and via defextension-point"
                  (m :name) k))
        (put points k p))
      (table/clear (collected :points))
      (table/clear (collected :contributes))
      (freeze (merge-into @{} m {:contributes (freeze contributes)
                                 :extension-points (freeze points)})))))

(defmacro defplugin
  ``Define this module's plugin manifest and export it as `manifest`
:

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

# -- core extension points -----------------------------------------------

(defn- unique-names [what]
  (fn [contribs]
    (def seen @{})
    (each c contribs
      (def n (get c :name))
      (when (in seen n)
        (errorf "duplicate %s %q" what n))
      (put seen n true))))

(def core-points
  "Extension points owned by void/core itself."
  (freeze
    {:void.core/cli
     (extension-point :void.core/cli
       :doc "CLI commands: {:name :db/migrate :fn <fn or symbol> :doc ... :needs [component-keys] :read-only? true|false}. :read-only? is the command's own answer to \"does running this change anything?\" — void/mcp exposes a read-only command to an agent as a tool and withholds every other one until an operator allowlists it, so silence means \"unknown\" and unknown is never offered"
       :schema {:name :keyword
                :fn [:or :function :symbol]
                :doc [:optional :string]
                :needs [:optional [:vector :keyword]]
                :read-only? [:optional :boolean]}
       :validate (unique-names "CLI command")
       :reduce |(sorted-by |($ :name) $))

     :void.core/health
     (extension-point :void.core/health
       :doc "Health checks beyond the per-component ones: {:name :fn}"
       :schema {:name :keyword :fn :function}
       :validate (unique-names "health check")
       :reduce |(sorted-by |($ :name) $))

     :void.core/store
     (extension-point :void.core/store
       :doc "Stores a second replica would have to see: {:name :void.http/session :what \"sessions\" :needs [component-keys] :ask (fn [boot] {:store :memory :shared? false|true|:by-design :why ... :replacement ...} | nil)}; asked once everything is up, and under [:deploy :shape] :fleet a per-process answer stops the boot. :needs are the components that have to be running for :ask to answer — the same convention as :void.core/cli, and what lets `void deploy check` survey a composition without opening a port"
       :schema {:name :keyword
                :what :string
                :ask :function
                :needs [:optional [:vector :keyword]]
                :doc [:optional :string]}
       :validate (unique-names "store declaration")
       :reduce |(sorted-by |($ :name) $))

     :void.core/log-sink
     (extension-point :void.core/log-sink
       :doc "Log record sinks: {:name :fn (fn [record])}; installed by plugin/start! next to the configured built-in sink"
       :schema {:name :keyword :fn :function :doc [:optional :string]}
       :validate (unique-names "log sink")
       :reduce |(sorted-by |($ :name) $))

     :void.core/log-serializer
     (extension-point :void.core/log-serializer
       :doc "Log value serializers by record key: {:key :err :fn (fn [value] shaped)}; the core ships the :err serializer"
       :schema {:key :keyword :fn :function :doc [:optional :string]}
       :validate (fn [contribs]
                   (def seen @{})
                   (each c contribs
                     (when (in seen (c :key))
                       (errorf "duplicate log serializer for %q" (c :key)))
                     (put seen (c :key) true)))
       :reduce (fn [contribs] (tabseq [c :in contribs] (c :key) (c :fn))))

     :void.core/config-source
     (extension-point :void.core/config-source
       :doc "Extra config sources (vault, consul): {:name :fn :priority}; consumed on config (re)load"
       :schema {:name :keyword :fn :function :priority [:optional :int]}
       :validate (unique-names "config source")
       :reduce |(sorted-by (fn [c] [(get c :priority 100) (c :name)]) $))

     :void.core/schema-type
     (extension-point :void.core/schema-type
       :doc "Custom schema types: {:name :money :spec <register-type! spec>}; registered during resolution"
       :schema {:name :keyword :spec :dictionary}
       :validate (unique-names "schema type")
       :reduce (fn [contribs]
                 (each c contribs
                   (schema/register-type! (c :name) (c :spec)))
                 (tuple ;(map |($ :name) contribs))))

     :void.core/schema-projection
     (extension-point :void.core/schema-projection
       :doc "Schema projections (openapi, proto, forms): {:name :fn}; registered during resolution"
       :schema {:name :keyword :fn :function}
       :validate (unique-names "schema projection")
       :reduce (fn [contribs]
                 (each c contribs
                   (schema/register-projection! (c :name) (c :fn)))
                 (tuple ;(map |($ :name) contribs))))

     :void.core/interface
     (extension-point :void.core/interface
       :doc "Interface declarations for component :provides: {:name :void/cache :doc ... :methods {...}}"
       :schema {:name :keyword
                :doc [:optional :string]
                :methods [:optional :dictionary]}
       :validate (unique-names "interface")
       :reduce (fn [contribs]
                 (freeze (tabseq [c :in contribs] (c :name) c))))

     :void.core/hooks
     (extension-point :void.core/hooks
       :doc "Lifecycle hooks: {:hook :before-start :fn (fn [boot]) :phase <int, default 1000> :name <keyword>}"
       :schema {:hook :keyword
                :fn :function
                :phase [:optional :int]
                :name [:optional :keyword]
                :doc [:optional :string]}
       :reduce |(sorted-by (fn [h] [(get h :phase 1000) (h :hook)]) $))}))

# -- bootstrap phases ----------------------------------------------------

(def- allowed-boot-opts {:plugins true :profile true :config true})

(defn- checked
  "Throw the batched phase errors, if any. `sources` (plugin name ->
  :source file) adds a `plugin files:` footer for the plugins the
  errors mention, pointing at the defining files."
  [phase errors &opt sources]
  (unless (empty? errors)
    (def files
      (seq [name :in (sorted (keys (or sources {})))
            :when (some |(string/find (string/format "%q" name) $) errors)]
        (string/format "%q -> %s" name (in sources name))))
    (errorf "plugin bootstrap failed at phase %q:\n  - %s%s"
            phase (string/join errors "\n  - ")
            (if (empty? files)
              ""
              (string "\n  plugin files:\n    " (string/join files "\n    "))))))

(defn- load-manifests
  "Phase 1 (load): resolve :plugins entries — manifest values, keywords
  looked up in manifest-registry, or module paths to require."
  [entries errors]
  (def out @[])
  (def seen @{})
  (each entry entries
    (def m
      (cond
        (and (dictionary? entry) (keyword? (get entry :name))) entry

        (keyword? entry)
        (or (get manifest-registry entry)
            (do (array/push errors (string/format "plugin %q is not registered — require its module first or pass its manifest" entry))
                nil))

        (or (string? entry) (symbol? entry))
        (let [[ok env] (protect (require (string entry)))]
          (if ok
            (or (get-in env ['manifest :value])
                (do (array/push errors (string/format "module %q does not export a manifest (use defplugin)" entry))
                    nil))
            (do (array/push errors (string/format "cannot load plugin module %q: %s" entry (err-str env)))
                nil)))

        (do (array/push errors (string/format "invalid :plugins entry %q — expected a manifest, a registered plugin keyword or a module path" entry))
            nil)))
    (when m
      (if (in seen (m :name))
        (array/push errors (string/format "plugin %q appears twice in :plugins" (m :name)))
        (do (put seen (m :name) true)
            (array/push out m)))))
  out)

(defn- check-compat
  "Phase 1 (load): :void-api compatibility and :requires (semver)."
  [ms errors]
  (def versions @{:void/core core/version})
  (each m ms (put versions (m :name) (m :version)))
  (each m ms
    (unless (= (m :void-api) core/void-api)
      (array/push errors
                  (string/format "plugin %q targets :void-api %d, this void/core implements %d"
                                 (m :name) (m :void-api) core/void-api)))
    (each r (sorted (keys (m :requires)))
      (def c (get-in m [:requires r]))
      (cond
        (nil? (versions r))
        (array/push errors
                    (string/format "plugin %q requires %q, which is not in the plugin list"
                                   (m :name) r))
        (and (string? c) (not (satisfies? (versions r) c)))
        (array/push errors
                    (string/format "plugin %q requires %q %s, but version %s is loaded"
                                   (m :name) r c (versions r)))))))

(defn- run-on-load [ms profile errors]
  (def names (tuple ;(map |($ :name) ms)))
  (each m ms
    (when-let [f (m :on-load)]
      (def [ok e] (protect (f {:name (m :name) :manifest m
                               :plugins names :profile profile})))
      (unless ok
        (array/push errors
                    (string/format "plugin %q: :on-load failed: %s" (m :name) (err-str e)))))))

(defn- load-boot-config
  "Phase 2 (config): layered load with plugin defaults, then batch
  validation of every :config-key against its :config-schema."
  [ms opts errors]
  (def copts (merge-into @{} (get opts :config {})))
  (when (get copts :defaults)
    (array/push errors ":config :defaults is reserved — plugin defaults come from manifests (:config-defaults)"))
  (put copts :defaults
       (seq [m :in ms :when (m :config-defaults)]
         {:plugin (m :name) :key (m :config-key) :defaults (m :config-defaults)}))
  (put copts :profile (get opts :profile :dev))
  (def [ok cfg] (protect (config/load copts)))
  (if ok
    (do
      (array/concat errors
                    (config/validate cfg
                                     (seq [m :in ms :when (m :config-schema)]
                                       {:plugin (m :name)
                                        :key (m :config-key)
                                        :schema (let [s (m :config-schema)]
                                                  (if (callable? s)
                                                    s
                                                    (fn [v] (schema/validate s v))))})))
      cfg)
    (do (array/push errors (err-str cfg))
        nil)))

(defn- split-active
  "Phase 3 (conditional): evaluate :when against the config values; an
  inactive plugin contributes neither components nor contributions. An
  active plugin requiring a deactivated one is an error."
  [ms cfg errors]
  (def active @[])
  (def inactive @[])
  (each m ms
    (if-let [w (m :when)]
      (let [[ok r] (protect (w (cfg :values)))]
        (cond
          (not ok)
          (array/push errors (string/format "plugin %q: :when failed: %s" (m :name) (err-str r)))
          r (array/push active m)
          (array/push inactive m)))
      (array/push active m)))
  (def active? (tabseq [m :in active] (m :name) true))
  (def loaded? (tabseq [m :in ms] (m :name) true))
  (each m active
    (each r (sorted (keys (m :requires)))
      (when (and (in loaded? r) (not (in active? r)))
        (array/push errors
                    (string/format "plugin %q requires %q, but it was deactivated by its :when condition"
                                   (m :name) r)))))
  [active inactive])

(defn- resolve-extensions
  "Phase 4 (extension resolution): collect points of active plugins +
  core points, validate every contribution against the point schema,
  enforce cardinality, run cross-checks and fold with :reduce."
  [active all errors]
  (def active-sorted (sorted-by |($ :name) active))
  (def points @{})
  (eachp [name p] core-points
    (put points name {:owner :void/core :point p}))
  (each m active-sorted
    (each name (sorted (keys (m :extension-points)))
      (if-let [prev (get points name)]
        (array/push errors
                    (string/format "extension point %q is declared by both %q and %q"
                                   name (prev :owner) (m :name)))
        (put points name {:owner (m :name) :point (get-in m [:extension-points name])}))))
  (def inactive-owners @{})
  (each m all
    (eachk name (m :extension-points)
      (unless (in points name)
        (put inactive-owners name (m :name)))))

  # deprecation aliases: a renamed point keeps its old name as an :aliases
  # entry; contributions addressed to the old name fold into the new point
  # with a warning
  (def aliases @{})
  (each pname (sorted (keys points))
    (each a (get-in points [pname :point :aliases] [])
      (cond
        (in points a)
        (array/push errors
                    (string/format "extension point %q declares alias %q, which is itself a declared point"
                                   pname a))
        (in aliases a)
        (array/push errors
                    (string/format "alias %q is claimed by both %q and %q"
                                   a (aliases a) pname))
        (put aliases a pname))))

  (def contribs @{})
  (each m active-sorted
    (each pname (sorted (keys (m :contributes)))
      (def canonical
        (cond
          (in points pname) pname
          (when-let [c (get aliases pname)]
            (eprintf "warning: plugin %q contributes to deprecated extension point %q — folded into %q"
                     (m :name) pname c)
            c)))
      (cond
        canonical
        (each v (get-in m [:contributes pname])
          (def arr (or (get contribs canonical)
                       (let [a @[]] (put contribs canonical a) a)))
          (array/push arr {:plugin (m :name) :value v}))

        (in inactive-owners pname)
        (array/push errors
                    (string/format "plugin %q contributes to %q, but its owner plugin %q is inactive"
                                   (m :name) pname (inactive-owners pname)))

        (array/push errors
                    (string/format "plugin %q contributes to unknown extension point %q%s"
                                   (m :name) pname
                                   (suggest pname (array/concat (array ;(keys points))
                                                                ;(keys aliases))))))))

  (def out @{})
  (each name (sorted (keys points))
    (def {:owner owner :point point} (points name))
    (def cs (get contribs name @[]))
    (def point-errors @[])
    (when-let [sch (point :schema)]
      (each c cs
        (def [ok res] (protect (schema/check sch (c :value))))
        (if ok
          (each e (res :errors)
            (array/push point-errors
                        (string/format "plugin %q: contribution to %q: %s"
                                       (c :plugin) name (schema/error-str e))))
          (array/push point-errors
                      (string/format "plugin %q: contribution to %q: %s"
                                     (c :plugin) name (err-str res))))))
    (defn from-str []
      (string/join (map |(string/format "%q" ($ :plugin)) cs) ", "))
    (case (point :cardinality)
      :single
      (when (> (length cs) 1)
        (array/push point-errors
                    (string/format "extension point %q has cardinality :single but received %d contributions (from: %s)"
                                   name (length cs) (from-str))))
      :single-required
      (unless (= 1 (length cs))
        (array/push point-errors
                    (string/format "extension point %q requires exactly one contribution, got %d%s"
                                   name (length cs)
                                   (if (empty? cs) "" (string " (from: " (from-str) ")")))))
      nil)
    (def values (tuple ;(map |($ :value) cs)))
    (var resolved nil)
    (when (empty? point-errors)
      (when-let [v (point :validate)]
        (def [ok e] (protect (v values)))
        (unless ok
          (array/push point-errors
                      (string/format "extension point %q: %s" name (err-str e)))))
      (when (empty? point-errors)
        (def reducef (or (point :reduce)
                         (if (= :many (point :cardinality)) identity first)))
        (def [ok v] (protect (reducef values)))
        (if ok
          (set resolved v)
          (array/push point-errors
                      (string/format "extension point %q: :reduce failed: %s" name (err-str v))))))
    (array/concat errors point-errors)
    (put out name @{:owner owner
                    :point point
                    :contributions (tuple ;cs)
                    :resolved resolved}))
  out)

(defn- build-system
  "Phase 5 (graph): components of active plugins -> system/init (dups,
  missing deps, interface conflicts, cycles). Every :provides interface
  must be declared via :void.core/interface."
  [active extensions cfg errors]
  (def comps (mapcat |($ :components) active))
  (def declared (or (get-in extensions [:void.core/interface :resolved]) {}))
  (each c comps
    (each iface (c :provides)
      (unless (in declared iface)
        (array/push errors
                    (string/format "component %q (plugin %q) provides undeclared interface %q — contribute a declaration to :void.core/interface"
                                   (c :key) (c :plugin) iface)))))
  (when (empty? errors)
    (def [ok sys] (protect (system/init comps (cfg :values))))
    (if ok
      sys
      (do (array/push errors (err-str sys))
          nil))))

(var current-boot
  "The boot value of the most recent bootstrap/start! in this process —
  the default subject of the zero-argument REPL tools (inspect, why,
  extension)."
  nil)

(defn- build-hooks
  ``Fold the :void.core/hooks contributions into a hooks/registry, each
  handler attributed to its source plugin. The registry is declared
  with every hook the active plugins say they fire (plus the lifecycle
  hooks) and owned by the active plugins' namespaces; a handler for a
  suspect name — undeclared, in a namespace an active plugin owns — is
  reported here with a did-you-mean, since it would otherwise wait
  forever. A handler for an absent plugin's hook is not suspect.``
  [active extensions]
  (def declared (tabseq [h :in hooks/lifecycle-hooks] h true))
  (each m active
    (each h (get m :hooks []) (put declared h true)))
  (def reg (hooks/registry (keys declared) (map |($ :name) active)))
  (each c (get-in extensions [:void.core/hooks :contributions] [])
    (def v (c :value))
    (when (hooks/suspect? reg (v :hook))
      (eprintf "warning: plugin %q registers a handler for hook %q, which no active plugin declares — it will never run%s"
               (c :plugin) (v :hook) (suggest (v :hook) (keys declared))))
    (hooks/add! reg (v :hook) (v :fn)
                :phase (get v :phase 1000)
                :name (get v :name)
                :doc (get v :doc)
                :plugin (c :plugin)))
  reg)

(defn- bootstrap* [opts track?]
  (unless (dictionary? opts)
    (errorf "bootstrap expects an options dictionary, got %q" opts))
  (eachk k opts
    (unless (in allowed-boot-opts k)
      (errorf "bootstrap: unknown option %q (allowed: %s)"
              k (names-str (keys allowed-boot-opts)))))
  (def profile (get opts :profile :dev))
  (def errors @[])

  (def ms (load-manifests (get opts :plugins []) errors))
  (def sources (tabseq [m :in ms :when (m :source)] (m :name) (m :source)))
  (check-compat ms errors)
  (when (empty? errors)
    (run-on-load ms profile errors))
  (checked :load errors sources)

  (def cfg (load-boot-config ms opts errors))
  # the deployment is resolved with the config and travels on the boot:
  # `dry-run` and `void deploy check` need the shape without starting
  # anything, and a bad [:deploy :shape] is a config error like any other
  (def dep (deploy/resolve! (if cfg (cfg :values) {}) profile errors))
  (checked :config errors sources)

  # the profile is reachable from a :when as (dyn :void/profile), the
  # same way config files already see it (config/load-file) — a plugin
  # that only belongs in some profiles (void/dev) deactivates itself
  (def [active inactive]
    (with-dyns [:void/profile profile]
      (split-active ms cfg errors)))
  (checked :conditional errors sources)

  (def extensions (resolve-extensions active ms errors))
  (checked :extension-resolution errors sources)

  (def sys (build-system active extensions cfg errors))
  (checked :graph errors sources)

  (def boot
    @{:phase :validated
      :profile profile
      :deploy dep
      :plugins (tuple ;(map |($ :name) ms))
      :manifests (tabseq [m :in ms] (m :name) m)
      :active (tuple ;(map |($ :name) active))
      :inactive (tuple ;(map |($ :name) inactive))
      :config cfg
      :extensions extensions
      :hooks (build-hooks active extensions)
      :system sys})
  (when track?
    (set current-boot boot))
  boot)

(defn bootstrap
  ``Run bootstrap phases 1-5 (load -> config -> conditional ->
  extension resolution -> graph) and return the boot value — nothing is
  started yet. Any error stops the run at its phase with the full batch
  of failures for that phase.

  Options:
    :plugins  manifests, registered plugin keywords or module paths
    :profile  :dev (default), :test, :prod, ...
    :config   options forwarded to config/load (:dir :files :env :cli
              ...); :defaults is reserved for manifest
              :config-defaults

  The boot value is plain data: :phase :profile :deploy :plugins
  :manifests :active :inactive :config :extensions :hooks :system.
  With a truthy
  `untracked` the boot is not recorded as the REPL tools' default
  subject (test bootstraps).``
  [opts &opt untracked]
  (bootstrap* opts (not untracked)))

# -- lifecycle -----------------------------------------------------------

(defn start!
  ``Phases 6-7: run the :config-loaded and :before-start hooks, start
  the component graph in dependency order, mark the boot :ready, run
  the :after-start hooks (see hooks/lifecycle-hooks; every handler
  receives the boot value), then survey the composition's stores
  against `[:deploy :shape]` — under `:fleet` a store living in one
  process's heap stops the boot with every violation in one error
, and the survey is left on the boot as :stores. Accepts a
  boot value from `bootstrap` or bootstrap options. Returns the boot
  value.``
  [boot-or-opts]
  (def boot (if (get boot-or-opts :system)
              boot-or-opts
              (bootstrap* boot-or-opts true)))
  # the logger comes up first: [:log] slice + profile pick the built-in
  # sink, contributed sinks/serializers install alongside
  (def log-cfg (get-in boot [:config :values :log]))
  (when log-cfg
    (def check (schema/check log/Config log-cfg))
    (unless (empty? (check :errors))
      (errorf "[:log] config invalid: %s"
              (string/join (map schema/error-str (check :errors)) "; "))))
  (log/configure! log-cfg (boot :profile))
  (when-let [sinks (get-in boot [:extensions :void.core/log-sink :resolved])]
    (unless (empty? sinks)
      (log/set-sinks! (array/concat (array ;(or (log/sinks) []))
                                    ;(map |($ :fn) sinks)))))
  (log/set-serializers!
    (or (get-in boot [:extensions :void.core/log-serializer :resolved]) {}))
  (hooks/run! (boot :hooks) :config-loaded boot)
  (hooks/run! (boot :hooks) :before-start boot)
  (system/start (boot :system))
  (put boot :phase :ready)
  # a failure past this line — an :after-start hook, the deploy check —
  # happens with every component already :running, and the error is
  # about to escape to a caller who will exit: stop the system and
  # flush the logger before it does, or the sockets, pools and workers
  # it survived keep running with nobody left to stop them
  (try
    (do
      (hooks/run! (boot :hooks) :after-start boot)
      # last, because it asks the stores that are now resolved — including
      # the ones a plugin resolves in an :after-start hook of its own
      # (void/security's limiter). Under [:deploy :shape] :fleet a store
      # living in one process's heap stops the boot here, with every
      # violation in one error
      (put boot :stores (deploy/check! boot)))
    ([e f]
      (try (system/stop (boot :system)) ([_]))
      (put boot :phase :stopped)
      (log/close!)
      (propagate e f)))
  boot)

(defn shutdown!
  "Run the :before-stop hooks, stop the system in reverse dependency
  order — each component's :stop under a deadline of `timeout` seconds
  (default 5); a hung stop is cancelled and reported instead of
  blocking shutdown — then run the :after-stop hooks. Stop hooks are
  protected: a failing handler is reported on stderr but never blocks
  the shutdown. Returns the boot value."
  [boot &opt timeout]
  (default timeout 5)
  (each e (hooks/run-protected! (boot :hooks) :before-stop boot)
    (eprint e))
  (system/stop (boot :system) timeout)
  (put boot :phase :stopped)
  (each e (hooks/run-protected! (boot :hooks) :after-stop boot)
    (eprint e))
  (log/close!)                    # stop async log writers
  boot)

(defn dry-run
  ``Phases 1-5 without starting anything — the full validation of a
  system configuration for CI: :void-api and :requires compatibility,
  config schemas, broken contributions, cardinality and :provides
  conflicts, dependency cycles. Throws with the batched error list on any
  failure; returns a summary report on success. Options as in
  `bootstrap`.``
  [opts]
  (def boot (bootstrap* opts false))
  {:ok true
   :profile (boot :profile)
   :deploy (boot :deploy)
   :plugins (boot :plugins)
   :active (boot :active)
   :inactive (boot :inactive)
   :components (tuple ;(get-in boot [:system :order] []))
   :extensions (tabseq [name :keys (boot :extensions)]
                 name {:owner (get-in boot [:extensions name :owner])
                       :contributions (length (get-in boot [:extensions name :contributions]))})})

# -- REPL tools ----------------------------------------------------------

(defn- pick-boot [boot]
  (or boot current-boot
      (error "no bootstrapped system — run plugin/bootstrap or plugin/start! first")))

(defn extension
  ``Resolved value of an extension point — what the point owner reads
  in its component's :start:

      (plugin/extension :void.core/cli)         # most recent boot
      (plugin/extension boot :void.core/cli)``
  [& args]
  (def [boot name]
    (case (length args)
      1 [nil (args 0)]
      2 args
      (error "usage: (extension point) or (extension boot point)")))
  (def b (pick-boot boot))
  (def e (get-in b [:extensions name]))
  (unless e
    (errorf "unknown extension point %q%s" name (suggest name (keys (b :extensions)))))
  (e :resolved))

(defn- check-value [c]
  (def [ok v] (protect ((c :fn))))
  (if ok v {:status :down :reason (if (string? v) v (describe v))}))

(defn health
  ``The health of a composition as data: every running component's
  `:health` folded together with every `:void.core/health`
  contribution, plus the aggregate.

      (plugin/health)        # most recent boot
      (plugin/health boot)

  `:down` anywhere is `:down` here; `:degraded` (what void/pressure
  reports while it sheds) is not down — a process refusing some
  requests on purpose is still the process a load balancer should
  keep. A health function that throws counts as down with the throw as
  its `:reason`: an endpoint that fails because a check failed fails
  exactly when something is already wrong.

  It lives here because it has two readers and neither owns it —
  void/obs-http answers `GET /health` with it and void/mcp publishes
  it as a resource. Both are projections; the fold is the core's.``
  [&opt boot]
  (def b (pick-boot boot))
  (def sys (get b :system))
  (def base (if sys (system/health sys) {:status :up :components {}}))
  (def checks
    (tabseq [c :in (get-in b [:extensions :void.core/health :resolved] [])]
      (c :name) (check-value c)))
  (def all (merge (base :components) checks))
  {:status (if (some |(= :down (get $ :status)) (values all)) :down :up)
   :components all})

(defn inspect
  ``Who registered what.

      (plugin/inspect)                    # plugin -> active? -> components -> contributions
      (plugin/inspect :void.core/cli)     # one point: owner, contributions with sources, resolved value
      (plugin/inspect boot)               # same, for an explicit boot value
      (plugin/inspect boot :void.core/cli)``
  [&opt a b]
  (def [boot sel]
    (cond
      (nil? a) [nil nil]
      (keyword? a) [nil a]
      [a b]))
  (def bt (pick-boot boot))
  (if sel
    (do
      (def e (get-in bt [:extensions sel]))
      (unless e
        (errorf "unknown extension point %q%s" sel (suggest sel (keys (bt :extensions)))))
      {:point sel
       :owner (e :owner)
       :doc (get-in e [:point :doc])
       :cardinality (get-in e [:point :cardinality])
       :schema (get-in e [:point :schema-source])
       :aliases (get-in e [:point :aliases])
       :contributions (e :contributions)
       :resolved (e :resolved)})
    (seq [name :in (sorted (keys (bt :manifests)))]
      (def m (get-in bt [:manifests name]))
      {:plugin name
       :version (m :version)
       :active (not (nil? (index-of name (bt :active))))
       :components (tuple ;(map |($ :key) (m :components)))
       :extension-points (tuple ;(sorted (keys (m :extension-points))))
       :contributes (tabseq [[p vs] :pairs (m :contributes)] p (length vs))})))

(defn why
  ``Why is a component in the graph, and who depends on it:

      (plugin/why :redis/pool)      # component: source plugin, deps, dependents
      (plugin/why :void/cache)      # interface: providers and the selected one
      (plugin/why boot :redis/pool)``
  [& args]
  (def [boot k]
    (case (length args)
      1 [nil (args 0)]
      2 args
      (error "usage: (why key) or (why boot key)")))
  (def bt (pick-boot boot))
  (def sys (bt :system))
  (cond
    (get-in sys [:components k])
    (do
      (def comp (get-in sys [:components k]))
      (def dependents @[])
      (eachp [c res] (sys :resolution)
        (eachp [ref rk] res
          (when (= rk k)
            (array/push dependents {:component c :via ref}))))
      {:key k
       :plugin (comp :plugin)
       :state (get-in sys [:states k] :not-started)
       :deps (get-in sys [:resolution k])
       :provides (comp :provides)
       :dependents (tuple ;(sorted-by |($ :component) dependents))})

    (get-in sys [:providers k])
    {:interface k
     :providers (tuple ;(get-in sys [:providers k]))
     :selected (get-in sys [:config k :impl])}

    (errorf "unknown component or interface %q%s"
            k (suggest k (keys (sys :components))))))
