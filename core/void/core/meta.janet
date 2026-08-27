### void/core/meta — metadata merge semantics (SPEC.md part II §2, ADR-0005).
###
### Route/handler metadata is an open map of namespaced keys — the main
### integration contract between plugins: authz, validation, OpenAPI,
### rate limits, txn, cache all attach to an endpoint without knowing
### about each other. The contract lives in core because non-HTTP
### protocols (Connect-RPC methods, Kafka handlers) carry the same
### metadata; void/http is just one consumer. Every key is declared
### once (schema + merge strategy); `merge-layers` folds the layers
### (global -> group -> route), validating keys (typos get
### did-you-mean, values get schema errors with paths) and recording
### the provenance of every value for explain-route-style tooling.
### Strategies: :replace (specific layer wins), :concat (lists are
### concatenated), :deep-merge (maps merge recursively), :restrict (a
### more specific layer may only tighten — the guarantee for security
### keys; loosening is an error).

(import ./schema :as schema)

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

# -- key declarations ----------------------------------------------------

(def- allowed-decl-keys
  {:key true :schema true :doc true :merge true :allow? true})

(def- strategies
  {:replace true :concat true :deep-merge true :restrict true})

(defn namespaced?
  "True when a metadata key is namespaced: :void.http/timeout, :app/x.
  Every key except :name must be (SPEC part II §2.3)."
  [k]
  (and (keyword? k) (not (nil? (string/find "/" (string k))))))

(defn declare-key
  ``Declare a metadata key (the substrate for the
  :void.http/route-meta-key extension point):

      (meta/declare-key :void.authz/policy
        :schema [:or :keyword [:vector :keyword]]
        :doc "Policy (or all-of vector) enforced before the handler"
        :merge :replace)

  Options:
    :schema  value schema, checked per layer at table-build time
    :merge   :replace (default) | :concat | :deep-merge | :restrict
    :allow?  required for :restrict — (fn [outer inner] bool), true
             when the more specific inner value only tightens outer
    :doc     docstring — metadata docs are generated from declarations``
  [key & kvs]
  (unless (namespaced? key)
    (errorf "metadata key %q must be namespaced (:void.http/timeout, :app/flag)" key))
  (when (odd? (length kvs))
    (errorf "metadata key %q: expected key-value option pairs" key))
  (def opts (table ;kvs))
  (eachk k opts
    (unless (in allowed-decl-keys k)
      (errorf "metadata key %q: unknown option %q (allowed: %s)"
              key k (names-str (keys allowed-decl-keys)))))
  (def strat (get opts :merge :replace))
  (unless (in strategies strat)
    (errorf "metadata key %q: :merge must be one of :replace :concat :deep-merge :restrict, got %q"
            key strat))
  (when (= strat :restrict)
    (unless (callable? (get opts :allow?))
      (errorf "metadata key %q: :merge :restrict requires an :allow? function (fn [outer inner] bool)"
              key)))
  (when-let [d (get opts :doc)]
    (unless (string? d)
      (errorf "metadata key %q: :doc must be a string, got %q" key d)))
  (when-let [s (get opts :schema)]
    (def [ok e] (protect (schema/normalize s)))
    (unless ok
      (errorf "metadata key %q: invalid :schema: %s" key (err-str e))))
  (freeze (merge-into @{} opts {:key key :merge strat})))

(defn declarations
  "Build a key -> declaration table from an indexed of declarations
  (see `declare-key`) or a dictionary key -> declaration/options.
  A key declared twice is an error (the conflict surfaces at start)."
  [decls]
  (def out @{})
  (defn add [d]
    (when (in out (d :key))
      (errorf "metadata key %q is declared twice" (d :key)))
    (put out (d :key) d))
  (cond
    (indexed? decls)
    (each d decls
      (unless (and (dictionary? d) (keyword? (get d :key)))
        (errorf "expected a declaration from declare-key, got %q" d))
      (add d))

    (dictionary? decls)
    (each k (sorted (keys decls))
      (def v (decls k))
      (unless (dictionary? v)
        (errorf "declaration for %q must be a dictionary, got %q" k v))
      (add (if (get v :key)
             (do (unless (= (v :key) k)
                   (errorf "declaration %q is stored under key %q" (v :key) k))
                 v)
             (declare-key k ;(mapcat identity (pairs v))))))

    (errorf "declarations must be indexed or a dictionary, got %q" decls))
  out)

# -- merge ---------------------------------------------------------------

(defn- deep-merge* [old new]
  (if (and (dictionary? old) (dictionary? new))
    (do
      (def out (merge-into @{} old))
      (eachp [k v] new
        (put out k (deep-merge* (get out k) v)))
      out)
    new))

