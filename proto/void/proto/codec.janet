### void/proto/codec — a value against a descriptor (SPEC.md §5.7,
### ADR-0013).
###
### Encode and decode, and the proto3 semantics that make the two
### asymmetric. What the format decided and this module obeys:
###
###   **A singular scalar equal to its default is not written.** That
###   is what "implicit presence" means, and it is why `{:qty 0}` and
###   `{}` are the same message. A field that has to tell zero from
###   absent says so — `optional` in the `.proto`, `:optional` in the
###   descriptor — and then it is written whenever it is present.
###
###   **A decoded message has every field.** Scalars come back as
###   their defaults, repeated fields as an empty array, maps as an
###   empty table; only a message field and an explicitly-present one
###   are absent, because for those absence is the value.
###
###   **Unknown fields survive.** Bytes for a field number this
###   descriptor never heard of are kept verbatim under
###   `:proto/unknown` and written back out at the end. A proxy, a
###   sidecar or an older replica must not be the reason a field
###   another peer added disappears — a decode that dropped them would
###   turn read-modify-write into data loss.
###
###   **Concatenation merges.** Two encodings of the same message
###   appended are the merge of the two, so a repeated field
###   accumulates, a singular one takes the last value and a nested
###   message merges into whatever is already there. `decode-into` is
###   that rule with a name.
###
### Depth is bounded (`:max-depth`, 64 by default): a length-delimited
### field can nest into itself forever, and a message from the network
### is a stranger.

(import ./wire :as wire)
(import ./descriptor :as desc)

(def unknown-key
  ``Where bytes belonging to field numbers this descriptor does not
  know are kept — one buffer, in the order they arrived.``
  :proto/unknown)

(def default-max-depth 64)

# -- values in -----------------------------------------------------------

(defn- fail [path msg & args]
  (errorf "proto: %s: %s" (string/join (map string path) ".")
          (string/format msg ;args)))

(defn- int-value [path f v]
  (unless (wire/integer-value? v)
    (fail path "%q is not an integer, and %q is" v (f :type)))
  (def spec (desc/scalars (f :type)))
  (when (= 32 (spec :bits))
    (def n (if (number? v) v (int/to-number v)))
    (def [lo hi] (if (spec :signed) [-2147483648 2147483647] [0 4294967295]))
    (unless (<= lo n hi)
      (fail path "%q does not fit in a %q (%d .. %d)" v (f :type) lo hi)))
  (when (and (not (spec :signed)) (compare< v 0))
    (fail path "%q is negative, and %q is not" v (f :type)))
  v)

(defn- string-value [path v]
  (cond
    (bytes? v) (string v)
    (or (keyword? v) (symbol? v)) (string v)
    (fail path "%q is not a string" v)))

(defn- enum-number [path fname v]
  (def e (desc/enum! fname))
  (cond
    (number? v) v
    (keyword? v) (or (get-in e [:values v])
                     (fail path "%q is not a value of %q (it has %s)"
                           v (e :name)
                           (string/join (map string (sorted (keys (e :values)))) " ")))
    (fail path "%q is neither a name nor a number of %q" v (e :name))))

(varfn encode-message [d value buf path depth] nil)

(defn- default-value?
  ``Is this the value proto3 leaves off the wire? A default is not
  written, which is what makes {:qty 0} and {} the same message. An
  enum is compared by number, so the zero value counts whether the
  caller spelled it as a name or as 0; a string and a buffer of the
  same emptiness are the same emptiness.``
  [path f v]
  (case (f :type)
    :ref (let [d (desc/resolve (f :ref) (f :name))]
           (and (= :enum (d :kind)) (zero? (enum-number path (f :ref) v))))
    :string (and (bytes? v) (zero? (length v)))
    :bytes (and (bytes? v) (zero? (length v)))
    :bool (not v)
    (and (wire/integer-value? v) (compare= v 0))))


