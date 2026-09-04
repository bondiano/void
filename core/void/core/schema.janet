### void/core/schema — schema layer.
###
### One declaration, many projections. A schema is plain data:
###
###   {:email [:string {:format :email}]
###    :age   [:int {:min 18}]
###    :role  [:enum :admin :user]
###    :tags  [:vector :keyword {:max 10}]}
###
### Forms: a keyword is a type (or a reference to a registered schema),
### a dictionary is a map schema, a tuple is [head props-or-children...]
### with heads :enum :union :and :optional :vector :map :map-of :ref
### :pred :peg :literal; any other value matches literally. Composition:
### `merge`, `select`, `optional`, `union`; recursion via [:ref :name].
### Validation collects every error with its path ([:tags 3]); messages
### are localizable through (dyn :void.schema/messages). Coercion mode
### turns strings into ints/keywords/booleans for query params and
### forms. Custom types (`register-type!`) and projections
### (`register-projection!`) are the substrate for the plugin extension
### points :void.core/schema-type and :void.core/schema-projection; the
### first projection is :validator. Optional :db/* props are parsed and
### stored but never consulted by validation (`db-annotations`).

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(defn- path-str [path]
  (string/format "[%s]"
                 (string/join (map |(string/format "%q" $) path) " ")))

(defn- integer? [v]
  (and (number? v)
       (not= v math/inf)
       (not= v (- math/inf))
       (= v (math/trunc v))))

(defn- names-str [names]
  (string/join (map |(string/format "%q" $) (sorted names)) " "))

# -- registries ----------------------------------------------------------

(def- type-registry @{})
(def- format-registry @{})
(def- schema-registry @{})
(def- projection-registry @{})

(def- combinator-heads
  {:enum true :union true :or true :and true :optional true :vector true
   :map true :map-of true :ref true :pred true :peg true :literal true})

(defn types
  "Names of all registered schema types."
  []
  (sorted (keys type-registry)))

(defn register-type!
  ``Register a custom schema type such as :money or :uuid — the substrate
  for the :void.core/schema-type extension point. spec keys:

    :validate  (fn [value props] bool) — required
    :coerce    (fn [value props] coerced-or-nil) — used in coercion
               mode when :validate fails; nil means "cannot coerce"
    :kind      :number | :bytes | :sized | :other (default) — opts the
               type into the generic prop checks (:min/:max, :pattern,
               :format)
    :message   error text override — string or (fn [err] string)

  Types must be registered before schemas that mention them are
  normalized; an unknown keyword in a schema is treated as a reference
  to a registered schema instead.``
  [name spec]
  (unless (keyword? name)
    (errorf "schema type name must be a keyword, got %q" name))
  (when (in combinator-heads name)
    (errorf "schema type %q collides with a built-in combinator" name))
  (def pred (get spec :validate))
  (unless (callable? pred)
    (errorf "schema type %q: :validate must be a function, got %q" name pred))
  (put type-registry name
       {:pred pred
        :coerce (get spec :coerce)
        :kind (get spec :kind :other)
        :message (get spec :message)})
  name)

(defn register-format!
  "Register a named string format (used as [:string {:format :email}]).
  The PEG pattern is anchored: it must match the whole string."
  [name pattern]
  (unless (keyword? name)
    (errorf "format name must be a keyword, got %q" name))
  (put format-registry name (peg/compile ~(* ,pattern -1)))
  name)

# -- built-in types and formats ------------------------------------------

(defn- coerce-scan [check]
  (fn [v _] (when (string? v)
              (when-let [n (scan-number v)]
                (when (check n) n)))))