(defn- merge-key [decl key outer inner source errors]
  (case (decl :merge)
    :replace inner

    :concat
    (cond
      # {slot [items]} concats per slot — lifecycle hooks (ADR-0016):
      # {:pre-handler [group-hook]} + {:pre-handler [route-hook]}
      # -> {:pre-handler [group-hook route-hook]}
      (dictionary? inner)
      (if (and (not (nil? outer)) (not (dictionary? outer)))
        (do (array/push errors
                        (string/format "metadata key %q (layer %q): :concat cannot mix %q with dictionary %q"
                                       key source outer inner))
            outer)
        (do
          (def out (merge-into @{} (or outer {})))
          (eachp [k v] inner
            (if (indexed? v)
              (put out k (tuple ;(get out k []) ;v))
              (array/push errors
                          (string/format "metadata key %q (layer %q): :concat dictionary values must be indexed, got %q under %q"
                                         key source v k))))
          (freeze out)))
      (not (indexed? inner))
      (do (array/push errors
                      (string/format "metadata key %q (layer %q): :concat expects an indexed value, got %q"
                                     key source inner))
          outer)
      (nil? outer) (tuple ;inner)
      (and (not (nil? outer)) (not (indexed? outer)))
      (do (array/push errors
                      (string/format "metadata key %q (layer %q): :concat cannot mix dictionary %q with %q"
                                     key source outer inner))
          outer)
      (tuple ;outer ;inner))

    :deep-merge
    (if (nil? outer) inner (deep-merge* outer inner))

    :restrict
    (if (nil? outer)
      inner
      (do
        (def [ok allowed] (protect ((decl :allow?) outer inner)))
        (cond
          (not ok)
          (do (array/push errors
                          (string/format "metadata key %q (layer %q): :allow? failed: %s"
                                         key source (err-str allowed)))
              outer)
          allowed inner
          (do (array/push errors
                          (string/format "metadata key %q (layer %q): value %q may only tighten %q (:restrict)"
                                         key source inner outer))
              outer))))))

(defn- record! [provenance k source v]
  (def entry {:source source :value v})
  (if-let [hist (get provenance k)]
    (array/push hist entry)
    (put provenance k @[entry])))

(defn merge-layers
  ``Merge metadata layers, least specific first (global -> group ->
  route; SPEC part II §2.4). Each layer is a metadata dictionary or a
  [source dictionary] pair — the source labels provenance and error
  messages (defaults to the layer index).

  Every key except :name must be namespaced and declared; an unknown
  key is an error with did-you-mean, an invalid value is a schema
  error, a :restrict loosening is an error. Bare keys are warnings, or
  errors with {:strict true} (CI mode).

  Never throws on invalid metadata (see merge-layers!); returns
    @{:value      merged metadata table
      :provenance key -> [{:source :value} ...] (every layer that set it)
      :errors     (...)
      :warnings   (...)}``
  [decls layers &opt opts]
  (default opts {})
  (def dm (declarations decls))
  (def errors @[])
  (def warnings @[])
  (def value @{})
  (def provenance @{})
  (loop [i :range [0 (length layers)]]
    (def layer (layers i))
    (def [source m]
      (cond
        (dictionary? layer) [i layer]
        (and (indexed? layer) (= 2 (length layer)) (dictionary? (layer 1)))
        [(layer 0) (layer 1)]
        (do (array/push errors
                        (string/format "layer %d must be a dictionary or [source dictionary], got %q"
                                       i layer))
            [i {}])))
    (each k (sorted (keys m))
      (def v (m k))
      (cond
        (= k :name)
        (do (put value :name v)
            (record! provenance :name source v))

        (not (keyword? k))
        (array/push errors
                    (string/format "metadata key %q (layer %q) must be a keyword" k source))

        (not (namespaced? k))
        (do
          (def msg (string/format "metadata key %q (layer %q) is not namespaced — use :app/%s or a declared plugin key"
                                  k source (string k)))
          (if (get opts :strict)
            (array/push errors msg)
            (do (array/push warnings msg)
                (put value k v)
                (record! provenance k source v))))

        (nil? (get dm k))
        (array/push errors
                    (string/format "unknown metadata key %q (layer %q)%s"
                                   k source (suggest k (keys dm))))

        (do
          (def decl (dm k))
          (var ok true)
          (when-let [sch (decl :schema)]
            (def [chk res] (protect (schema/check sch v)))
            (if chk
              (each e (res :errors)
                (set ok false)
                (array/push errors
                            (string/format "metadata key %q (layer %q): %s"
                                           k source (schema/error-str e))))
              (do (set ok false)
                  (array/push errors
                              (string/format "metadata key %q (layer %q): %s"
                                             k source (err-str res))))))
          (when ok
            (put value k (merge-key decl k (get value k) v source errors))
            (record! provenance k source v))
          nil))))
  @{:value value
    :provenance provenance
    :errors (tuple ;errors)
    :warnings (tuple ;warnings)})

(defn merge-layers!
  "Like `merge-layers`, but throws one error listing every failure —
  the table-build fail-fast path. Returns the merged metadata table."
  [decls layers &opt opts]
  (def res (merge-layers decls layers opts))
  (unless (empty? (res :errors))
    (errorf "metadata errors:\n  - %s" (string/join (res :errors) "\n  - ")))
  (res :value))

# -- inspection ----------------------------------------------------------

(defn explain
  "Provenance of one key after `merge-layers`: {:key :value :history
  [{:source :value} ...]} — the substrate for explain-route."
  [result key]
  {:key key
   :value (get-in result [:value key])
   :history (tuple ;(get-in result [:provenance key] []))})

(defn explain-str
  "One-line human answer: \":void.http/timeout = 5 — from layer :route
  (layers also contributing: :global)\"."
  [result key]
  (def e (explain result key))
  (if (empty? (e :history))
    (string/format "%q is not set" key)
    (do
      (def shadowed (reverse (slice (e :history) 0 -2)))
      (string/format "%q = %q — from layer %q%s"
                     key (e :value)
                     (get (last (e :history)) :source)
                     (if (empty? shadowed)
                       ""
                       (string " (layers also contributing: "
                               (string/join (map |(string/format "%q" ($ :source)) shadowed) ", ")
                               ")"))))))
