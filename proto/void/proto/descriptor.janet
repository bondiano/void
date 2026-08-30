### void/proto/descriptor — a protobuf message as a value (SPEC.md
### §5.7, ADR-0013).
###
### The middle of the package, and the only thing the other modules
### agree on. A descriptor is plain data (ADR-0004), and it has three
### authors who never meet: `defmessage` writes one by hand, ./parse
### reads one out of a `.proto` file, and ./schema projects one from a
### schema the application already declared for validation. All three
### produce the same value, so ./codec and ./json know about only one
### of them.
###
### **Two vocabularies, one seam.** A descriptor speaks protobuf's
### words — `:repeated`, `:optional`, `:map`, `:sint64` — because that
### is what a `.proto` file says and what a wire format means. A void
### schema speaks void's — `:vector`, `:optional`, `:map-of`, `:int`.
### ./schema is the one place the two meet; nothing else in the
### repository has to learn that protobuf calls a vector "repeated".
###
### **Names.** A descriptor is registered under a keyword, and its
### protobuf name is the same string with the last dot turned into the
### slash: `example.Order` <-> `:example/Order`, and a nested
### `example.Order.Item` <-> `:example.Order/Item`. The mapping is
### total in both directions, which is what lets a message be
### registered in the *schema* registry under the same name — so
### `[:ref :example/Order]`, `void schemas`, OpenAPI and void/admin
### see a protobuf message without any of them knowing what protobuf
### is.
###
### **References resolve late.** A field naming `:example/Item` keeps
### the name, not the descriptor: messages are recursive (a tree node
### holds tree nodes) and a `.proto` file mentions a type long before
### it defines it. `resolve` is called when a value is encoded, and an
### unknown name is an error there rather than a nil three frames
### down.

(def scalars
  ``The proto3 scalar types: wire type, proto3 default, and whether a
  repeated field of this type is packed unless told otherwise.``
  (let [num (fn [wire] {:wire wire :default 0 :packable true})]
    {:double (merge (num :fixed64) {:numeric :float})
     :float (merge (num :fixed32) {:numeric :float})
     :int32 (merge (num :varint) {:numeric :int :bits 32 :signed true})
     :int64 (merge (num :varint) {:numeric :int :bits 64 :signed true})
     :uint32 (merge (num :varint) {:numeric :int :bits 32 :signed false})
     :uint64 (merge (num :varint) {:numeric :int :bits 64 :signed false})
     :sint32 (merge (num :varint) {:numeric :int :bits 32 :signed true :zigzag true})
     :sint64 (merge (num :varint) {:numeric :int :bits 64 :signed true :zigzag true})
     :fixed32 (merge (num :fixed32) {:numeric :int :bits 32 :signed false})
     :fixed64 (merge (num :fixed64) {:numeric :int :bits 64 :signed false})
     :sfixed32 (merge (num :fixed32) {:numeric :int :bits 32 :signed true})
     :sfixed64 (merge (num :fixed64) {:numeric :int :bits 64 :signed true})
     :bool {:wire :varint :default false :packable true}
     :string {:wire :length :default "" :packable false}
     :bytes {:wire :length :default "" :packable false}}))

(def max-field-number 536870911)

(def- reserved-field-numbers
  "19000-19999 belong to protobuf's own implementation, and always have."
  [19000 19999])

# -- names ---------------------------------------------------------------

(defn proto-name
  ``The protobuf name of a registered keyword: `:example/Order` ->
  "example.Order", `:Order` -> "Order".``
  [name]
  (unless (keyword? name)
    (errorf "proto: a descriptor name must be a keyword, got %q" name))
  (def s (string name))
  (if-let [slash (string/find "/" s)]
    (string (string/slice s 0 slash) "." (string/slice s (inc slash)))
    s))

(defn name-of
  ``The keyword a protobuf name registers under: "example.Order" ->
  `:example/Order`, "Order" -> `:Order`. The last dot becomes the
  slash, so a nested "example.Order.Item" is `:example.Order/Item`.``
  [pname]
  (def s (string pname))
  (def dots (string/find-all "." s))
  (if (empty? dots)
    (keyword s)
    (let [i (last dots)]
      (keyword (string/slice s 0 i) "/" (string/slice s (inc i))))))