(each [name spec]
  [[:any {:validate (fn [_ _] true)}]
   [:nil {:validate (fn [v _] (nil? v))}]
   [:boolean {:validate (fn [v _] (boolean? v))
              :coerce (fn [v _] (case v "true" true "false" false))}]
   [:int {:validate (fn [v _] (integer? v)) :kind :number
          :coerce (coerce-scan integer?)}]
   [:number {:validate (fn [v _] (number? v)) :kind :number
             :coerce (coerce-scan number?)}]
   [:string {:validate (fn [v _] (string? v)) :kind :bytes}]
   [:buffer {:validate (fn [v _] (buffer? v)) :kind :bytes}]
   [:bytes {:validate (fn [v _] (bytes? v)) :kind :bytes}]
   [:keyword {:validate (fn [v _] (keyword? v))
              :coerce (fn [v _] (when (and (string? v) (not (empty? v)))
                                  (keyword v)))}]
   [:symbol {:validate (fn [v _] (symbol? v))}]
   [:tuple {:validate (fn [v _] (tuple? v)) :kind :sized}]
   [:array {:validate (fn [v _] (array? v)) :kind :sized}]
   [:indexed {:validate (fn [v _] (indexed? v)) :kind :sized}]
   [:table {:validate (fn [v _] (table? v)) :kind :sized}]
   [:struct {:validate (fn [v _] (struct? v)) :kind :sized}]
   [:dictionary {:validate (fn [v _] (dictionary? v)) :kind :sized}]
   [:function {:validate (fn [v _] (callable? v))}]]
  (register-type! name spec))

