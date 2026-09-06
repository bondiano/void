### void/core/extension — extension points: the contract, the
### collector and the resolution.
###
### Owns everything that is about a *point* rather than about a plugin
### or a boot: the shape of a point contract (`extension-point`), the
### module-level queue that `contribute!` / `defextension-point` fill
### before `defplugin` folds it into a manifest, the points void/core
### itself declares (`core-points`), and phase 4 of bootstrap — every
### active plugin's contributions validated against the owning point's
### schema, checked for cardinality, cross-checked and folded with
### :reduce (`resolve`). The seam is here because a point's semantics
### (what a contribution must look like, how many, how they fold) are
### decided by the point's author and read by the host, and neither
### side should have to know how a manifest is parsed or how a boot
### is sequenced to reason about them. `resolve-point` is the unit
### the resolution is made of and the place a point's default
### validate/reduce is chosen (`point-validator`, `point-reducer`):
### a future `:key`/`:index` option on `extension-point` lands there.

(import ./schema :as schema)
(import ./util :as util)

# -- the contract ----------------------------------------------------------

(def- allowed-point-keys
  {:name true :doc true :schema true :cardinality true
   :reduce true :validate true :aliases true :conformance true})

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
    :conformance  the module of the point's conformance suite
                  ("void/bus/conformance/backend"), when the point is a
                  contract several implementations answer to: a
                  contract counts as frozen only with a suite every
                  implementation runs (docs/CONTRACTS.md names the
                  points that have none)
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
              name k (util/names-str (keys allowed-point-keys)))))
  (def card (get opts :cardinality :many))
  (unless (in cardinalities card)
    (errorf "extension point %q: :cardinality must be :many, :single or :single-required, got %q"
            name card))
  (each fk [:reduce :validate]
    (when-let [f (get opts fk)]
      (unless (util/callable? f)
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
  (when-let [c (get opts :conformance)]
    (unless (string? c)
      (errorf "extension point %q: :conformance must be a module name, got %q" name c)))
  (def sch
    (when-let [s (get opts :schema)]
      (def [ok n] (protect (schema/normalize s)))
      (unless ok
        (errorf "extension point %q: invalid :schema: %s" name (util/err-str n)))
      n))
  # :schema-source keeps the author's shorthand — the contract docs
  # (scripts/gen-contracts.janet) render it, :schema is the normalized
  # validator input
  (freeze (merge-into @{} opts {:name name :cardinality card :schema sch
                                :aliases (tuple ;aliases)
                                :schema-source (get opts :schema)})))

(defn point?
  "Is `x` a point contract — what `extension-point` builds: a
  dictionary with a keyword :name and a known :cardinality. The
  manifest uses it to tell a built point from an options dictionary
  in :extension-points."
  [x]
  (and (dictionary? x)
       (keyword? (get x :name))
       (in cardinalities (get x :cardinality))))

# -- module-level collector (contribute! / defextension-point) -----------

(def- collected
  "The queue a module fills between its first `contribute!` and its
  `defplugin`: points and contributions keyed by point name. Owned
  here so that only `drain-collected!` empties it."
  @{:points @{} :contributes @{}})

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

(defn drain-collected!
  "Take everything queued by `contribute!` / `defextension-point` since
  the last drain — `{:points {name point} :contributes {name [value
  ...]}}`, frozen — and empty the queue. `defplugin` is the one
  caller: the queue belongs to the manifest defined next."
  []
  (def out (freeze {:points (collected :points)
                    :contributes (collected :contributes)}))
  (table/clear (collected :points))
  (table/clear (collected :contributes))
  out)

# -- core extension points -----------------------------------------------

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
       :validate (util/unique-by "CLI command" |($ :name))
       :reduce |(sorted-by |($ :name) $))

     :void.core/health
     (extension-point :void.core/health
       :doc "Health checks beyond the per-component ones: {:name :fn}"
       :schema {:name :keyword :fn :function}
       :validate (util/unique-by "health check" |($ :name))
       :reduce |(sorted-by |($ :name) $))

     :void.core/store
     (extension-point :void.core/store
       :doc "Stores a second replica would have to see: {:name :void.http/session :what \"sessions\" :needs [component-keys] :ask (fn [boot] {:store :memory :shared? false|true|:by-design :why ... :replacement ...} | nil)}; asked once everything is up, and under [:deploy :shape] :fleet a per-process answer stops the boot. :needs are the components that have to be running for :ask to answer — the same convention as :void.core/cli, and what lets `void deploy check` survey a composition without opening a port"
       :schema {:name :keyword
                :what :string
                :ask :function
                :needs [:optional [:vector :keyword]]
                :doc [:optional :string]}
       :validate (util/unique-by "store declaration" |($ :name))
       :reduce |(sorted-by |($ :name) $))

     :void.core/log-sink
     (extension-point :void.core/log-sink
       :doc "Log record sinks: {:name :fn (fn [record])}; installed by plugin/start! next to the configured built-in sink"
       :schema {:name :keyword :fn :function :doc [:optional :string]}
       :validate (util/unique-by "log sink" |($ :name))
       :reduce |(sorted-by |($ :name) $))

     :void.core/log-serializer
     (extension-point :void.core/log-serializer
       :doc "Log value serializers by record key: {:key :err :fn (fn [value] shaped)}; the core ships the :err serializer"
       :schema {:key :keyword :fn :function :doc [:optional :string]}
       :validate (util/unique-by "log serializer for" |($ :key))
       :reduce (fn [contribs] (tabseq [c :in contribs] (c :key) (c :fn))))

     :void.core/config-source
     (extension-point :void.core/config-source
       :doc "Extra config sources (vault, consul): {:name :fn :priority}; consumed on config (re)load"
       :schema {:name :keyword :fn :function :priority [:optional :int]}
       :validate (util/unique-by "config source" |($ :name))
       :reduce |(sorted-by (fn [c] [(get c :priority 100) (c :name)]) $))

     :void.core/schema-type
     (extension-point :void.core/schema-type
       :doc "Custom schema types: {:name :money :spec <register-type! spec>}; registered during resolution"
       :schema {:name :keyword :spec :dictionary}
       :validate (util/unique-by "schema type" |($ :name))
       :reduce (fn [contribs]
                 (each c contribs
                   (schema/register-type! (c :name) (c :spec)))
                 (tuple ;(map |($ :name) contribs))))

     :void.core/schema-projection
     (extension-point :void.core/schema-projection
       :doc "Schema projections (openapi, proto, forms): {:name :fn}; registered during resolution"
       :schema {:name :keyword :fn :function}
       :validate (util/unique-by "schema projection" |($ :name))
       :reduce (fn [contribs]
                 (each c contribs
                   (schema/register-projection! (c :name) (c :fn)))
                 (tuple ;(map |($ :name) contribs))))

     :void.core/interface
     (extension-point :void.core/interface
       :doc "Interface declarations for component :provides: {:name :void/cache :doc ... :methods {...} :conformance \"void/cache/conformance/store\"} — :conformance names the module of the interface's conformance suite, the one every implementation runs"
       :schema {:name :keyword
                :doc [:optional :string]
                :methods [:optional :dictionary]
                :conformance [:optional :string]}
       :validate (util/unique-by "interface" |($ :name))
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

# -- resolution (bootstrap phase 4) ---------------------------------------

(defn- declared-points
  "The points a boot resolves against, name -> {:owner :point}: the
  core's own first, then every active plugin's in name order. A name
  declared twice is an error naming both owners; the first declaration
  keeps the name."
  [active-sorted errors]
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
  points)

(defn- inactive-owners
  "Point name -> the loaded-but-inactive plugin declaring it: so a
  contribution to a point whose owner was switched off by its :when
  is reported as that, not as a typo."
  [all points]
  (def owners @{})
  (each m all
    (eachk name (m :extension-points)
      (unless (in points name)
        (put owners name (m :name)))))
  owners)

(defn- alias-map
  "Deprecated name -> canonical point, from every declared point's
  :aliases. An alias that is itself a declared point, or claimed by
  two points, is an error."
  [points errors]
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
  aliases)

(defn- gather-contributions
  "Canonical point name -> [{:plugin :value} ...] over the active
  plugins in name order. A contribution addressed to an alias folds
  into the canonical point with a deprecation warning on stderr; one
  addressed to an inactive owner's point or to no point at all is an
  error (the latter with a did-you-mean)."
  [active-sorted points aliases inactive errors]
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

        (in inactive pname)
        (array/push errors
                    (string/format "plugin %q contributes to %q, but its owner plugin %q is inactive"
                                   (m :name) pname (inactive pname)))

        (array/push errors
                    (string/format "plugin %q contributes to unknown extension point %q%s"
                                   (m :name) pname
                                   (util/suggest pname (array/concat (array ;(keys points))
                                                                ;(keys aliases))))))))
  contribs)