(defn json-name
  ``The JSON name of a field: protobuf's lowerCamelCase of
  `some_field`. A field that carries its own `:json-name` keeps it —
  that is what `json_name = "..."` in a `.proto` file is for.``
  [name]
  (def parts (string/split "_" (string name)))
  (string (first parts)
          ;(seq [p :in (slice parts 1) :when (not (empty? p))]
             (string (string/ascii-upper (string/slice p 0 1))
                     (string/slice p 1)))))

# -- fields --------------------------------------------------------------

(def- labels {:singular true :repeated true :optional true :map true})

(defn- type-entry [fname t]
  (cond
    (scalars t) {:type t}
    (keyword? t) {:type :ref :ref t}
    (errorf (string "proto field %q: %q is not a type — a proto3 scalar (%s) or the "
                    "name of a message or an enum")
            fname t (string/join (map string (sorted (keys scalars))) " "))))

(defn- field-doc [fname]
  (string/format
    (string "proto field %q: expected [number type], [number :repeated type], "
            "[number :optional type] or [number :map key-type value-type], "
            "with an optional trailing option table")
    fname))

(defn field
  ``Normalize one field declaration. `spec` is `[number & form]`:

      [1 :string]                     singular
      [2 :repeated :example/Item]     repeated
      [3 :optional :int64]            explicit presence (proto3 optional)
      [4 :map :string :int32]         a map field
      [5 :string {:oneof :choice}]    with options

  Options: :json-name, :oneof, :packed (false writes a repeated scalar
  unpacked, which is what a proto2 peer expects), :deprecated, :doc.``
  [fname spec]
  (unless (keyword? fname)
    (errorf "proto: a field name must be a keyword, got %q" fname))
  (unless (and (indexed? spec) (>= (length spec) 2))
    (error (field-doc fname)))
  (def number (first spec))
  (unless (and (number? number) (= number (math/trunc number))
               (<= 1 number max-field-number))
    (errorf "proto field %q: %q is not a field number (1 - %d)"
            fname number max-field-number))
  (when (<= (reserved-field-numbers 0) number (reserved-field-numbers 1))
    (errorf "proto field %q: %d is in the range protobuf reserves for its own implementation (%d - %d)"
            fname number ;reserved-field-numbers))
  (def rest (slice spec 1))
  (def opts (let [l (last rest)] (if (dictionary? l) l {})))
  (def form (if (dictionary? (last rest)) (slice rest 0 -2) rest))
  (def label (if (labels (first form)) (first form) :singular))
  (def types (if (labels (first form)) (slice form 1) form))
  (def base
    (if (= :map label)
      (do
        (unless (= 2 (length types)) (error (field-doc fname)))
        (def k (type-entry fname (first types)))
        (when (or (= :ref (k :type)) (index-of (k :type) [:double :float :bytes]))
          (errorf (string "proto field %q: a map key is an integer, a bool or a string — "
                          "protobuf allows nothing else, and %q is not one")
                  fname (first types)))
        {:type :map :key k :value (type-entry fname (types 1))})
      (do
        (unless (= 1 (length types)) (error (field-doc fname)))
        (type-entry fname (first types)))))
  (def entry
    (merge
      {:name fname :number number :label label
       :json-name (get opts :json-name (json-name fname))}
      base
      (tabseq [k :in [:oneof :deprecated :doc] :when (not (nil? (opts k)))] k (opts k))))
  # packed is the default for a repeated numeric scalar in proto3, and
  # a peer sending the unpacked form is understood either way — the
  # option only says what *we* write
  (def packable (and (= :repeated label)
                     (get-in scalars [(entry :type) :packable] false)))
  (put entry :packed (and packable (get opts :packed true)))
  (when (and (entry :oneof) (not= :singular label))
    (errorf "proto field %q: a %q field cannot belong to a oneof" fname label))
  (freeze entry))