(def- alnum '(range "az" "AZ" "09"))

(each [name pattern]
  [[:email ~(* (some (+ ,alnum (set "._%+-")))
               "@"
               (some (+ ,alnum "-"))
               (some (* "." (some (+ ,alnum "-")))))]
   [:uuid (do (def hex '(range "09" "af" "AF"))
              ~(* (repeat 8 ,hex) "-" (repeat 4 ,hex) "-" (repeat 4 ,hex)
                  "-" (repeat 4 ,hex) "-" (repeat 12 ,hex)))]
   [:date ~(* (repeat 4 (range "09")) "-"
              (repeat 2 (range "09")) "-"
              (repeat 2 (range "09")))]
   [:uri ~(* (some (range "az" "AZ")) ":" (some 1))]]
  (register-format! name pattern))

# -- normalization -------------------------------------------------------

(def- node-proto {:void.schema/node true})

(defn node?
  "True when x is a normalized schema node — a struct with keys
  :type, :props and :children."
  [x]
  (and (struct? x) (= node-proto (struct/getproto x))))

(defn- node [type props children]
  (struct/with-proto node-proto
                     :type type
                     :props (freeze (or props {}))
                     :children (tuple ;(or children []))))

(var- normalize* nil)

(defn- check-bound [props head k]
  (when-let [v (get props k)]
    (unless (number? v)
      (errorf "schema %q: %q must be a number, got %q" head k v))))

(defn- type-node [head props-form]
  (def tdef (in type-registry head))
  (def props (or props-form {}))
  (unless (dictionary? props)
    (errorf "schema %q: props must be a dictionary, got %q" head props-form))
  (def out (merge-into @{} props))
  (check-bound out head :min)
  (check-bound out head :max)
  (when-let [pat (get out :pattern)]
    (unless (= :bytes (tdef :kind))
      (errorf "schema %q: :pattern only applies to string-like types" head))
    (def [ok p] (protect (peg/compile ~(* ,pat -1))))
    (unless ok
      (errorf "schema %q: cannot compile :pattern %q: %s" head pat (describe p)))
    (put out :pattern-peg p))
  (when-let [f (get out :format)]
    (unless (= :bytes (tdef :kind))
      (errorf "schema %q: :format only applies to string-like types" head))
    (unless (in format-registry f)
      (errorf "unknown string format %q (known: %s)" f (names-str (keys format-registry)))))
  (node head out []))

(defn- map-node [props-form entries-form]
  (unless (dictionary? props-form)
    (errorf "schema :map: props must be a dictionary, got %q" props-form))
  (unless (dictionary? entries-form)
    (errorf "schema :map: entries must be a dictionary, got %q" entries-form))
  (node :map props-form
        (seq [k :in (sorted (keys entries-form))]
          [k (normalize* (entries-form k))])))

(defn- props-form [form idx head]
  (def props (or (get form idx) {}))
  (unless (dictionary? props)
    (errorf "schema %q: props must be a dictionary, got %q" head props))
  props)

(defn- normalize-tuple [form]
  (def head (let [h (first form)] (if (= h :or) :union h)))
  (unless (keyword? head)
    (errorf "schema tuple must start with a keyword, got %q" form))
  (def n (length form))
  (defn arity [ok what]
    (unless ok (errorf "schema %q: expected %s, got %q" head what form)))
  (case head
    :enum
    (do (arity (> n 1) "at least one member")
        (node :enum {:values (tuple ;(slice form 1))} []))

    :union
    (do (arity (> n 1) "at least one branch")
        (node :union {} (map normalize* (slice form 1))))

    :and
    (do (arity (> n 1) "at least one schema")
        (node :and {} (map normalize* (slice form 1))))

    :optional
    (do (arity (= n 2) "exactly one schema")
        (node :optional {} [(normalize* (form 1))]))

    :vector
    (do (arity (<= 2 n 3) "[:vector item props?]")
        (def props (props-form form 2 head))
        (check-bound props head :min)
        (check-bound props head :max)
        (node :vector props [(normalize* (form 1))]))

    :map-of
    (do (arity (<= 3 n 4) "[:map-of key-schema value-schema props?]")
        (node :map-of (props-form form 3 head)
              [(normalize* (form 1)) (normalize* (form 2))]))

    :map
    (do (arity (<= 2 n 3) "[:map props? entries]")
        (if (= n 3)
          (map-node (form 1) (form 2))
          (map-node {} (form 1))))

    :ref
    (do (arity (and (= n 2) (keyword? (form 1))) "[:ref :name]")
        (node :ref {:name (form 1)} []))

    :pred
    (do (arity (and (<= 2 n 3) (callable? (form 1))) "[:pred fn message?]")
        (node :pred {:fn (form 1) :message (get form 2)} []))

    :peg
    (do (arity (= n 2) "[:peg pattern]")
        (def [ok p] (protect (peg/compile ~(* ,(form 1) -1))))
        (unless ok
          (errorf "schema :peg: cannot compile %q: %s" (form 1) (describe p)))
        (node :peg {:source (form 1) :peg p} []))

    :literal
    (do (arity (= n 2) "[:literal value]")
        (node :literal {:value (form 1)} []))

    (if (in type-registry head)
      (do (arity (<= n 2) "[type props?]")
          (type-node head (get form 1)))
      (errorf "unknown schema head %q (types: %s)"
              head (names-str (keys type-registry))))))

(defn normalize
  ``Normalize any schema form into a node struct {:type :props
  :children}. Idempotent; every public function accepts sugar and
  normalizes, but `defschema`/`register!` do it once up front.``
  [form]
  (cond
    (node? form) form
    (keyword? form) (if (in type-registry form)
                      (node form {} [])
                      (node :ref {:name form} []))
    (indexed? form) (normalize-tuple form)
    (dictionary? form) (map-node {} form)
    (node :literal {:value form} [])))

(set normalize* normalize)

# -- registry ------------------------------------------------------------

(defn register!
  "Normalize and register a schema under a name (OpenAPI $ref, reuse,
  recursion via [:ref name]). Re-registering replaces — REPL-friendly.
  Returns the normalized schema."
  [name sch]
  (unless (keyword? name)
    (errorf "schema name must be a keyword, got %q" name))
  (def n (normalize sch))
  (put schema-registry name n)
  n)

(defn lookup
  "Fetch a registered schema by name, or nil."
  [name]
  (get schema-registry name))

(defn registered
  "Names of all registered schemas."
  []
  (sorted (keys schema-registry)))

(defmacro defschema
  ``Define `name` as a normalized schema and register it under
  (keyword name):

      (defschema CreateUser
        "optional docstring"
        {:email [:string {:format :email}]
         :age   [:int {:min 18}]})

  Registration makes the schema addressable as :CreateUser — from
  [:ref :CreateUser] (also recursively, from inside itself) and from
  projections such as OpenAPI $ref.``
  [name & forms]
  (def doc (when (and (>= (length forms) 2) (string? (first forms)))
             (first forms)))
  (def body (if doc (drop 1 forms) forms))
  (unless (= 1 (length body))
    (errorf "defschema %s: expected exactly one schema form" name))
  (if doc
    ~(def ,name ,doc (,register! ,(keyword name) ,(first body)))
    ~(def ,name (,register! ,(keyword name) ,(first body)))))

(defn- resolve-ref [name opts]
  (def sch (or (when-let [reg (get opts :registry)] (get reg name))
               (get schema-registry name)))
  (unless sch
    (errorf "schema %q is not registered (schemas: %s; types: %s)"
            name (names-str (keys schema-registry)) (names-str (keys type-registry))))
  (normalize sch))

# -- errors and messages -------------------------------------------------

(def default-messages
  "Default error text per error code: code -> (fn [err] string). A
  localization layer (void/i18n) replaces these wholesale or per-code
  via (setdyn :void.schema/messages table); every error carries enough
  data (:path :code :value + code-specific keys) to re-render."
  {:type (fn [e] (string/format "expected %q, got %q" (e :expected) (e :value)))
   :literal (fn [e] (string/format "expected exactly %q, got %q" (e :expected) (e :value)))
   :enum (fn [e] (string/format "expected one of %s, got %q"
                                (names-str (e :values)) (e :value)))
   :union (fn [e] (string/format "no union branch matched %q" (e :value)))
   :missing (fn [_] "required key is missing")
   :unknown (fn [_] "unknown key in a closed map")
   :key (fn [e] (string/format "invalid key %q" (e :value)))
   :min (fn [e] (string/format "expected at least %q, got %q" (e :min) (e :value)))
   :max (fn [e] (string/format "expected at most %q, got %q" (e :max) (e :value)))
   :min-length (fn [e] (string/format "expected length >= %q, got %q" (e :min) (e :length)))
   :max-length (fn [e] (string/format "expected length <= %q, got %q" (e :max) (e :length)))
   :pattern (fn [e] (string/format "%q does not match pattern %q" (e :value) (e :pattern)))
   :format (fn [e] (string/format "%q is not a valid %q" (e :value) (e :format)))
   :pred (fn [e] (string/format "predicate failed for %q" (e :value)))
   :peg (fn [e] (string/format "%q does not match peg %q" (e :value) (e :source)))})

(defn- err! [errors path code & kvs]
  (array/push errors (struct :path (tuple ;path) :code code ;kvs)))

(defn error-str
  ``Render one validation error: "[:tags 3]: expected :keyword, got 42".
  A :message on the error (custom type / [:pred fn msg]) wins; otherwise
  the code is looked up in (dyn :void.schema/messages), falling back to
  `default-messages`.``
  [err]
  (def m (get err :message))
  (def msg
    (cond
      (callable? m) (m err)
      m m
      (let [f (or (get (dyn :void.schema/messages {}) (err :code))
                  (get default-messages (err :code)))]
        (if f (f err) (string/format "invalid value %q" (err :value))))))
  (if (empty? (err :path))
    msg
    (string (path-str (err :path)) ": " msg)))

# -- validation ----------------------------------------------------------

(var- visit nil)

(defn- check-props [kind props v path errors]
  (defn bounds [len min-code max-code & extra]
    (when-let [m (props :min)]
      (when (< len m) (err! errors path min-code :min m ;extra :value v)))
    (when-let [m (props :max)]
      (when (> len m) (err! errors path max-code :max m ;extra :value v))))
  (case kind
    :number (bounds v :min :max)
    :bytes
    (do
      (bounds (length v) :min-length :max-length :length (length v))
      (when-let [p (props :pattern-peg)]
        (unless (peg/match p v)
          (err! errors path :pattern :pattern (props :pattern) :value v)))
      (when-let [f (props :format)]
        (unless (peg/match (in format-registry f) v)
          (err! errors path :format :format f :value v))))
    :sized (bounds (length v) :min-length :max-length :length (length v))
    nil))

(defn- visit-type-node [sch value path errors opts]
  (def name (sch :type))
  (def tdef (or (get type-registry name)
                (errorf "schema type %q is not registered" name)))
  (def props (sch :props))
  (var v value)
  (when (and (get opts :coerce)
             (tdef :coerce)
             (not ((tdef :pred) v props)))
    (def c ((tdef :coerce) v props))
    (unless (nil? c) (set v c)))
  (if ((tdef :pred) v props)
    (check-props (tdef :kind) props v path errors)
    (err! errors path :type :expected name :value v :message (tdef :message)))
  v)

(defn- visit-enum [sch value path errors opts]
  (def values ((sch :props) :values))
  (defn hit? [v] (not (nil? (index-of v values))))
  (var v value)
  (when (and (get opts :coerce) (string? v) (not (hit? v)))
    (when (hit? (keyword v)) (set v (keyword v)))
    (when-let [n (when (string? v) (scan-number v))]
      (when (hit? n) (set v n))))
  (unless (hit? v)
    (err! errors path :enum :values values :value v))
  v)

(defn- visit-union [sch value path errors opts]
  (def causes @[])
  (var matched nil)
  (each branch (sch :children)
    (when (nil? matched)
      (def sub @[])
      (def v (visit branch value path sub opts))
      (if (empty? sub)
        (set matched [v])
        (array/push causes (tuple ;sub)))))
  (if matched
    (matched 0)
    (do (err! errors path :union :value value :causes (tuple ;causes))
        value)))

(defn- visit-vector [sch value path errors opts]
  (if (not (indexed? value))
    (do (err! errors path :type :expected :vector :value value)
        value)
    (do
      (check-props :sized (sch :props) value path errors)
      (def item (first (sch :children)))
      (def coerce? (get opts :coerce))
      (def out (when coerce? @[]))
      (eachp [i v] value
        (def v2 (visit item v (tuple ;path i) errors opts))
        (when out (array/push out v2)))
      (if coerce?
        (if (tuple? value) (tuple ;out) out)
        value))))

(defn- visit-map [sch value path errors opts]
  (if (not (dictionary? value))
    (do (err! errors path :type :expected :map :value value)
        value)
    (do
      (def coerce? (get opts :coerce))
      (def out (when coerce? (merge-into @{} value)))
      (def known @{})
      (each [k sub] (sch :children)
        (put known k true)
        (def p (tuple ;path k))
        (def v (get value k))
        (if (nil? v)
          (unless (= :optional (sub :type))
            (err! errors p :missing))
          (do (def v2 (visit sub v p errors opts))
              (when out (put out k v2)))))
      (when (get (sch :props) :closed)
        (eachk k value
          (unless (in known k)
            (err! errors (tuple ;path k) :unknown :value (get value k)))))
      (if coerce?
        (if (struct? value) (freeze out) out)
        value))))

(defn- visit-map-of [sch value path errors opts]
  (if (not (dictionary? value))
    (do (err! errors path :type :expected :map :value value)
        value)
    (do
      (def [ks vs] (sch :children))
      (def coerce? (get opts :coerce))
      (def out (when coerce? @{}))
      (eachp [k v] value
        (def p (tuple ;path k))
        (def key-errors @[])
        (def k2 (visit ks k p key-errors opts))
        (unless (empty? key-errors)
          (err! errors p :key :value k))
        (def v2 (visit vs v p errors opts))
        (when out (put out k2 v2)))
      (if coerce?
        (if (struct? value) (freeze out) out)
        value))))

(defn- visit-pred [sch value path errors]
  (def [ok res] (protect (((sch :props) :fn) value)))
  (unless (and ok res)
    (err! errors path :pred :value value :message ((sch :props) :message)))
  value)

(defn- visit-peg [sch value path errors]
  (if (not (bytes? value))
    (err! errors path :type :expected :bytes :value value)
    (unless (peg/match ((sch :props) :peg) value)
      (err! errors path :peg :source ((sch :props) :source) :value value)))
  value)

(set visit
  (fn visit [sch value path errors opts]
    (case (sch :type)
      :literal (do (unless (deep= value ((sch :props) :value))
                     (err! errors path :literal
                           :expected ((sch :props) :value) :value value))
                   value)
      :enum (visit-enum sch value path errors opts)
      :union (visit-union sch value path errors opts)
      :and (do (var v value)
               (each c (sch :children)
                 (set v (visit c v path errors opts)))
               v)
      :optional (if (nil? value)
                  value
                  (visit (first (sch :children)) value path errors opts))
      :vector (visit-vector sch value path errors opts)
      :map (visit-map sch value path errors opts)
      :map-of (visit-map-of sch value path errors opts)
      :ref (visit (resolve-ref ((sch :props) :name) opts) value path errors opts)
      :pred (visit-pred sch value path errors)
      :peg (visit-peg sch value path errors)
      (visit-type-node sch value path errors opts))))

(def- allowed-check-opts {:coerce true :registry true})

(defn check
  ``Validate value against schema; collect every error, never throw on
  invalid data. Returns {:value v :errors [...]} where each error is
  {:path [:tags 3] :code :type ...} (render with `error-str`).

  Options:
    :coerce    true — coercion mode: "42"→42, "admin"→:admin,
               "true"→true, plus :coerce of custom types; :value is
               the coerced result
    :registry  extra name->schema table consulted by [:ref name]
               before the global registry``
  [sch value &opt opts]
  (default opts {})
  (eachk k opts
    (unless (in allowed-check-opts k)
      (errorf "schema/check: unknown option %q (allowed: %s)"
              k (names-str (keys allowed-check-opts)))))
  (def errors @[])
  (def v (visit (normalize sch) value [] errors opts))
  {:value v :errors (tuple ;errors)})

(defn valid?
  "True when value matches schema (no coercion)."
  [sch value]
  (empty? ((check sch value) :errors)))

(defn validate
  "Like `check`, but throws one error listing every failure; returns
  the (possibly coerced) value on success. Options as in `check`."
  [sch value &opt opts]
  (def res (check sch value opts))
  (unless (empty? (res :errors))
    (errorf "schema validation failed:\n  - %s"
            (string/join (map error-str (res :errors)) "\n  - ")))
  (res :value))

(defn coerce
  "Validate in coercion mode; returns the coerced value or throws the
  full error batch. Sugar for (validate sch value {:coerce true})."
  [sch value]
  (validate sch value {:coerce true}))

# -- composition ---------------------------------------------------------

(defn- as-map-node [sch who]
  (def n (normalize sch))
  (unless (= :map (n :type))
    (errorf "%s expects map schemas, got %q" who (n :type)))
  n)

(defn union
  "Schema matching any of the given schemas (first match wins, also
  for coercion)."
  [& schs]
  (when (empty? schs) (error "schema/union needs at least one schema"))
  (node :union {} (map normalize schs)))