(defn- encode-scalar [buf path f t v]
  (case t
    :bool (wire/encode-varint buf (if v 1 0))
    :string (wire/encode-bytes buf (string-value path v))
    :bytes (do (unless (bytes? v) (fail path "%q is not bytes" v))
               (wire/encode-bytes buf v))
    :double (do (unless (number? v) (fail path "%q is not a number" v))
                (wire/encode-double buf v))
    :float (do (unless (number? v) (fail path "%q is not a number" v))
               (wire/encode-float buf v))
    (let [n (int-value path f v)
          spec (desc/scalars t)]
      (case (spec :wire)
        :varint (if (spec :zigzag)
                  (wire/encode-varint buf (wire/zigzag n))
                  (wire/encode-varint buf n))
        :fixed32 (wire/encode-fixed32 buf n)
        :fixed64 (wire/encode-fixed64 buf n)))))

(defn- encode-value
  "One field value, without its tag."
  [buf path f v depth]
  (if (= :ref (f :type))
    (let [d (desc/resolve (f :ref) (f :name))]
      (if (= :enum (d :kind))
        (wire/encode-varint buf (enum-number path (f :ref) v))
        (do
          (unless (dictionary? v) (fail path "%q is not a message" v))
          (def inner @"")
          (encode-message d v inner path (inc depth))
          (wire/encode-bytes buf inner))))
    (encode-scalar buf path f (f :type) v)))

(defn- entry-wire-type [f]
  (if (= :ref (f :type))
    (let [d (desc/resolve (f :ref) (f :name))]
      (if (= :enum (d :kind)) :varint :length))
    (get-in desc/scalars [(f :type) :wire])))

(defn- encode-map-entry [buf path f k v depth]
  (def entry @"")
  (def kf (merge (f :key) {:name (f :name) :number 1 :label :singular}))
  (def vf (merge (f :value) {:name (f :name) :number 2 :label :singular}))
  # an entry omits a default key or value, exactly as a message omits
  # a default singular field — the reader fills both back in
  (unless (default-value? path kf k)
    (wire/encode-tag entry 1 (entry-wire-type kf))
    (encode-value entry path kf k depth))
  (unless (or (nil? v) (default-value? path vf v))
    (wire/encode-tag entry 2 (entry-wire-type vf))
    (encode-value entry path vf v depth))
  (wire/encode-tag buf (f :number) :length)
  (wire/encode-bytes buf entry))

(varfn encode-message [d value buf path depth]
  (when (> depth default-max-depth)
    (fail path "message nests deeper than %d levels" default-max-depth))
  (unless (dictionary? value)
    (fail path "%q is not a message" value))
  # a oneof is one choice, and two values in it is a bug in the caller
  # rather than something to resolve by field order
  (eachp [name members] (d :oneofs)
    (def set-members (filter |(not (nil? (get value $))) members))
    (when (> (length set-members) 1)
      (fail path "oneof %q has %d values set (%s) and it holds one"
            name (length set-members)
            (string/join (map string set-members) " "))))
  (each f (d :fields)
    (def v (get value (f :name)))
    (def fpath [;path (f :name)])
    (cond
      (nil? v) nil

      (= :repeated (f :label))
      (do
        (unless (indexed? v) (fail fpath "%q is not a list" v))
        (unless (empty? v)
          (if (f :packed)
            (do
              (def packed @"")
              (each item v (encode-scalar packed fpath f (f :type) item))
              (wire/encode-tag buf (f :number) :length)
              (wire/encode-bytes buf packed))
            (each item v
              (wire/encode-tag buf (f :number) (entry-wire-type f))
              (encode-value buf fpath f item depth)))))

      (= :map (f :label))
      (do
        (unless (dictionary? v) (fail fpath "%q is not a map" v))
        (eachp [k item] v
          (encode-map-entry buf fpath f k item depth)))

      # implicit presence: a default is not written
      (and (not (desc/explicit-presence? f)) (default-value? fpath f v)) nil

      (do
        (wire/encode-tag buf (f :number) (entry-wire-type f))
        (encode-value buf fpath f v depth))))
  (when-let [raw (get value unknown-key)]
    (buffer/push buf raw))
  buf)

