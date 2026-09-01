### void/proto — protobuf, in Janet (SPEC.md §5.7, ADR-0013).
###
### The foundation of the protocol branch, and the one ADR-0013 says
### to write first: void/grpc needs it to speak Connect's binary
### codec, and OTLP has a protobuf encoding waiting behind
### `[:obs-otlp :encoding]` for the day somebody wants it (ADR-0027
### shipped the JSON one without this package on purpose).
###
###     (proto/defproto "protos/orders.proto")
###
###     (proto/encode :orders/Order {:id "A-1" :total 990})
###     (proto/decode :orders/Order bytes)
###     (proto/to-json :orders/Order value)
###
### **A message is a table, and that is the whole object model.** No
### generated classes, no accessors, no builder: a decoded message is
### an ordinary Janet table with keyword keys, which is what every
### other layer in void already knows how to validate, log, put in a
### job's arguments and compare in a test. What a code generator would
### have produced is instead a *descriptor* — data — and one codec
### that reads it.
###
### **What lives where.** ./wire is the format's bottom (varints,
### tags, IEEE 754 by hand); ./descriptor is a message as a value;
### ./codec is encode and decode against one; ./json is the proto3
### JSON mapping, which Connect's `application/json` needs; ./parse is
### the `.proto` grammar as a PEG; ./schema is the schema layer in
### both directions; ./wkt carries `google/protobuf/*.proto` so an
### import of one resolves against nothing on disk.
###
### **Every message is a registered void schema.** ./schema *watches*
### the descriptor registry, so a message parsed out of a `.proto`
### file is a schema under the same name without anybody asking —
### which means `[:ref :orders/Order]`, `void schemas`, void/openapi's
### document, void/rest's body validation and void/admin's forms all
### work on a protobuf message, and none of them learned anything.
### That is SPEC §3.3's "one declaration, many projections" collecting
### on an investment made in wave 1.
###
### **What it does not do.** No proto2: `required`, groups and field
### defaults have no encoding here, and each is refused by name rather
### than approximated. No `Any`, `Struct`, `Value` or `ListValue` (see
### ./wkt). No `descriptor.proto` self-description and no gRPC server
### reflection — reflection is a *service*, and it belongs to
### void/grpc if it belongs anywhere.

(import void/core/plugin :as plugin)
(import void/core/schema :as schema)
(import ./wire :as wire)
(import ./descriptor :as descriptor)
(import ./codec :as codec)
(import ./json :as pjson)
(import ./parse :as parse)
(import ./schema :as pschema)
(import ./wkt :as wkt)

# -- the descriptor registry, and the schema layer watching it -----------

(descriptor/watch! pschema/register-schema!)

(defn register!
  ``Register a descriptor and project it into the schema registry.
  The public door to `descriptor/register!` — everything void/proto
  offers goes through here, so nothing can register a message that
  the rest of void cannot see.``
  [desc]
  (descriptor/register! desc)
  (descriptor/flush!)
  desc)

(defn registered
  "Names of every registered descriptor, optionally of one kind
  (:message, :enum, :service)."
  [&opt kind]
  (descriptor/registered kind))

(defn lookup
  "A descriptor by keyword name or protobuf name, or nil."
  [name]
  (descriptor/lookup name))

(defn describe
  "A descriptor as `.proto` source — what `void proto describe`
  prints."
  [name]
  (descriptor/render (or (descriptor/lookup name)
                         (errorf "void/proto: nothing is registered as %q" name))))

# -- the codec, re-exported ----------------------------------------------

(defn encode
  "Encode a message value to protobuf bytes."
  [message value &opt buf]
  (codec/encode message value buf))

(defn decode
  "Decode protobuf bytes into a message value."
  [message bytes]
  (codec/decode message bytes))

(defn to-json
  "A message value as plain data in the proto3 JSON mapping."
  [message value &opt opts]
  (pjson/to-json message value opts))

(defn from-json
  "Plain data in the proto3 JSON mapping as a message value."
  [message value &opt opts]
  (pjson/from-json message value opts))

(defn encode-json
  "A message value as a proto3-JSON string."
  [message value &opt opts]
  (pjson/encode message value opts))

(defn decode-json
  "A proto3-JSON string as a message value."
  [message text &opt opts]
  (pjson/decode message text opts))

# -- declaring messages in Janet -----------------------------------------

(defmacro defmessage
  ``Declare and register a message:

      (defmessage :example/Order
        {:id    [1 :string]
         :total [2 :int64]
         :items [3 :repeated :example/Item]
         :tags  [4 :map :string :string]
         :note  [5 :optional :string]})

  The name is also the name its void schema registers under. See
  `descriptor/field` for the field forms.``
  [name fields &opt opts]
  ~(,register! (,descriptor/message ,name ,fields ,opts)))

(defmacro defenum
  ``Declare and register an enum:

      (defenum :example/Status {:unknown 0 :active 1 :closed 2})

  proto3 wants a zero value, and so does this.``
  [name values &opt opts]
  ~(,register! (,descriptor/enum ,name ,values ,opts)))

(defmacro defservice-proto
  ``Declare and register a *service descriptor* — the shape of an
  RPC service with no handlers attached. void/grpc's `defservice`
  binds handlers to one of these; here is the shape by itself, for a
  service declared in Janet rather than in a `.proto` file.``
  [name methods &opt opts]
  ~(,register! (,descriptor/service ,name ,methods ,opts)))

(defn- source-dir []
  (def f (dyn *current-file*))
  (if (and f (string/find "/" f))
    (string/slice f 0 (last (string/find-all "/" f)))
    "."))