(defn optional
  "Wrap a schema so the value may be nil — and, as a map entry, the
  key may be absent. Equivalent to [:optional sch]."
  [sch]
  (node :optional {} [(normalize sch)]))

(defn merge
  "Merge map schemas left to right: later entries and props win."
  [& schs]
  (when (empty? schs) (error "schema/merge needs at least one schema"))
  (def props @{})
  (def entries @{})
  (each sch schs
    (def n (as-map-node sch "schema/merge"))
    (eachp [k v] (n :props) (put props k v))
    (each [k sub] (n :children) (put entries k sub)))
  (node :map props (seq [k :in (sorted (keys entries))] [k (entries k)])))

(defn select
  "Project a map schema onto a subset of its keys — a DTO from an
  entity: (schema/select User [:email :brand-id])."
  [sch ks]
  (def n (as-map-node sch "schema/select"))
  (def entries @{})
  (each [k sub] (n :children) (put entries k sub))
  (node :map (n :props)
        (seq [k :in ks]
          (if-let [sub (get entries k)]
            [k sub]
            (errorf "schema/select: key %q not in schema (has: %s)"
                    k (names-str (keys entries)))))))

# -- projections ---------------------------------------------------------

(defn projections
  "Names of all registered projections."
  []
  (sorted (keys projection-registry)))