(defn- schema-errors
  "Every contribution to `name` checked against the point's :schema
  (none: no errors), each failure attributed to its plugin."
  [name point cs]
  (def errors @[])
  (when-let [sch (point :schema)]
    (each c cs
      (def [ok res] (protect (schema/check sch (c :value))))
      (if ok
        (each e (res :errors)
          (array/push errors
                      (string/format "plugin %q: contribution to %q: %s"
                                     (c :plugin) name (schema/error-str e))))
        (array/push errors
                    (string/format "plugin %q: contribution to %q: %s"
                                   (c :plugin) name (util/err-str res))))))
  errors)

(defn- cardinality-error
  "The one message a :single / :single-required point produces when
  the count of contributions is wrong, naming the contributors; nil
  otherwise (and always nil for :many)."
  [name point cs]
  (defn from-str []
    (string/join (map |(string/format "%q" ($ :plugin)) cs) ", "))
  (case (point :cardinality)
    :single
    (when (> (length cs) 1)
      (string/format "extension point %q has cardinality :single but received %d contributions (from: %s)"
                     name (length cs) (from-str)))
    :single-required
    (unless (= 1 (length cs))
      (string/format "extension point %q requires exactly one contribution, got %d%s"
                     name (length cs)
                     (if (empty? cs) "" (string " (from: " (from-str) ")"))))))

