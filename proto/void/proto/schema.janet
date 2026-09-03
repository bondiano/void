### void/proto/schema — the schema layer, both directions.
###
### "Protobuf descriptor" is one of the projections of the
### schema layer, next to JSON Schema and form hints. This is that
### projection — and its inverse, which turns out to be the half that
### earns the package its keep:
###
###   **descriptor -> schema** (`schema-of`) runs on every registered
###   descriptor, so a message parsed out of a `.proto` file is a
###   registered void schema under the same name. Nothing else had to
###   be told: `[:ref :example/Order]` works, `void schemas` lists it,
###   void/openapi renders it into an OpenAPI document, void/rest
###   validates a request body against it and void/admin can build a
###   form out of it. One declaration, and the projections were
###   already written.
###
###   **schema -> descriptor** (`descriptor-of`, the `:proto`
###   projection) goes the other way for an application that declared
###   its shapes as void schemas and now wants them on the wire. It
###   needs one thing a schema cannot know: the field numbers, which
###   are the wire format's compatibility contract. `:proto/field` is
###   the annotation that carries them, and a field without one is an
###   error naming it — inventing a number from key order would make
###   the encoding depend on how the schema was written, and the next
###   edit would silently break every peer.
###
### **Two integers that are not one.** A void `:int` is a Janet
### number, which stops being exact at 2^53; an `int64` does not. So
### this module registers two schema types — `:proto/int64` and
### `:proto/uint64` — that accept a number *or* the int/s64 the codec
### hands back, and a descriptor's 64-bit fields project to those.
### They are registered at module load rather than at bootstrap
### because a descriptor registered at load projects its schema
### immediately; void/proto also contributes them to
### `:void.core/schema-type`, so `plugin/inspect` and CONTRACTS.md see
### them like any other custom type (registering twice replaces, which
### is what the schema layer's registry does by design).

(import void/core/schema :as schema)
(import ./wire :as wire)
(import ./descriptor :as desc)

# -- the two integer types -----------------------------------------------

(defn- int64-in-range? [v lo hi]
  (and (wire/integer-value? v) (compare<= lo v) (compare<= v hi)))

(def int64-min (int/s64 "-9223372036854775808"))
(def int64-max (int/s64 "9223372036854775807"))
(def uint64-max (int/u64 "18446744073709551615"))

(def types
  ``The custom schema types a protobuf descriptor projects onto: a
  64-bit integer is a Janet number when it fits in one and an
  int/s64 (or int/u64) when it does not, and a schema that says
  `:int` would reject exactly the values that needed the wider type.``
  {:proto/int64
   {:validate (fn [v _] (int64-in-range? v int64-min int64-max))
    :kind :number
    :coerce (fn [v _] (when (bytes? v)
                        (let [[ok n] (protect (int/s64 (string v)))]
                          (when ok (wire/narrow n)))))
    :message "must be a 64-bit signed integer"}
   :proto/uint64
   {:validate (fn [v _] (int64-in-range? v 0 uint64-max))
    :kind :number
    :coerce (fn [v _] (when (bytes? v)
                        (let [[ok n] (protect (int/u64 (string v)))]
                          (when ok (wire/narrow n)))))
    :message "must be a 64-bit unsigned integer"}})

(eachp [name spec] types (schema/register-type! name spec))

# -- descriptor -> schema ------------------------------------------------

(def- scalar-schemas
  {:double :number :float :number
   :int32 [:int {:min -2147483648 :max 2147483647}]
   :sint32 [:int {:min -2147483648 :max 2147483647}]
   :sfixed32 [:int {:min -2147483648 :max 2147483647}]
   :uint32 [:int {:min 0 :max 4294967295}]
   :fixed32 [:int {:min 0 :max 4294967295}]
   :int64 :proto/int64 :sint64 :proto/int64 :sfixed64 :proto/int64
   :uint64 :proto/uint64 :fixed64 :proto/uint64
   :bool :boolean :string :string :bytes :bytes})

(defn- type-schema [f entry]
  (if (= :ref (entry :type))
    # a reference to something not registered yet is a reference all
    # the same: the schema registry resolves [:ref ...] when a value is
    # validated, which is later than here and later than the
    # registration that will fill it in
    (let [d (or (desc/lookup (entry :ref))
                (break [:ref (entry :ref)]))]
      (if (= :enum (d :kind))
        # a peer built from a newer .proto sends a number this enum
        # does not name, and the codec keeps it — so the schema that
        # describes what the codec produces has to allow it
        [:or [:enum ;(sorted (keys (d :values)))] :int]
        [:ref (d :name)]))
    (or (scalar-schemas (entry :type))
        (errorf "proto schema: no schema for %q" (entry :type)))))