(defn register-projection!
  ``Register a projection — the substrate for the
  :void.core/schema-projection extension point (OpenAPI, protobuf,
  form hints, generators, docs...). f is (fn [normalized-schema & args])
  and must handle — or explicitly reject — every node type it may
  receive (contract discipline).``
  [name f]
  (unless (keyword? name)
    (errorf "projection name must be a keyword, got %q" name))
  (unless (callable? f)
    (errorf "projection %q must be a function, got %q" name f))
  (put projection-registry name f)
  name)

(defn project
  "Apply a registered projection to a schema:
  (schema/project :validator CreateUser {:coerce true})."
  [name sch & args]
  (def f (or (get projection-registry name)
             (errorf "unknown schema projection %q (known: %s)"
                     name (names-str (keys projection-registry)))))
  (f (normalize sch) ;args))

(register-projection! :validator
  (fn validator-projection [sch &opt opts]
    (fn [value] (validate sch value opts))))

# -- reading a schema back -----------------------------------------------
#
# Everything that projects a schema — a form, an admin resource, a
# protobuf message, a table — asks the same two questions: what is
# under the :optional / :ref wrappers of a field, and which props with
# a given prefix are hung on it. These are those questions, asked once.

(defn unwrap
  ``Strip the :optional and :ref wrappers off a normalized node ->
  [inner-node required?]: :optional makes the field not required, :ref
  is followed into the registered schema (an unregistered name is an
  error). With `keep-refs?` a :ref node is returned as it is, for a
  reader to which the *name* matters more than the shape behind it —
  void/proto, where a reference is a message type.``
  [node &opt keep-refs?]
  (case (node :type)
    :optional (let [[inner _] (unwrap (first (node :children)) keep-refs?)]
                [inner false])
    :ref (if keep-refs?
           [node true]
           (let [name (get-in node [:props :name])]
             (unwrap (or (lookup name)
                         (errorf "schema %q is not registered" name))
                     keep-refs?)))
    [node true]))

