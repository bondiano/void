### void/proto/json — the proto3 JSON mapping (SPEC.md §5.7,
### ADR-0013).
###
### protobuf defines *two* encodings, and this is the second one. It
### is not "the message, as JSON": it is a specified mapping with
### rules that surprise people who guess, and every one of them is
### here because a client generated from the same `.proto` obeys it:
###
###   **64-bit integers travel as strings.** JSON numbers are doubles,
###   so `{"total": 9007199254740993}` is already wrong by the time a
###   parser has read it. int64, uint64, fixed64, sfixed64 and sint64
###   are quoted — the same honesty ./wire keeps on the binary side.
###
###   **Field names are lowerCamelCase**, and a decoder accepts the
###   original `snake_case` too, because the specification says it
###   must and because a hand-written client will send it.
###
###   **Defaults are omitted** and absence means the default, so an
###   encoder and a decoder round-trip through a smaller object than
###   people expect. `:emit-defaults` is for a human reading the
###   output, not for a peer.
###
###   **bytes are base64**, enums are their names, and a NaN is the
###   string "NaN" — JSON has no such number and pretending otherwise
###   is how a metric becomes null.
###
###   **Four well-known types have a form of their own**: a Timestamp
###   is an RFC 3339 string, a Duration is seconds with an "s", a
###   wrapper is its bare value and an Empty is `{}` (see ./wkt).
###
### An unknown member is an **error** unless `:ignore-unknown` — a
### field name nobody recognises is usually a typo or a version skew,
### and both are worth hearing about at the edge rather than three
### layers in. That is the same call void/rest makes about a body that
### does not match its schema.

(import spork/json)
(import spork/base64)
(import ./wire :as wire)
(import ./descriptor :as desc)
(import ./wkt :as wkt)

(def- big-int-types
  "The integer types JSON carries as strings, because a double cannot
  hold all of them."
  {:int64 true :uint64 true :fixed64 true :sfixed64 true :sint64 true})

(defn- fail [path msg & args]
  (errorf "proto json: %s: %s"
          (if (empty? path) "message" (string/join (map string path) "."))
          (string/format msg ;args)))

# -- numbers -------------------------------------------------------------

(defn- number-out [v]
  (cond
    (not= v v) "NaN"
    (= v math/inf) "Infinity"
    (= v (- math/inf)) "-Infinity"
    v))

(defn- number-in [path v]
  (cond
    (number? v) v
    (bytes? v) (case (string v)
                 "NaN" math/nan
                 "Infinity" math/inf
                 "-Infinity" (- math/inf)
                 (or (scan-number (string v))
                     (fail path "%q is not a number" v)))
    (fail path "%q is not a number" v)))

(defn- integer-in [path v]
  (cond
    (number? v) (do (unless (= v (math/trunc v)) (fail path "%q is not a whole number" v))
                    v)
    (bytes? v) (let [s (string v)]
                 (or (when-let [n (scan-number s)]
                       (when (and (= n (math/trunc n)) (< (math/abs n) wire/max-exact)) n))
                     (let [[ok big] (protect (int/s64 s))]
                       (if ok big (fail path "%q is not a whole number" v)))))
    (wire/integer-value? v) v
    (fail path "%q is not a whole number" v)))

# -- timestamps and durations --------------------------------------------
#
# Written out rather than delegated: Janet has no date type, and the
# two formats are small enough that a dependency would cost more than
# the twenty lines.

(defn- pad [n width]
  (def s (string n))
  (string (string/repeat "0" (max 0 (- width (length s)))) s))

(defn- fraction [nanos]
  (cond
    (zero? nanos) ""
    (zero? (% nanos 1000000)) (string "." (pad (/ nanos 1000000) 3))
    (zero? (% nanos 1000)) (string "." (pad (/ nanos 1000) 6))
    (string "." (pad nanos 9))))

(defn timestamp-out
  "A {:seconds :nanos} Timestamp as the RFC 3339 string the mapping
  asks for, always in UTC and always with a Z."
  [path v]
  (def secs (let [s (get v :seconds 0)]
              (if (number? s) s (fail path "a Timestamp past 2^53 seconds is not a date"))))
  (def nanos (get v :nanos 0))
  (unless (<= 0 nanos 999999999)
    (fail path "a Timestamp's nanos are 0 .. 999999999, got %q" nanos))
  (def d (os/date secs))
  (string (pad (d :year) 4) "-" (pad (inc (d :month)) 2) "-" (pad (inc (d :month-day)) 2)
          "T" (pad (d :hours) 2) ":" (pad (d :minutes) 2) ":" (pad (d :seconds) 2)
          (fraction nanos) "Z"))

(def- rfc3339-peg
  (peg/compile
    ~{:d (range "09")
      :n (/ (<- (some :d)) ,scan-number)
      :frac (/ (<- (* "." (some :d))) ,(fn [s] (string/slice s 1)))
      :offset (+ (* (set "Zz") (constant 0))
                 (/ (* (<- (set "+-")) :n ":" :n)
                    ,(fn [sign h m] (* (if (= sign "-") -1 1) (+ (* 3600 h) (* 60 m))))))
      :main (* :n "-" :n "-" :n (set "Tt ") :n ":" :n ":" :n
               (? :frac) :offset -1)}))