(defn schema-of
  ``A message descriptor as a void schema. Repeated
  becomes `[:vector ...]`, a map becomes `[:map-of ...]`, a message
  field and an `optional` one become `[:optional ...]` — because those
  are the fields the codec may leave out, and everything else it fills
  with a default.``
  [message]
  (def d (if (dictionary? message) message (desc/message! message)))
  (def out @{})
  (each f (d :fields)
    (def base
      (case (f :label)
        :repeated [:vector (type-schema f f)]
        :map [:map-of (type-schema f (f :key)) (type-schema f (f :value))]
        (type-schema f f)))
    (put out (f :name)
         (if (desc/explicit-presence? f) [:optional base] base)))
  # unknown fields ride along on a decoded message, and a schema that
  # did not know that would call every forwarded message invalid
  (put out (keyword "proto/unknown") [:optional :bytes])
  out)

(defn register-schema!
  ``Register a descriptor's schema under the descriptor's own name, so
  the rest of void sees a protobuf message as an ordinary schema.
  Enums register as their own `[:enum ...]`; services have no shape
  and register nothing.``
  [d]
  (case (d :kind)
    :message (schema/register! (d :name) (schema-of d))
    :enum (schema/register! (d :name) [:or [:enum ;(sorted (keys (d :values)))] :int])
    nil))

# -- schema -> descriptor ------------------------------------------------

(def- schema-scalars
  {:int :int64 :number :double :string :string :keyword :string
   :boolean :bool :bytes :bytes :buffer :bytes
   :proto/int64 :int64 :proto/uint64 :uint64})

(defn annotations
  ``The `:proto/*` props of a schema, the way `schema/db-annotations`
  reads the `:db/*` ones: they are stored on the nodes and never consulted
  by validation. Returns {:schema {...} :fields {key {...}}}.``
  [sch]
  (defn proto-props [props]
    (freeze (tabseq [[k v] :pairs props
                     :when (and (keyword? k) (string/has-prefix? "proto/" k))]
              k v)))
  (def n (schema/normalize sch))
  (def fields @{})
  (when (= :map (n :type))
    (each [k sub] (n :children)
      (def inner (if (= :optional (sub :type)) (first (sub :children)) sub))
      (def props (proto-props (inner :props)))
      (unless (empty? props) (put fields k props))))
  {:schema (proto-props (n :props)) :fields (freeze fields)})

(defn- unwrap [node]
  (if (= :optional (node :type)) [(first (node :children)) true] [node false]))

(defn- entry-type [name key node]
  (def props (node :props))
  (or (get props (keyword "proto/type"))
      (case (node :type)
        :ref (get-in node [:props :name])
        :enum (errorf (string "proto: %q field %q is an inline [:enum ...] — protobuf enums are "
                              "named types, so register it (schema/register!) and refer to it "
                              "with [:ref :name], or say which scalar it travels as with "
                              "{:proto/type :string}")
                      name key)
        (or (schema-scalars (node :type))
            (errorf (string "proto: %q field %q is a %q, and no protobuf type follows from "
                            "that — name one with {:proto/type :int32}")
                    name key (node :type))))))

(defn descriptor-of
  ``A void schema as a message descriptor — the `:proto` projection.

      (defschema Order
        {:id    [:string {:proto/field 1}]
         :total [:int {:proto/field 2 :proto/type :int64}]
         :items [:vector [:ref :Item] {:proto/field 3}]})

      (schema/project :proto Order {:name :example/Order})

  Every field needs `:proto/field`: a field number is the wire
  format's compatibility contract, and one invented from key order
  would change the moment somebody renamed a key. `:proto/type` names
  the protobuf type when the void type does not imply one (`:int` is
  `int64` unless told otherwise, since a Janet number outgrows int32
  without saying so).``
  [sch &opt opts]
  (default opts {})
  (def n (schema/normalize sch))
  (unless (= :map (n :type))
    (errorf "proto: only a map schema projects to a message, got %q" (n :type)))
  (def sprops (n :props))
  (def name (or (opts :name)
                (get sprops (keyword "proto/message"))
                (error "proto: this projection needs a name — (schema/project :proto s {:name :example/Order})")))
  (def fields @{})
  (each [key sub] (n :children)
    (def [node optional] (unwrap sub))
    (def props (node :props))
    (def number (get props (keyword "proto/field")))
    (unless number
      (errorf (string "proto: %q field %q has no :proto/field. A field number is what keeps "
                      "an encoding readable by a peer built yesterday, so void/proto will not "
                      "invent one — write [:string {:proto/field 3}]")
              name key))
    (def opt-table
      (tabseq [[from to] :in [[(keyword "proto/json-name") :json-name]
                              [(keyword "proto/oneof") :oneof]
                              [(keyword "proto/packed") :packed]]
               :when (not (nil? (get props from)))]
        to (get props from)))
    (put fields key
         (case (node :type)
           :vector [number :repeated (entry-type name key (first (node :children))) opt-table]
           :map-of [number :map
                    (entry-type name key (get (node :children) 0))
                    (entry-type name key (get (node :children) 1))
                    opt-table]
           (if optional
             [number :optional (entry-type name key node) opt-table]
             [number (entry-type name key node) opt-table]))))
  (desc/message name fields
                (tabseq [k :in [:proto-name :doc] :when (opts k)] k (opts k))))

(schema/register-projection! :proto
  (fn proto-projection [sch &opt opts] (descriptor-of sch opts)))