(defn encode
  ``Encode `value` (a dictionary) against a message descriptor or the
  name of one. Returns a buffer:

      (codec/encode :example/Order {:id "A-1" :total 990})

  Field order on the wire is field-number order, which is what makes
  two encodings of the same value the same bytes.``
  [message value &opt buf]
  (def d (if (dictionary? message) message (desc/message! message)))
  (encode-message d value (or buf @"") [(d :name)] 0))

# -- values out ----------------------------------------------------------

(defn- decode-scalar [f t bytes idx path]
  (case t
    :bool (let [[v next] (wire/decode-varint bytes idx)]
            [(not (and (number? v) (zero? v))) next])
    :string (let [[v next] (wire/decode-bytes bytes idx)] [v next])
    :bytes (wire/decode-bytes bytes idx)
    :double (wire/decode-double bytes idx)
    :float (wire/decode-float bytes idx)
    (let [spec (desc/scalars t)]
      (case (spec :wire)
        :varint (let [[v next] (wire/decode-varint bytes idx)]
                  [(cond
                     (spec :zigzag) (wire/unzigzag v)
                     # a negative int32 or int64 is written as the
                     # unsigned two's-complement reading of itself, all
                     # ten bytes of it — so only a value too wide for a
                     # double can be one, and a signed field reads that
                     # one back through int/s64
                     (and (spec :signed) (not (number? v))) (wire/narrow (int/s64 v))
                     (wire/narrow v))
                   next])
        :fixed32 (let [[v next] (wire/decode-fixed32 bytes idx)]
                   [(if (and (spec :signed) (>= v 2147483648)) (- v 4294967296) v) next])
        :fixed64 (let [[v next] (wire/decode-fixed64 bytes idx)]
                   [(wire/narrow (if (spec :signed) (int/s64 v) v)) next])
        (errorf "proto: no reader for %q" t)))))

(varfn decode-fields [d bytes start stop into path depth] nil)

(defn- decode-value [f bytes idx path depth]
  (if (= :ref (f :type))
    (let [dd (desc/resolve (f :ref) (f :name))]
      (if (= :enum (dd :kind))
        (let [[v next] (wire/decode-varint bytes idx)
              n (if (number? v) v (int/to-number (int/s64 v)))]
          # a number this enum does not name is kept as the number:
          # that is what a peer built from a newer .proto sends, and
          # dropping it is how a round trip loses a value
          [(get-in dd [:by-number n] n) next])
        (let [[len next] (wire/decode-varint bytes idx)
              stop (+ next len)]
          (when (> stop (length bytes))
            (errorf "proto: %s: message field runs past the end" (string/join (map string path) ".")))
          [(decode-fields dd bytes next stop @{} path (inc depth)) stop])))
    (decode-scalar f (f :type) bytes idx path)))

(defn- decode-map-entry [f bytes idx path depth]
  (def [len next] (wire/decode-varint bytes idx))
  (def stop (+ next len))
  (def kf (merge (f :key) {:name (f :name) :number 1 :label :singular}))
  (def vf (merge (f :value) {:name (f :name) :number 2 :label :singular}))
  (var k (desc/default-value kf))
  (var v (desc/default-value vf))
  (var i next)
  (while (< i stop)
    (def [number wtype after-tag] (wire/decode-tag bytes i))
    (cond
      (= 1 number) (let [[value j] (decode-value kf bytes after-tag path depth)]
                     (set k value) (set i j))
      (= 2 number) (let [[value j] (decode-value vf bytes after-tag path depth)]
                     (set v value) (set i j))
      (set i (wire/skip-value bytes after-tag wtype))))
  [k v stop])

(defn- blank
  ``A fresh message: proto3 says a decoded message has a value for
  every field, so the defaults are here before a byte is read.
  Everything with explicit presence — a message field, an `optional`
  one, a oneof member — is left out, because for those the absence
  *is* the value.``
  [d into]
  (each f (d :fields)
    (unless (or (desc/explicit-presence? f) (not (nil? (get into (f :name)))))
      (put into (f :name) (desc/default-value f))))
  into)

