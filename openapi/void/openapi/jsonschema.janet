### void/openapi/jsonschema — normalized schema nodes -> JSON Schema.
###
### The OpenAPI side of "one declaration, many projections": a walk
### over the node structs void/core/schema normalizes everything into,
### producing plain JSON Schema data (draft 2020-12, the OpenAPI 3.1
### dialect) with string keys ready for json/encode. A [:ref :Order]
### becomes "$ref" "#/components/schemas/Order" and the name lands in
### the caller's refs set; `components` chases those references through
### the schema registry to a fixpoint, so a spec ships every schema it
### mentions, transitively. What JSON Schema cannot express
### (:pred, custom types) degrades to an annotated permissive schema
### instead of failing — contract discipline says handle every node type,
### not reject the schema. Registered with the schema layer as the
### :openapi projection by init.janet, through the same
### :void.core/schema-projection extension point third-party projections
### would use.

(import void/core/schema :as schema)

(defn ref-path
  "The components pointer for a registered schema name."
  [name]
  (string "#/components/schemas/" name))

(defn- plain [v]
  (if (keyword? v) (string v) v))

(defn- bounds [out props min-key max-key]
  (when-let [m (props :min)] (put out min-key m))
  (when-let [m (props :max)] (put out max-key m))
  out)

(defn- string-node [props]
  (def out @{"type" "string"})
  (bounds out props "minLength" "maxLength")
  (when-let [f (props :format)] (put out "format" (string f)))
  (when-let [p (props :pattern)]
    (when (bytes? p) (put out "pattern" (string p))))
  out)

(var- convert* nil)

(defn- map-node [node refs]
  (def out @{"type" "object"})
  (def properties @{})
  (def required @[])
  (each [k sub] (node :children)
    (put properties (string k) (convert* sub refs))
    (unless (= :optional (sub :type))
      (array/push required (string k))))
  (unless (empty? properties) (put out "properties" properties))
  (unless (empty? required) (put out "required" required))
  (when (get-in node [:props :closed])
    (put out "additionalProperties" false))
  out)

(defn convert
  ``One normalized node (sugar accepted) as JSON Schema data; every
  [:ref name] encountered is recorded into the mutable `refs` set.``
  [sch refs]
  (def node (schema/normalize sch))
  (def props (node :props))
  (case (node :type)
    :ref (do (put refs (props :name) true)
             @{"$ref" (ref-path (props :name))})
    :optional @{"anyOf" @[(convert* (first (node :children)) refs)
                          @{"type" "null"}]}
    :map (map-node node refs)
    :map-of @{"type" "object"
              "additionalProperties" (convert* (get (node :children) 1) refs)}
    :vector (bounds @{"type" "array"
                      "items" (convert* (first (node :children)) refs)}
                    props "minItems" "maxItems")
    :enum @{"enum" (map plain (props :values))}
    :union @{"anyOf" (map |(convert* $ refs) (node :children))}
    :and @{"allOf" (map |(convert* $ refs) (node :children))}
    :literal @{"const" (plain (props :value))}
    :pred @{"x-void/type" "pred"
            "description" (or (let [m (props :message)]
                                (when (bytes? m) (string m)))
                              "opaque predicate")}
    :peg @{"type" "string" "x-void/type" "peg"}
    :int (bounds @{"type" "integer"} props "minimum" "maximum")
    :number (bounds @{"type" "number"} props "minimum" "maximum")
    :boolean @{"type" "boolean"}
    :nil @{"type" "null"}
    :any @{}
    :string (string-node props)
    :bytes (string-node props)
    :buffer (string-node props)
    :keyword @{"type" "string"}
    :symbol @{"type" "string"}
    :tuple @{"type" "array"}
    :array @{"type" "array"}
    :indexed @{"type" "array"}
    :table @{"type" "object"}
    :struct @{"type" "object"}
    :dictionary @{"type" "object"}
    :function @{"x-void/type" "function"}
    # a custom registered type: permissive, annotated
    @{"x-void/type" (string (node :type))}))

(set convert* convert)

(defn json-schema
  "convert without the ref bookkeeping — the :openapi projection
  surface: (schema/project :openapi Order)."
  [sch]
  (convert sch @{}))

(defn components
  ``Resolve a refs set (name -> true) through the schema registry to a
  fixpoint: {"Order" {...} ...} covering every schema the seeds
  mention, transitively. An unregistered name converts to an annotated
  permissive schema — the spec still builds, the gap is visible.``
  [refs]
  (def out @{})
  (def pending (array ;(keys refs)))
  (while (not (empty? pending))
    (def name (array/pop pending))
    (unless (in out (string name))
      (def more @{})
      (put out (string name)
           (if-let [sch (schema/lookup name)]
             (convert sch more)
             @{"x-void/unregistered" (string name)}))
      (eachk r more
        (unless (in out (string r))
          (array/push pending r)))))
  out)