(defn fields
  ``The fields of a map schema in the schema's own order (a map is
  normalized with its keys sorted), each unwrapped: a tuple of
  [key inner-node required?] (see `unwrap`; `keep-refs?` passes
  through). Anything but a map is an error — a projection of
  fields has nothing to say about a scalar.``
  [sch &opt keep-refs?]
  (def n (normalize sch))
  (unless (= :map (n :type))
    (errorf "schema/fields: expected a map schema, got %q" (n :type)))
  (tuple ;(seq [[k sub] :in (n :children)]
            (def [inner required?] (unwrap sub keep-refs?))
            [k inner required?])))

(defn- props-under [prefix props]
  (freeze (tabseq [[k v] :pairs props
                   :when (and (keyword? k) (string/has-prefix? prefix k))]
            k v)))

(defn annotations
  ``The props under one namespace prefix — "db/", "proto/", or any
  other a projection reserves — as {:schema {...} :fields {key {...}}}:
  the top-level props of the schema and, for a map, those of each field
  looked at under its :optional wrapper (a :ref is left alone: the
  annotation belongs to the field, not to the schema it points at).
  Annotations are parsed and stored on nodes and never consulted by
  validation; a schema without any is a plain DTO.``
  [sch prefix]
  (def n (normalize sch))
  (def fields @{})
  (when (= :map (n :type))
    (each [k sub] (n :children)
      (def [inner _] (unwrap sub true))
      (def ps (props-under prefix (inner :props)))
      (unless (empty? ps) (put fields k ps))))
  {:schema (props-under prefix (n :props))
   :fields (freeze fields)})

(defn db-annotations
  ``The :db/* annotations of a schema — `(annotations sch "db/")`:
  :db/table at the top, :db/pk, :db/type ... per field. They feed the
  entity layer, void/admin and migrations-diff.``
  [sch]
  (annotations sch "db/"))