(varfn decode-fields [d bytes start stop into path depth]
  (when (> depth default-max-depth)
    (errorf "proto: %q nests deeper than %d levels — refusing to keep reading"
            (d :name) default-max-depth))
  (blank d into)
  (var i start)
  (while (< i stop)
    (def tag-at i)
    (def [number wtype after-tag] (wire/decode-tag bytes i))
    (def f (get-in d [:by-number number]))
    (cond
      (nil? f)
      # a field this descriptor never heard of: kept verbatim, tag
      # included, and written back out on the next encode
      (let [next (wire/skip-value bytes after-tag wtype)]
        (unless (get into unknown-key) (put into unknown-key @""))
        (buffer/push (get into unknown-key) (string/slice bytes tag-at next))
        (set i next))

      (= :map (f :label))
      (let [[k v stop*] (decode-map-entry f bytes after-tag [;path (f :name)] depth)]
        (unless (get into (f :name)) (put into (f :name) @{}))
        (put (get into (f :name)) k v)
        (set i stop*))

      (and (= :repeated (f :label)) (= :length wtype)
           (get-in desc/scalars [(f :type) :packable]))
      # the packed form, whatever this descriptor says it writes
      (let [[len next] (wire/decode-varint bytes after-tag)
            run-stop (+ next len)]
        (when (> run-stop (length bytes))
          (errorf "proto: packed field %q runs past the end" (f :name)))
        (unless (get into (f :name)) (put into (f :name) @[]))
        (var j next)
        (while (< j run-stop)
          (def [v k] (decode-scalar f (f :type) bytes j [;path (f :name)]))
          (array/push (get into (f :name)) v)
          (set j k))
        (set i run-stop))

      (= :repeated (f :label))
      (let [[v next] (decode-value f bytes after-tag [;path (f :name)] depth)]
        (unless (get into (f :name)) (put into (f :name) @[]))
        (array/push (get into (f :name)) v)
        (set i next))

      # a scalar or a message: the last one wins, and two encodings of
      # a nested message merge — which is what makes concatenation the
      # merge operation the format promises
      (let [existing (get into (f :name))
            [v next] (if (and (dictionary? existing) (= :ref (f :type)))
                       (let [[len after] (wire/decode-varint bytes after-tag)
                             run-stop (+ after len)
                             dd (desc/resolve (f :ref) (f :name))]
                         [(decode-fields dd bytes after run-stop existing
                                         [;path (f :name)] (inc depth))
                          run-stop])
                       (decode-value f bytes after-tag [;path (f :name)] depth))]
        (put into (f :name) v)
        # a oneof holds one value: the arrival of a member clears the
        # others, which is the semantics, not a tidying-up
        (when-let [o (f :oneof)]
          (each other (get-in d [:oneofs o])
            (unless (= other (f :name)) (put into other nil))))
        (set i next))))
  (when (> i stop)
    (errorf "proto: %q: a field runs past the end of the message" (d :name)))
  into)

(defn decode-into
  ``Decode `bytes` into an existing message table — protobuf's merge:
  repeated fields accumulate, singular ones take the last value and
  nested messages merge. Concatenating two encodings and decoding the
  result is the same as decoding both in turn, and that is a property
  the format guarantees rather than an accident here.``
  [message bytes into]
  (def d (if (dictionary? message) message (desc/message! message)))
  (decode-fields d bytes 0 (length bytes) into [(d :name)] 0))

(defn decode
  ``Decode `bytes` against a message descriptor or the name of one:

      (codec/decode :example/Order payload)

  Every field of the descriptor is present in the result except the
  ones whose absence is a value (message fields, `optional` fields,
  oneof members). Bytes belonging to unknown field numbers are kept
  under :proto/unknown and ride along on the next encode.``
  [message bytes]
  (decode-into message bytes @{}))
