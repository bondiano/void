### void/core/config — layered configuration (SPEC.md §3.2, ADR-0007).
###
### Layers in priority order: plugin defaults <- config files
### (config/default.janet|jdn, then config/<profile>.janet|jdn) <-
### env vars (VOID_DB__HOST -> [:db :host]) <- CLI overrides.
### The merge records the provenance of every value, queryable with
### `(config/explain cfg :database :host)`. Secret references
### ({:secret "DB_PASSWORD"}) are resolved at load time into opaque
### boxes that never print their value. Errors (unreadable files,
### unresolvable secrets, schema failures) are collected in one batch —
### fail fast, but with the full list.

(defn- path-str [path]
  (string/format "[%s]"
                 (string/join (map |(string/format "%q" $) path) " ")))

# -- secrets -------------------------------------------------------------

(def- secret-store
  "Box table -> revealed value. Weak keys: a value is dropped together
  with its box. The value never lives inside the box itself, so no
  print, log or REPL inspection of the config tree can leak it."
  (table/weak-keys 8))

(defn secret-spec?
  "True when a config value is a secret reference like
  {:secret \"DB_PASSWORD\"} (optionally with :file)."
  [x]
  (and (dictionary? x) (string? (get x :secret))))

(defn secret?
  "True when x is a resolved secret box produced by `load`."
  [x]
  (and (table? x) (not (nil? (in secret-store x)))))

(defn reveal
  "Return the value held by a secret box — the only way to get it.
  Printing the box shows the reference name, never the value."
  [box]
  (unless (secret? box)
    (errorf "not a secret box: %q" box))
  (in secret-store box))

(defn- make-secret [spec value]
  (def box @{:secret (spec :secret)})
  (put secret-store box value)
  box)

(defn- resolve-secret
  "Resolve one secret spec: custom sources first, then :file, then the
  env table. Returns [value nil] or [nil error-message]."
  [spec env sources]
  (def name (spec :secret))
  (if-let [v (some |($ spec) sources)]
    [v nil]
    (if-let [file (get spec :file)]
      (if (os/stat file)
        [(string/trim (slurp file)) nil]
        [nil (string/format "secret %s: file %s not found" name file)])
      (if-let [v (get env name)]
        [v nil]
        [nil (string/format "secret %s: env var %s is not set" name name)]))))

(defn- resolve-secrets! [node path env sources errors]
  (eachp [k v] node
    (def p (tuple ;path k))
    (cond
      (secret-spec? v)
      (let [[value err] (resolve-secret v env sources)]
        (if err
          (array/push errors (string/format "config %s: %s" (path-str p) err))
          (put node k (make-secret v value))))

      (table? v)
      (resolve-secrets! v p env sources errors))))

# -- layered merge with provenance ---------------------------------------

(defn- collect-leaves
  "Flatten a layer into [path value] leaves. Secret specs and empty
  dictionaries are leaves, not subtrees."
  [data path out]
  (if (and (dictionary? data)
           (not (secret-spec? data))
           (not (empty? data)))
    (eachp [k v] data
      (collect-leaves v (tuple ;path k) out))
    (array/push out [path data]))
  out)

(defn- assoc-path! [root path value]
  (var node root)
  (each k (slice path 0 -2)
    (unless (table? (get node k))
      (put node k @{}))
    (set node (get node k)))
  (put node (last path) value))

(defn- record! [provenance path source]
  (if-let [hist (get provenance path)]
    (array/push hist source)
    (put provenance path @[source])))

(defn- apply-layer! [vals provenance data source]
  (each [path value] (collect-leaves data [] @[])
    (when (next path)
      (assoc-path! vals path value)
      (record! provenance path source))))

# -- env vars ------------------------------------------------------------

(defn- parse-scalar
  "Coerce an env/CLI string: numbers, true/false/nil, JDN forms
  (keywords, tuples, dictionaries, quoted strings) — anything else
  stays a string."
  [s]
  (def n (scan-number s))
  (cond
    (not (nil? n)) n
    (= s "true") true
    (= s "false") false
    (= s "nil") nil
    (and (not (empty? s))
         (string/find (string/slice s 0 1) "{[(:@\""))
    (let [[ok v] (protect (parse s))] (if ok v s))
    s))

(defn- env-var-path
  "VOID_DB__POOL_SIZE -> [:db :pool-size]: strip the prefix, `__`
  separates nesting levels, `_` inside a segment becomes `-`."
  [name prefix]
  (tuple ;(map |(keyword (string/replace-all "_" "-" (string/ascii-lower $)))
               (string/split "__" (string/slice name (length prefix))))))

(defn- apply-env! [vals provenance env prefix]
  (each name (sorted (keys env))
    (when (and (string/has-prefix? prefix name)
               (> (length name) (length prefix))
               (not= name (string prefix "PROFILE")))
      (def path (env-var-path name prefix))
      (assoc-path! vals path (parse-scalar (env name)))
      (record! provenance path {:layer :env :var name}))))

# -- CLI overrides -------------------------------------------------------

(defn- parse-override
  "\"--database.host=x\" / \"database.host=x\" -> [[:database :host] \"x\" nil],
  or [nil nil error-message]."
  [arg]
  (def s (if (string/has-prefix? "--" arg) (string/slice arg 2) arg))
  (def eq (string/find "=" s))
  (if (or (nil? eq) (zero? eq))
    [nil nil (string/format "CLI override %q must look like path.to.key=value" arg)]
    (let [path (tuple ;(map keyword (string/split "." (string/slice s 0 eq))))
          value (parse-scalar (string/slice s (inc eq)))]
      [path value nil])))

(defn- apply-cli! [vals provenance cli errors]
  (cond
    (nil? cli) nil

    (dictionary? cli)
    (apply-layer! vals provenance cli {:layer :cli})

    (indexed? cli)
    (each arg cli
      (def [path value err] (parse-override arg))
      (if err
        (array/push errors err)
        (do
          (assoc-path! vals path value)
          (record! provenance path {:layer :cli :arg arg}))))

    (array/push errors
                (string/format ":cli must be a dictionary or a list of overrides, got %q" cli))))

# -- config files --------------------------------------------------------

(defn- read-config-file
  "Load one config file: .jdn is parsed as a single JDN value, .janet is
  evaluated in a fresh environment (the profile is available inside as
  (dyn :void/profile)); the result must be a dictionary."
  [path profile]
  (def [ok v]
    (protect
      (if (string/has-suffix? ".jdn" path)
        (parse (slurp path))
        (with-dyns [:void/profile profile]
          (eval-string (slurp path) (make-env))))))
  (cond
    (not ok) [nil (string/format "config file %s: %s" path (describe v))]
    (not (dictionary? v))
    [nil (string/format "config file %s must contain a dictionary, got %q" path v)]
    [v nil]))

(defn- config-files [dir profile files errors]
  (def out @[])
  (each path [(string dir "/default.jdn")
              (string dir "/default.janet")
              (string dir "/" profile ".jdn")
              (string dir "/" profile ".janet")]
    (when (os/stat path)
      (array/push out path)))
  (each path files
    (if (os/stat path)
      (array/push out path)
      (array/push errors (string/format "config file %s not found" path))))
  out)

# -- load ----------------------------------------------------------------

(def- allowed-load-opts
  {:defaults true :dir true :files true :profile true
   :env true :env-prefix true :cli true :secret-sources true})

(defn- apply-defaults! [vals provenance defaults layers errors]
  (defn add-layer [source data]
    (array/push layers source)
    (apply-layer! vals provenance data source))
  (cond
    (nil? defaults) nil

    (dictionary? defaults)
    (add-layer {:layer :defaults} defaults)

    (indexed? defaults)
    (each d defaults
      (if (and (dictionary? d) (keyword? (get d :key)) (dictionary? (get d :defaults)))
        (add-layer {:layer :defaults :plugin (get d :plugin)}
                   {(d :key) (d :defaults)})
        (array/push errors
                    (string/format "defaults entry must be {:plugin <kw> :key <kw> :defaults <dict>}, got %q" d))))

    (array/push errors
                (string/format ":defaults must be a dictionary or a list of per-plugin entries, got %q" defaults))))

(defn load
  ``Build the application config from layered sources (ADR-0007).

  Layers in priority order (later wins):
    1. plugin defaults        (:defaults option)
    2. config files           (:dir / :files)
    3. env vars               (VOID_DB__HOST -> [:db :host])
    4. CLI overrides          (:cli)

  Options:
    :defaults        dictionary (single layer) or indexed of
                     {:plugin <kw> :key <config-key> :defaults <dict>}
    :dir             directory scanned for default.janet|jdn and
                     <profile>.janet|jdn (default "config"; missing
                     files are fine)
    :files           explicit extra files, loaded after :dir files;
                     a missing file here is an error
    :profile         :dev (default), :test, :prod or any keyword
    :env             env table (default (os/environ)) — also the
                     source for secret references
    :env-prefix      default "VOID_"
    :cli             nested dictionary or list of "db.host=v" strings
    :secret-sources  functions (fn [spec] value-or-nil) tried first
                     when resolving {:secret "NAME"} references

  Secret references anywhere in the tree are resolved into opaque
  boxes (see `reveal`). All errors are collected and thrown in one
  batch. Returns a config table:
    :profile :values :provenance :layers``
  [&opt opts]
  (default opts {})
  (eachk k opts
    (unless (in allowed-load-opts k)
      (errorf "config/load: unknown option %q (allowed: %s)"
              k
              (string/join (map |(string/format "%q" $)
                                (sorted (keys allowed-load-opts)))
                           " "))))
  (def profile (get opts :profile :dev))
  (def env (get opts :env (os/environ)))
  (def prefix (get opts :env-prefix "VOID_"))
  (def errors @[])
  (def vals @{})
  (def provenance @{})
  (def layers @[])

  (apply-defaults! vals provenance (get opts :defaults) layers errors)

  (each path (config-files (get opts :dir "config") profile
                           (get opts :files []) errors)
    (def [data err] (read-config-file path profile))
    (if err
      (array/push errors err)
      (do
        (def source {:layer :file :path path})
        (array/push layers source)
        (apply-layer! vals provenance data source))))

  (array/push layers {:layer :env :prefix prefix})
  (apply-env! vals provenance env prefix)

  (when-let [cli (get opts :cli)]
    (array/push layers {:layer :cli})
    (apply-cli! vals provenance cli errors))

  (resolve-secrets! vals [] env (get opts :secret-sources []) errors)

  (unless (empty? errors)
    (errorf "config errors:\n  - %s" (string/join errors "\n  - ")))
  @{:profile profile
    :values vals
    :provenance provenance
    :layers layers})

# -- inspection ----------------------------------------------------------

(defn value
  "Get a config value by path: (config/value cfg :database :host)."
  [cfg & path]
  (get-in (cfg :values) path))

(defn describe-source
  "Human-readable origin of a provenance entry: \"env var VOID_DB__HOST\"."
  [source]
  (case (get source :layer)
    :defaults (if-let [p (get source :plugin)]
                (string/format "defaults of plugin %q" p)
                "defaults")
    :file (string/format "file %s" (source :path))
    :env (string/format "env var %s" (source :var))
    :cli (if-let [a (get source :arg)]
           (string/format "CLI override %s" a)
           "CLI override")
    (string/format "%q" source)))

(defn- child-entries [provenance path]
  (def plen (length path))
  (def out @{})
  (eachp [p hist] provenance
    (when (and (> (length p) plen)
               (= path (slice p 0 plen)))
      (put out p (last hist))))
  out)

(defn explain
  ``Where did a config value come from?

      (config/explain cfg :database :host)
      # {:path [:database :host] :value "10.0.0.5"
      #  :source {:layer :env :var "VOID_DATABASE__HOST"}
      #  :history [<defaults> <file> <env>]}

  :history lists every layer that set the value, oldest first;
  :source is the winning (last) one. For a path that is a subtree the
  result carries :children — leaf path -> winning source.``
  [cfg & path]
  (def p (tuple ;path))
  (def hist (get-in cfg [:provenance p]))
  (def v (get-in (cfg :values) p))
  (if hist
    {:path p
     :value v
     :source (last hist)
     :history (tuple ;hist)}
    {:path p
     :value v
     :children (child-entries (cfg :provenance) p)}))

(defn explain-str
  "One-line human answer: \"[:database :host] = \\\"10.0.0.5\\\" — from
  env var VOID_DATABASE__HOST (overrides file config/dev.janet)\"."
  [cfg & path]
  (def e (explain cfg ;path))
  (cond
    (get e :source)
    (do
      (def shadowed (reverse (slice (e :history) 0 -2)))
      (string/format "%s = %q — from %s%s"
                     (path-str (e :path))
                     (e :value)
                     (describe-source (e :source))
                     (if (empty? shadowed)
                       ""
                       (string " (overrides: "
                               (string/join (map describe-source shadowed) ", ")
                               ")"))))

    (and (get e :children) (not (empty? (e :children))))
    (string/join
      (map (fn [p] (string/format "%s — from %s"
                                  (path-str p)
                                  (describe-source (get-in e [:children p]))))
           (sorted (keys (e :children))))
      "\n")

    (string/format "%s is not set" (path-str (e :path)))))

# -- batch validation ----------------------------------------------------

(defn validate
  ``Validate config slices against per-plugin specs — all of them, not
  first-fail (ADR-0007). specs is indexed of
  {:key <config-key> :schema <callable> :plugin <kw, optional>};
  a schema fails by returning false or throwing. Returns an array of
  error strings, empty when everything is valid.``
  [cfg specs]
  (def errors @[])
  (each spec specs
    (when-let [schema (get spec :schema)]
      (def k (spec :key))
      (def who (if-let [p (get spec :plugin)]
                 (string/format " (plugin %q)" p)
                 ""))
      (def [ok res] (protect (schema (get (cfg :values) k))))
      (cond
        (not ok)
        (array/push errors (string/format "config %q%s: %s" k who (describe res)))
        (= res false)
        (array/push errors (string/format "config %q%s: schema validation failed" k who)))))
  errors)

(defn validate!
  "Like `validate`, but throws a single error listing every failure.
  Returns the config on success."
  [cfg specs]
  (def errors (validate cfg specs))
  (unless (empty? errors)
    (errorf "config validation failed:\n  - %s" (string/join errors "\n  - ")))
  cfg)