(defn timestamp-in
  "An RFC 3339 string as {:seconds :nanos}. Anything else — a number,
  a date without a zone — is an error: a timestamp whose offset was
  guessed is worse than no timestamp."
  [path v]
  (unless (bytes? v) (fail path "a Timestamp is an RFC 3339 string, got %q" v))
  (def caps (peg/match rfc3339-peg (string v)))
  (unless caps (fail path "%q is not an RFC 3339 timestamp" v))
  (def has-frac (= 8 (length caps)))
  (def [y mo d h mi s] caps)
  (def frac (if has-frac (caps 6) ""))
  (def offset (last caps))
  (def base (os/mktime {:year y :month (dec mo) :month-day (dec d)
                        :hours h :minutes mi :seconds s}))
  (def digits (string/slice (string frac "000000000") 0 9))
  {:seconds (- base offset) :nanos (scan-number digits)})

(defn duration-out
  "A {:seconds :nanos} Duration as the mapping's seconds-with-an-s."
  [path v]
  (def secs (get v :seconds 0))
  (def nanos (get v :nanos 0))
  (unless (number? secs) (fail path "a Duration past 2^53 seconds is not a duration"))
  (def negative (or (< secs 0) (< nanos 0)))
  (string (if (and negative (zero? secs)) "-" "")
          secs (fraction (math/abs nanos)) "s"))

(defn duration-in
  "The mapping's seconds-with-an-s as {:seconds :nanos}."
  [path v]
  (unless (bytes? v) (fail path "a Duration is a string like \"1.5s\", got %q" v))
  (def s (string v))
  (unless (string/has-suffix? "s" s) (fail path "%q does not end in \"s\"" s))
  (def body (string/slice s 0 -2))
  (def n (scan-number body))
  (unless n (fail path "%q is not a duration" s))
  (def whole (if (< n 0) (math/ceil n) (math/floor n)))
  (def dot (string/find "." body))
  (def digits (if dot
                (string/slice (string (string/slice body (inc dot)) "000000000") 0 9)
                "0"))
  (def nanos (scan-number digits))
  {:seconds whole :nanos (if (< n 0) (- nanos) nanos)})

# -- the mapping ---------------------------------------------------------

(varfn message-out [d value opts path] nil)
(varfn message-in [d value opts path] nil)

(defn- scalar-out [path f t v opts]
  (case t
    :bool (truthy? v)
    :string (string v)
    :bytes (base64/encode (string v))
    :double (number-out v)
    :float (number-out v)
    (if (big-int-types t)
      # a 64-bit integer is a string, whether it needed to be or not:
      # a peer that special-cased "only when it is big" would send two
      # shapes for one field
      (string v)
      (if (number? v) v (int/to-number v)))))

(defn- value-out [path f v opts]
  (if (= :ref (f :type))
    (let [d (desc/resolve (f :ref) (f :name))]
      (if (= :enum (d :kind))
        (cond
          (opts :enums-as-numbers) (if (number? v) v (get-in d [:values v] 0))
          (keyword? v) (string v)
          (get-in d [:by-number v] v))
        (message-out d v opts path)))
    (scalar-out path f (f :type) v opts)))

(defn- map-key-out [path f k]
  (case (get-in f [:key :type])
    :string (string k)
    :bool (if k "true" "false")
    (string k)))

(defn- map-key-in [path f k]
  (case (get-in f [:key :type])
    :string (string k)
    :bool (case (string k)
            "true" true
            "false" false
            (fail path "%q is not a boolean map key" k))
    (integer-in path k)))

(varfn message-out [d value opts path]
  (unless (dictionary? value)
    (fail path "%q is not a message" value))
  (def pname (d :proto-name))
  (when-let [why (wkt/unsupported pname)]
    (fail path "%s has a JSON form of its own that void/proto does not write — %s" pname why))
  (cond
    (= "google.protobuf.Timestamp" pname) (timestamp-out path value)
    (= "google.protobuf.Duration" pname) (duration-out path value)
    (wkt/wrappers pname)
    (let [f (get-in d [:by-name :value])
          v (get value :value)]
      (if (nil? v) nil (value-out path f v opts)))
    (do
      (def out @{})
      (each f (d :fields)
        # with :emit-defaults a field nobody set still has a value —
        # its proto3 default — and that is exactly what a human
        # reading the output came for
        (def v (let [given (get value (f :name))]
                 (if (and (nil? given) (opts :emit-defaults)
                          (not (desc/explicit-presence? f)))
                   (desc/default-value f)
                   given)))
        (def key (if (opts :proto-names) (string (f :name)) (f :json-name)))
        (def fpath [;path (f :name)])
        (cond
          (nil? v) nil

          (= :repeated (f :label))
          (unless (and (empty? v) (not (opts :emit-defaults)))
            (put out key (map |(value-out fpath f $ opts) v)))

          (= :map (f :label))
          (unless (and (empty? v) (not (opts :emit-defaults)))
            (def entries @{})
            (eachp [k item] v
              (put entries (map-key-out fpath f k)
                   (value-out fpath (merge (f :value) {:name (f :name)}) item opts)))
            (put out key entries))

          (and (not (opts :emit-defaults))
               (not (desc/explicit-presence? f))
               (= v (desc/default-value f)))
          nil

          (put out key (value-out fpath f v opts))))
      out)))