(defn- point-validator
  "The cross-check a point runs over its contribution values before
  folding: its :validate, or nil for none. The place a default check
  derived from the contract (a `:key` option: no two contributions
  with the same key) would be chosen."
  [point]
  (point :validate))

(defn- point-reducer
  "The fold a point applies to its contribution values: its :reduce,
  else the tuple of values for :many and the single value otherwise.
  The place a default fold derived from the contract (`:key`: sorted
  by it; `:index`: a table keyed by it) would be chosen."
  [point]
  (or (point :reduce)
      (if (= :many (point :cardinality)) identity first)))

(defn resolve-point
  ``Resolve one point from its contributions `cs` (`[{:plugin :value}
  ...]`): schema-check every value, enforce :cardinality, then — only
  when all of that held — run the point's cross-check and fold with
  its reducer. Returns `[resolved errors]`: `resolved` is nil whenever
  `errors` is not empty, and every message names the point and, for
  a bad contribution, the plugin it came from.``
  [name point cs]
  (def errors (schema-errors name point cs))
  (when-let [e (cardinality-error name point cs)]
    (array/push errors e))
  (def values (tuple ;(map |($ :value) cs)))
  (var resolved nil)
  (when (empty? errors)
    (when-let [v (point-validator point)]
      (def [ok e] (protect (v values)))
      (unless ok
        (array/push errors
                    (string/format "extension point %q: %s" name (util/err-str e)))))
    (when (empty? errors)
      (def [ok v] (protect ((point-reducer point) values)))
      (if ok
        (set resolved v)
        (array/push errors
                    (string/format "extension point %q: :reduce failed: %s" name (util/err-str v))))))
  [resolved errors])

(defn resolve
  ``Phase 4 (extension resolution): collect points of active plugins +
  core points, validate every contribution against the point schema,
  enforce cardinality, run cross-checks and fold with :reduce. `all`
  is every loaded manifest, active or not, so a contribution to a
  deactivated owner's point is reported as that. Errors accumulate in
  `errors`; the result is name -> `@{:owner :point :contributions
  :resolved}` — the boot's :extensions.``
  [active all errors]
  (def active-sorted (sorted-by |($ :name) active))
  (def points (declared-points active-sorted errors))
  (def inactive (inactive-owners all points))
  # deprecation aliases: a renamed point keeps its old name as an :aliases
  # entry; contributions addressed to the old name fold into the new point
  # with a warning
  (def aliases (alias-map points errors))
  (def contribs (gather-contributions active-sorted points aliases inactive errors))
  (def out @{})
  (each name (sorted (keys points))
    (def {:owner owner :point point} (points name))
    (def cs (get contribs name @[]))
    (def [resolved point-errors] (resolve-point name point cs))
    (array/concat errors point-errors)
    (put out name @{:owner owner
                    :point point
                    :contributions (tuple ;cs)
                    :resolved resolved}))
  out)
