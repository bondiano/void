### void/proto/wkt — the well-known types (SPEC.md §5.7).
###
### `google/protobuf/*.proto` is not a library one downloads: every
### protobuf implementation ships these descriptors, because a
### `.proto` in the wild imports them and a JSON encoder is required
### to give four of them a form of their own (a Timestamp is an RFC
### 3339 string, not `{"seconds":"...","nanos":0}`). So they are here,
### written as ordinary descriptors — which is the point: nothing in
### ./codec knows they exist, and an `import
### "google/protobuf/timestamp.proto"` resolves against this registry
### rather than against a file somebody has to have.
###
### What is here is what an RPC service actually uses: Timestamp,
### Duration, the nine wrappers, Empty and FieldMask. What is not:
### Struct, Value, ListValue and Any. The first three are JSON in
### protobuf's clothing and would need a recursive special case in
### both directions; Any needs a type registry keyed by URL and a
### `.proto` most services do not have. Their absence is an error
### naming them, not a silent mis-encoding.

(import ./descriptor :as desc)

(def- timestamp-fields {:seconds [1 :int64] :nanos [2 :int32]})

(def wrappers
  ``The nine `google.protobuf.*Value` messages: one field, number 1,
  and a JSON form that is the bare value. They exist so a proto3
  field can say "unset" without `optional`, which is the problem
  `optional` solved later and better.``
  {"google.protobuf.DoubleValue" :double
   "google.protobuf.FloatValue" :float
   "google.protobuf.Int64Value" :int64
   "google.protobuf.UInt64Value" :uint64
   "google.protobuf.Int32Value" :int32
   "google.protobuf.UInt32Value" :uint32
   "google.protobuf.BoolValue" :bool
   "google.protobuf.StringValue" :string
   "google.protobuf.BytesValue" :bytes})

(def unsupported
  ``The well-known types void/proto does not carry, and why. Named
  here so an import of one is an error that says what happened rather
  than "unknown message".``
  {"google.protobuf.Any" (string "Any carries a type URL and the encoded bytes of whatever it "
                                 "names, so decoding one means a registry keyed by URL and a "
                                 "descriptor nobody handed us")
   "google.protobuf.Struct" "Struct, Value and ListValue are JSON wearing protobuf's clothes"
   "google.protobuf.Value" "Struct, Value and ListValue are JSON wearing protobuf's clothes"
   "google.protobuf.ListValue" "Struct, Value and ListValue are JSON wearing protobuf's clothes"})

(def files
  ``Which `.proto` path defines which of these, so an `import` in a
  parsed file resolves without the file being on disk.``
  {"google/protobuf/timestamp.proto" ["google.protobuf.Timestamp"]
   "google/protobuf/duration.proto" ["google.protobuf.Duration"]
   "google/protobuf/empty.proto" ["google.protobuf.Empty"]
   "google/protobuf/field_mask.proto" ["google.protobuf.FieldMask"]
   "google/protobuf/wrappers.proto" (sorted (keys wrappers))})

(defn- register-message [pname fields]
  (desc/register! (desc/message (desc/name-of pname) fields {:proto-name pname})))

(defn install!
  ``Register every well-known type void/proto carries. Called once at
  module load; calling it again is harmless (the registry replaces).``
  []
  (register-message "google.protobuf.Timestamp" timestamp-fields)
  (register-message "google.protobuf.Duration" timestamp-fields)
  (register-message "google.protobuf.Empty" {})
  (register-message "google.protobuf.FieldMask" {:paths [1 :repeated :string]})
  (eachp [pname t] wrappers
    (register-message pname {:value [1 t]}))
  nil)

(install!)

(defn file
  ``The protobuf names a `google/protobuf/*.proto` import brings in, or
  nil when the path is not one of ours.``
  [path]
  (files (string path)))
