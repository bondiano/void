(import ../test-support/paths)
(import void/proto :as proto)
(import spork/json)

(proto/defenum :j/Kind {:KIND_UNSET 0 :KIND_ONE 1})
(proto/defmessage :j/Inner {:inner_value [1 :string]})
(proto/defmessage :j/Msg
  {:small [1 :int32] :big [2 :int64] :unsigned [3 :uint64]
   :name [4 :string] :blob [5 :bytes] :flag [6 :bool] :amount [7 :double]
   :kind [8 :j/Kind] :inner [9 :j/Inner] :list [10 :repeated :int32]
   :tags [11 :map :string :string] :maybe [12 :optional :int32]
   :renamed [13 :string {:json-name "aka"}]
   :at [14 :google.protobuf/Timestamp] :took [15 :google.protobuf/Duration]
   :wrapped [16 :google.protobuf/Int32Value]})

(defn- j [v &opt opts] (proto/to-json :j/Msg v opts))

# -- the rules that surprise people --------------------------------------

(assert (= "42" (get (j {:big 42}) "big"))
        "a 64-bit integer travels as a string, because a JSON number is a double")
(assert (= 42 (get (j {:small 42}) "small")) "a 32-bit one does not")
(assert (= "18446744073709551615" (get (j {:unsigned (int/u64 "18446744073709551615")}) "unsigned")))
(assert (= "AAE=" (get (j {:blob "\x00\x01"}) "blob")) "bytes are base64")
(assert (= "KIND_ONE" (get (j {:kind :KIND_ONE}) "kind")) "an enum is its name")
(assert (= 1 (get (j {:kind :KIND_ONE} {:enums-as-numbers true}) "kind")))
(assert (= "innerValue" (first (keys (get (j {:inner {:inner_value "x"}}) "inner"))))
        "field names are lowerCamelCase")
(assert (= "inner_value" (first (keys (get (j {:inner {:inner_value "x"}} {:proto-names true})
                                           "inner"))))
        "unless the caller asked for the .proto spelling")
(assert (= "x" (get (j {:renamed "x"}) "aka")) "json_name wins over both")

(assert (empty? (j {})) "a message of defaults is an empty object")
(assert (empty? (j {:small 0 :name "" :list [] :kind :KIND_UNSET})))
(assert (not (empty? (j {} {:emit-defaults true}))) "unless somebody wants to read it")
(assert (= 0 (get (j {} {:emit-defaults true}) "small")))
(assert (nil? (get (j {} {:emit-defaults true}) "inner"))
        "and even then an absent message stays absent — absence is its value")
(assert (= 0 (get (j {:maybe 0}) "maybe")) "an `optional` zero is written")

(assert (= "NaN" (get (j {:amount math/nan}) "amount")))
(assert (= "Infinity" (get (j {:amount math/inf}) "amount"))
        "JSON has no infinity, and the mapping says what to write instead")

# -- back again ------------------------------------------------------------

(defn- back [text] (proto/decode-json :j/Msg text))

(assert (= 42 ((back `{"big":"42"}`) :big)) "a quoted 64-bit integer reads back as a number")
(assert (= 42 ((back `{"big":42}`) :big)) "and so does an unquoted one, which is also legal")
(assert (= 0 (compare (int/s64 "9007199254740993") ((back `{"big":"9007199254740993"}`) :big)))
        "one that a double cannot hold comes back as an int/s64")
(assert (= 7 ((back `{"small":7}`) :small)))
(assert (= "\x00\x01" ((back `{"blob":"AAE="}`) :blob)))
(assert (= :KIND_ONE ((back `{"kind":"KIND_ONE"}`) :kind)))
(assert (= :KIND_ONE ((back `{"kind":1}`) :kind)) "a number names an enum value too")
(assert (= "x" (get-in (back `{"inner":{"inner_value":"x"}}`) [:inner :inner_value]))
        "a decoder accepts the .proto spelling as well — the specification requires it")
(assert (= "x" (get-in (back `{"inner":{"innerValue":"x"}}`) [:inner :inner_value])))
(assert (nil? ((back `{"maybe":null}`) :maybe)) "null is absence")
(assert (= 0 ((back `{}`) :small)) "and everything unmentioned is its default")
(assert (deep= @{"a" "b"} ((back `{"tags":{"a":"b"}}`) :tags)))

(def [ok err] (protect (back `{"nope":1}`)))
(assert (not ok))
(assert (string/find "nope" err)
        "an unknown member is an error naming it — version skew is worth hearing about")
(assert (proto/decode-json :j/Msg `{"nope":1}` {:ignore-unknown true})
        "unless the caller says otherwise")

(assert (not (first (protect (back `{"small":"seven"}`)))))
(assert (not (first (protect (back `{"list":5}`)))) "a repeated field is an array")

# -- the four well-known types that have a form of their own --------------

(assert (= "1970-01-12T13:46:40.500Z" (get (j {:at {:seconds 1000000 :nanos 500000000}}) "at"))
        "a Timestamp is an RFC 3339 string, in UTC, with the fraction it needs")
(assert (= "1970-01-01T00:00:00Z" (get (j {:at {:seconds 0 :nanos 0}}) "at")))
(assert (= "1969-12-31T23:59:59Z" (get (j {:at {:seconds -1}}) "at")) "and dates before it work")
(assert (deep= {:seconds 0 :nanos 0} ((back `{"at":"1970-01-01T00:00:00Z"}`) :at)))
(assert (= 1788080400 (get-in (back `{"at":"2026-08-30T12:00:00+03:00"}`) [:at :seconds]))
        "an offset is honoured rather than ignored")
(assert (= 500000000 (get-in (back `{"at":"2026-08-30T12:00:00.5Z"}`) [:at :nanos])))
(assert (not (first (protect (back `{"at":"2026-08-30"}`))))
        "a date with no time and no zone is refused rather than guessed at")

(assert (= "1.500s" (get (j {:took {:seconds 1 :nanos 500000000}}) "took"))
        "a Duration is written with 0, 3, 6 or 9 fractional digits — the mapping's own rule")
(assert (= "-3s" (get (j {:took {:seconds -3}}) "took")))
(assert (deep= {:seconds 1 :nanos 500000000} ((back `{"took":"1.5s"}`) :took))
        "and read with however many a peer sent")
(assert (= -3 (get-in (back `{"took":"-3s"}`) [:took :seconds])))

(assert (= 5 (get (j {:wrapped {:value 5}}) "wrapped")) "a wrapper is its bare value")
(assert (= 5 (get-in (back `{"wrapped":5}`) [:wrapped :value])))
(assert (nil? (get (j {}) "wrapped")) "and an unset one is absent, which is why it exists")

# -- the string form is the data form encoded -----------------------------

(def value {:small 1 :big 2 :name "x" :list [1 2] :inner {:inner_value "y"}})
(assert (deep= (json/decode (proto/encode-json :j/Msg value))
               (json/decode (json/encode (proto/to-json :j/Msg value))))
        "encode is to-json plus json/encode, and nothing else")
(assert (deep= (proto/decode-json :j/Msg (proto/encode-json :j/Msg value))
               (proto/from-json :j/Msg (proto/to-json :j/Msg value)))
        "and the round trip through either is the same round trip")

(print "json ok")