(defn wire-type
  ``The wire type a field's values travel as — the length-delimited
  form for a packed repeated field, a map or a message, and the
  scalar's own otherwise.``
  [f]
  (cond
    (f :packed) :length
    (= :map (f :type)) :length
    (= :ref (f :type)) :length
    (get-in scalars [(f :type) :wire])
    (errorf "proto field %q: no wire type for %q" (f :name) (f :type))))

# -- messages, enums, services -------------------------------------------

(defn- index-fields [name fields]
  (def by-number @{})
  (def by-name @{})
  (def by-json @{})
  (each f fields
    (when (in by-number (f :number))
      (errorf "proto message %q: field number %d is claimed by %q and by %q"
              name (f :number) (get-in by-number [(f :number) :name]) (f :name)))
    (put by-number (f :number) f)
    (put by-name (f :name) f)
    # a decoder accepts both spellings, which is what the proto3 JSON
    # mapping asks of it
    (put by-json (f :json-name) f)
    (put by-json (string (f :name)) f))
  [by-number by-name by-json])

(defn message
  ``Build a message descriptor from a name and a table of field
  declarations (see `field`):

      (message :example/Order
        {:id    [1 :string]
         :total [2 :int64]
         :items [3 :repeated :example/Item]})

  opts: :proto-name (the keyword's own spelling by default), :doc,
  :reserved.``
  [name fields &opt opts]
  (default opts {})
  (unless (dictionary? fields)
    (errorf "proto message %q: fields must be a dictionary, got %q" name fields))
  (def entries (sorted-by |($ :number)
                          (seq [k :in (sorted (keys fields))] (field k (fields k)))))
  (def [by-number by-name by-json] (index-fields name entries))
  (def oneofs @{})
  (each f entries
    (when-let [o (f :oneof)]
      (unless (oneofs o) (put oneofs o @[]))
      (array/push (oneofs o) (f :name))))
  (freeze
    {:kind :message
     :name name
     :proto-name (get opts :proto-name (proto-name name))
     :fields (tuple ;entries)
     :by-number by-number
     :by-name by-name
     :by-json by-json
     :oneofs oneofs
     :reserved (get opts :reserved [])
     :doc (opts :doc)}))

(defn enum
  ``Build an enum descriptor:

      (enum :example/Status {:unknown 0 :active 1 :closed 2})

  proto3 wants the first value to be zero, because that is what an
  absent field decodes to — an enum without one cannot say "unset",
  and the error says so rather than letting the hole reach the wire.``
  [name values &opt opts]
  (default opts {})
  (unless (dictionary? values)
    (errorf "proto enum %q: values must be a dictionary, got %q" name values))
  (def by-number @{})
  (var zero nil)
  (each k (sorted (keys values))
    (def v (values k))
    (unless (and (number? v) (= v (math/trunc v)))
      (errorf "proto enum %q: %q is not a number for %q" name v k))
    (when (zero? v) (set zero k))
    (if (in by-number v)
      (unless (get opts :allow-alias)
        (errorf "proto enum %q: %q and %q are both %d, and allow_alias is off"
                name (by-number v) k v))
      (put by-number v k)))
  (unless zero
    (errorf (string "proto enum %q: proto3 needs a value numbered 0 — it is what an "
                    "absent field decodes to, and an enum without one cannot say \"unset\"")
            name))
  (freeze
    {:kind :enum
     :name name
     :proto-name (get opts :proto-name (proto-name name))
     :values (freeze values)
     :by-number by-number
     :zero zero
     :allow-alias (truthy? (get opts :allow-alias))
     :doc (opts :doc)}))

(defn method
  ``Normalize one RPC method: {:name :GetOrder :input
  :orders/GetOrderRequest :output :orders/Order}, plus whatever the
  `.proto` said about streaming and idempotency.``
  [spec]
  (unless (and (dictionary? spec) (keyword? (spec :name)))
    (errorf "proto rpc: a method needs a keyword :name, got %q" spec))
  (each k [:input :output]
    (unless (keyword? (spec k))
      (errorf "proto rpc %q: %q must name a message, got %q" (spec :name) k (spec k))))
  (freeze
    (merge {:client-streaming false :server-streaming false :idempotent false}
           spec
           {:proto-name (get spec :proto-name (string (spec :name)))})))

(defn service
  ``Build a service descriptor — the value void/grpc projects into
  routes:

      (service :orders/OrderService
        [{:name :GetOrder :input :orders/GetOrderRequest
          :output :orders/Order :idempotent true}])``
  [name methods &opt opts]
  (default opts {})
  (def ms (map method methods))
  (def by-name @{})
  (each m ms
    (when (in by-name (m :name))
      (errorf "proto service %q: two methods named %q" name (m :name)))
    (put by-name (m :name) m))
  (freeze
    {:kind :service
     :name name
     :proto-name (get opts :proto-name (proto-name name))
     :methods (tuple ;ms)
     :by-name by-name
     :doc (opts :doc)}))

# -- the registry --------------------------------------------------------
#
# One table for messages, enums and services: a `.proto` file defines
# all three in one namespace, and so does this.

(def- registry @{})
(def- by-proto-name @{})
(def- watchers @[])
(var- pending @[])

(defn watch!
  ``Be told about descriptors as they are registered. `f` is called
  once per descriptor at the next `flush!` — which is a batch and not
  a callback per `register!` on purpose: a message may name a type the
  next line of the same file defines, and a watcher that resolved
  references eagerly would be reading a half-registered file.
  void/proto/schema is the one watcher in the repository, and it is
  what makes every protobuf message a registered void schema.``
  [f]
  (array/push watchers f)
  f)

(defn register!
  "Register a descriptor under its name. Re-registering replaces —
  REPL-friendly, like the schema registry. Returns the descriptor."
  [desc]
  (unless (and (dictionary? desc) (desc :kind) (keyword? (desc :name)))
    (errorf "proto: %q is not a descriptor" desc))
  (put registry (desc :name) desc)
  (put by-proto-name (desc :proto-name) desc)
  (array/push pending desc)
  desc)

(defn flush!
  ``Hand every descriptor registered since the last flush to the
  watchers, and return them. Called at the end of each public way in —
  a parsed file, a `defmessage`, `proto/register!` — so that by the
  time anything is projected, everything it can refer to is there.``
  []
  (def batch pending)
  (set pending @[])
  (each d batch
    (each w watchers (w d)))
  batch)

(defn deregister!
  "Forget a descriptor by name — the other half of `register!`, for a
  test that registered its own and a REPL that renamed something."
  [name]
  (when-let [d (registry name)]
    (put by-proto-name (d :proto-name) nil))
  (put registry name nil)
  nil)

(defn lookup
  "A descriptor by keyword name or by protobuf name, or nil."
  [name]
  (or (registry name)
      (if (bytes? name)
        (by-proto-name (string name))
        (when (keyword? name) (by-proto-name (proto-name name))))))

(defn registered
  "Names of every registered descriptor, optionally of one kind."
  [&opt kind]
  (sorted (seq [[k d] :pairs registry
                :when (or (nil? kind) (= kind (d :kind)))]
            k)))

(defn resolve
  ``The descriptor a field's `:ref` names, or an error saying who
  wanted it. Late by design: messages are recursive, and a `.proto`
  mentions a type before it defines one.``
  [name &opt whose]
  (or (lookup name)
      (errorf "proto: %q is not a registered message or enum%s"
              name (if whose (string/format " (wanted by %q)" whose) ""))))

(defn message!
  "A registered *message* descriptor, or an error."
  [name]
  (def d (resolve name))
  (unless (= :message (d :kind))
    (errorf "proto: %q is a %q, not a message" name (d :kind)))
  d)

(defn enum!
  "A registered *enum* descriptor, or an error."
  [name]
  (def d (resolve name))
  (unless (= :enum (d :kind))
    (errorf "proto: %q is a %q, not an enum" name (d :kind)))
  d)

(defn service!
  "A registered *service* descriptor, or an error."
  [name]
  (def d (resolve name))
  (unless (= :service (d :kind))
    (errorf "proto: %q is a %q, not a service" name (d :kind)))
  d)

(defn field!
  "One field of a message by name, or an error naming what is there."
  [desc fname]
  (or (get-in desc [:by-name fname])
      (errorf "proto message %q has no field %q (it has %s)"
              (desc :name) fname
              (string/join (map string (sorted (keys (desc :by-name)))) " "))))

# -- what a field means once its reference is resolved -------------------
#
# Three questions the codec asks about every field, and all three need
# the registry: a `:ref` is a message or an enum, and the two behave
# nothing alike. An enum is a scalar with names on it — implicit
# presence, a zero value, a varint on the wire. A message is the one
# thing in proto3 that can be *absent*.

(defn message-field?
  ``Does this field hold a message, rather than an enum or a scalar? A
  reference nobody has registered *yet* counts as one: two messages
  that name each other are declared in two forms, and the first of
  them has to be projectable before the second exists. An enum that
  turns up later costs the projected schema an `:optional` it did not
  need, and nothing on the wire.``
  [f]
  (and (= :ref (f :type))
       (let [d (lookup (f :ref))]
         (or (nil? d) (= :message (d :kind))))))

(defn explicit-presence?
  ``Can this field tell "unset" from "the default"? A singular message
  field, an `optional` one and a oneof member can — everything else
  has proto3's implicit presence, where the default and the absence
  are one value and neither reaches the wire.``
  [f]
  (or (= :optional (f :label))
      (truthy? (f :oneof))
      (and (= :singular (f :label)) (message-field? f))))

(defn default-value
  ``The proto3 default of a field: the type's zero for a scalar, the
  zero-numbered name for an enum, a fresh empty array for a repeated
  field, a fresh empty table for a map, and nil for a message —
  "absent" is the only thing a message field can mean.``
  [f]
  (case (f :label)
    :repeated @[]
    :map @{}
    (if (= :ref (f :type))
      (let [d (resolve (f :ref) (f :name))]
        (when (= :enum (d :kind)) (d :zero)))
      (get-in scalars [(f :type) :default]))))

# -- rendering -----------------------------------------------------------

(defn- simple-name [pname]
  (last (string/split "." pname)))

(defn- render-type [f]
  (case (f :type)
    :ref (proto-name (f :ref))
    :map (string "map<" (render-type (f :key)) ", " (render-type (f :value)) ">")
    (string (f :type))))

(defn render
  ``A descriptor as `.proto` source — what `void proto describe`
  prints. A projection rather than the original text: comments and
  option order are gone, and what is left is exactly what this package
  acts on, which is the reason to print it at all.``
  [desc]
  (def out @"")
  (case (desc :kind)
    :message
    (do
      (buffer/push out "message " (simple-name (desc :proto-name)) " {\n")
      (def seen-oneof @{})
      (each f (desc :fields)
        (def o (f :oneof))
        (cond
          (and o (in seen-oneof o)) nil
          o (do
              (put seen-oneof o true)
              (buffer/push out "  oneof " (string o) " {\n")
              (each n (get-in desc [:oneofs o])
                (def g (get-in desc [:by-name n]))
                (buffer/format out "    %s %s = %d;\n"
                               (render-type g) (string n) (g :number)))
              (buffer/push out "  }\n"))
          (buffer/format out "  %s%s %s = %d;\n"
                         (case (f :label) :repeated "repeated " :optional "optional " "")
                         (render-type f) (string (f :name)) (f :number))))
      (buffer/push out "}\n"))

    :enum
    (do
      (buffer/push out "enum " (simple-name (desc :proto-name)) " {\n")
      (each n (sorted (keys (desc :by-number)))
        (buffer/format out "  %s = %d;\n" (string (get-in desc [:by-number n])) n))
      (buffer/push out "}\n"))

    :service
    (do
      (buffer/push out "service " (simple-name (desc :proto-name)) " {\n")
      (each m (desc :methods)
        (buffer/format out "  rpc %s(%s%s) returns (%s%s);\n"
                       (m :proto-name)
                       (if (m :client-streaming) "stream " "") (proto-name (m :input))
                       (if (m :server-streaming) "stream " "") (proto-name (m :output))))
      (buffer/push out "}\n"))

    (buffer/format out "%q\n" desc))
  (string out))