(defmacro defproto
  ``Load a `.proto` file **at compile time** and register everything in
  it:

      (defproto "protos/orders.proto")
      (defproto "protos/orders.proto" {:paths ["vendor/protos"]})

  The path is relative to the file this form appears in — and so is
  every relative `:paths` entry, because both name files that travel
  with the module, not with whatever directory the process was started
  in. Imports resolve next to the importing file and then along
  `:paths` — except `google/protobuf/*.proto`, which ./wkt already
  has. Parsing happens
  while the module compiles and the descriptors are baked into it as
  values, so a running application never reads a `.proto` (SPEC §8.5
  rule 3: what can happen at build time does).

  This is the codegen macro SPEC §5.7 asks for, and the code it
  generates is data — there are no message classes to generate.``
  [path &opt opts]
  (default opts {})
  (def dir (source-dir))
  (defn rooted [p] (if (string/has-prefix? "/" p) p (string dir "/" p)))
  (def where (rooted path))
  (def paths (map rooted (get opts :paths [])))
  # `seen` is how `load` remembers which files it has parsed, and
  # therefore exactly which files this form is responsible for — this
  # one and everything its imports reached, and nothing that some other
  # module registered earlier in the same compilation
  (def seen @{})
  (def file (parse/load where (merge opts {:seen seen :paths paths})))
  (def all @[])
  (each parsed (values seen)
    (when (dictionary? parsed)
      (each d (parsed :descriptors) (array/push all d))))
  ~(do
     ,;(seq [d :in all] ~(,register! ',d))
     ',(freeze (merge {} file
                      {:descriptors (tuple ;(map |($ :name) (file :descriptors)))}))))

# -- extension point -----------------------------------------------------

(plugin/defextension-point :void.proto/file
  :doc "`.proto` files a plugin ships: {:name :orders/api :path \"protos/orders.proto\" :paths [\"vendor/protos\"]?}. Loaded and registered at :before-start, before any route table is built, so void/grpc can project a service declared in a file the application never imported. A plugin that would rather have its descriptors baked into its module uses `proto/defproto` and contributes nothing"
  :schema {:name :keyword
           :path :string
           :paths [:optional [:vector :string]]
           :doc [:optional :string]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (when (in seen (c :name))
                  (errorf "duplicate .proto contribution %q" (c :name)))
                (put seen (c :name) true)))
  :reduce |(sorted-by |($ :name) $))

# -- custom schema types and the projection ------------------------------
#
# ./schema registers both at module load, because a descriptor
# registered while a module loads projects its schema right then —
# long before a bootstrap could resolve an extension point. They are
# declared here as well so `plugin/inspect` and CONTRACTS.md show them
# next to every other custom type and projection; registering twice is
# a replace, which is what the schema layer's registries do by design.

(eachp [name spec] pschema/types
  (plugin/contribute! :void.core/schema-type {:name name :spec spec}))

(plugin/contribute! :void.core/schema-projection
  {:name :proto
   :fn (fn proto-projection [sch &opt opts] (pschema/descriptor-of sch opts))})

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:proto] config slice."
  {:paths [:optional [:vector :string]]})

(def defaults {:paths []})

(var settings "The [:proto] slice, read at :before-start." defaults)

(defn load-file!
  ``Read, parse and register a `.proto` file and everything it
  imports. `paths` are searched after the importing file's own
  directory; `[:proto :paths]` is appended to them.``
  [path &opt paths]
  (parse/load path {:paths [;(or paths []) ;(get settings :paths [])]})
  (descriptor/flush!)
  nil)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 300
   :name :proto/load-files
   :doc "Load every :void.proto/file contribution, before route tables are built"
   :fn (fn load-files [boot]
         (set settings (merge defaults (or (get-in boot [:config :values :proto]) {})))
         (each c (get-in boot [:extensions :void.proto/file :resolved] [])
           (def [ok err] (protect (load-file! (c :path) (get c :paths []))))
           (unless ok
             (errorf "void/proto: %q could not load %q: %s"
                     (c :name) (c :path) (if (string? err) err (string/format "%q" err))))))})

# -- CLI -----------------------------------------------------------------

(defn- kind-line [name]
  (def d (descriptor/lookup name))
  (string/format "%-10s %-32s %s"
                 (string (d :kind)) (string name) (d :proto-name)))

(plugin/contribute! :void.core/cli
  {:name :proto/list
   :read-only? true
   :doc "List every registered protobuf descriptor: void proto list [messages|enums|services]"
   :fn (fn cli-list [& args]
         (def kind (case (first args)
                     nil nil
                     "messages" :message
                     "enums" :enum
                     "services" :service
                     (errorf "void proto list takes messages, enums or services (got %q)"
                             (first args))))
         (def names (descriptor/registered kind))
         (if (empty? names)
           (print "no protobuf descriptors are registered")
           (each n names (print (kind-line n)))))})

(plugin/contribute! :void.core/cli
  {:name :proto/describe
   :read-only? true
   :doc "Print a descriptor as .proto source: void proto describe example.Order"
   :fn (fn cli-describe [& args]
         (unless (= 1 (length args))
           (error "void proto describe takes one name: void proto describe example.Order"))
         (def name (first args))
         (def d (or (descriptor/lookup name)
                    (descriptor/lookup (keyword name))
                    (errorf "nothing is registered as %q (void proto list shows what is)" name)))
         (prin (descriptor/render d)))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/proto
  :doc "protobuf in pure Janet: the wire format, a codec over descriptors, the proto3 JSON mapping, a `.proto` parser on PEG, and the schema layer in both directions — every registered message is a registered void schema, so OpenAPI, validation and the admin see it without knowing what protobuf is."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :proto
  :config-schema Config
  :config-defaults defaults)