(defn- scalar-in [path f t v]
  (case t
    :bool (cond
            (boolean? v) v
            (bytes? v) (case (string v) "true" true "false" false
                         (fail path "%q is not a boolean" v))
            (fail path "%q is not a boolean" v))
    :string (if (bytes? v) (string v) (fail path "%q is not a string" v))
    :bytes (if (bytes? v)
             (let [[ok out] (protect (base64/decode (string v)))]
               (if ok (string out) (fail path "%q is not base64" v)))
             (fail path "%q is not base64-encoded bytes" v))
    :double (number-in path v)
    :float (number-in path v)
    (integer-in path v)))

(defn- value-in [path f v opts]
  (if (= :ref (f :type))
    (let [d (desc/resolve (f :ref) (f :name))]
      (if (= :enum (d :kind))
        (cond
          (bytes? v) (let [k (keyword v)]
                       (if (get-in d [:values k])
                         k
                         (fail path "%q is not a value of %q (it has %s)"
                               v (d :name)
                               (string/join (map string (sorted (keys (d :values)))) " "))))
          (number? v) (get-in d [:by-number v] v)
          (fail path "%q is neither the name nor the number of a %q" v (d :name)))
        (message-in d v opts path)))
    (scalar-in path f (f :type) v)))

(varfn message-in [d value opts path]
  (def pname (d :proto-name))
  (when-let [why (wkt/unsupported pname)]
    (fail path "%s has a JSON form of its own that void/proto does not read — %s" pname why))
  (cond
    (= :null value) nil
    (= "google.protobuf.Timestamp" pname) (timestamp-in path value)
    (= "google.protobuf.Duration" pname) (duration-in path value)
    (wkt/wrappers pname)
    (if (nil? value)
      nil
      @{:value (value-in path (get-in d [:by-name :value]) value opts)})
    (do
      (unless (dictionary? value)
        (fail path "%q is not an object" value))
      (def out @{})
      (eachp [k v] value
        (def f (get-in d [:by-json (string k)]))
        (cond
          (nil? f)
          (unless (opts :ignore-unknown)
            (fail path "%q is not a field of %q (it has %s)"
                  k (d :name)
                  (string/join (sorted (map |($ :json-name) (d :fields))) " ")))

          # JSON null is "the default", which for a message field and
          # for an explicitly-present one means absent. spork/json
          # decodes null to the keyword :null, so that is what "no
          # value" looks like here
          (or (nil? v) (= :null v)) nil

          (= :repeated (f :label))
          (do
            (unless (indexed? v) (fail [;path (f :name)] "%q is not an array" v))
            (put out (f :name) (map |(value-in [;path (f :name)] f $ opts) v)))

          (= :map (f :label))
          (do
            (unless (dictionary? v) (fail [;path (f :name)] "%q is not an object" v))
            (def entries @{})
            (eachp [mk mv] v
              (put entries (map-key-in [;path (f :name)] f mk)
                   (value-in [;path (f :name)] (merge (f :value) {:name (f :name)}) mv opts)))
            (put out (f :name) entries))

          (put out (f :name) (value-in [;path (f :name)] f v opts))))
      # everything the object did not mention is its proto3 default,
      # exactly as on the binary side
      (each f (d :fields)
        (unless (or (desc/explicit-presence? f) (not (nil? (get out (f :name)))))
          (put out (f :name) (desc/default-value f))))
      out)))

(defn- options [opts]
  (merge {:emit-defaults false :proto-names false
          :ignore-unknown false :enums-as-numbers false}
         (or opts {})))

(defn to-json
  ``A message value as plain data ready for `json/encode`: string
  keys, the mapping's spelling of every scalar.

  opts: :emit-defaults (write fields equal to their default),
  :proto-names (the `.proto` spelling instead of lowerCamelCase),
  :enums-as-numbers.``
  [message value &opt opts]
  (def d (if (dictionary? message) message (desc/message! message)))
  (message-out d value (options opts) []))

(defn from-json
  ``Plain data (as `json/decode` produces it, string keys) as a
  message value.

  opts: :ignore-unknown (a member this message does not declare is
  skipped instead of refused).``
  [message value &opt opts]
  (def d (if (dictionary? message) message (desc/message! message)))
  (message-in d value (options opts) []))

(defn encode
  "A message value as a JSON string."
  [message value &opt opts]
  (json/encode (to-json message value opts)))

(defn decode
  "A JSON string as a message value."
  [message text &opt opts]
  (def [ok data] (protect (json/decode text)))
  (unless ok
    (errorf "proto json: %q is not JSON: %s" (string message) (describe data)))
  (from-json message data opts))
