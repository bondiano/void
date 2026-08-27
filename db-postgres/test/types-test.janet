(import ../test-support/paths)
(import void/db-postgres/types :as types)

# Postgres speaks text on the wire here (see the module header for
# why), so every value in and out is a string somewhere. This file is
# about the edges of that: the values a naive round trip loses.

(defn- dec* [name text &opt opts]
  (types/decode (get types/oids name) text opts))

# -- scalars out ---------------------------------------------------------

(assert (= true (dec* :bool "t")))
(assert (= false (dec* :bool "f")))
(assert (= 42 (dec* :int4 "42")))
(assert (= -7 (dec* :int2 "-7")))
(assert (= 1.5 (dec* :float8 "1.5")))
(assert (nan? (dec* :float8 "NaN")) "the three floats that are not numbers")
(assert (= math/inf (dec* :float8 "Infinity")))
(assert (= (- math/inf) (dec* :float4 "-Infinity")))

(assert (= 9007199254740991 (dec* :int8 "9007199254740991"))
        "an int8 a double can hold comes back as a number")
(def big (dec* :int8 "9223372036854775807"))
(assert (= :core/s64 (type big))
        "and one it cannot comes back as an s64 rather than rounded")
(assert (= "9223372036854775807" (string big)) "intact, to the last digit")

(assert (= "0.10" (dec* :numeric "0.10"))
        "numeric stays a string: it is exact decimal, and a double is not")
(assert (= "$1.00" (dec* :money "$1.00")))

(assert (= "hello" (dec* :text "hello")))
(assert (= "2026-08-27" (dec* :date "2026-08-27"))
        "janet has no date type, so a timestamp comes back as Postgres wrote it")

(assert (deep= @{"k" 1} (dec* :jsonb `{"k": 1}`)))
(assert (= `{"k": 1}` (dec* :jsonb `{"k": 1}` {:json false}))
        ":json false hands the text back — a caller who disagrees should not have to re-encode")

(def bytes (dec* :bytea `\x48656c6c6f`))
(assert (= "Hello" (string bytes)) "bytea in the hex format is a buffer")
(assert (buffer? bytes))
(def [ok err] (protect (types/decode-bytea "Hello")))
(assert (not ok) "and the escape format is refused rather than mangled")
(assert (string/find "bytea_output" err) "with the setting to change")

(assert (= "whatever" (types/decode 999999 "whatever"))
        "an OID this driver does not know decodes to its text, not to an error")

# -- arrays out ----------------------------------------------------------

(assert (deep= @[1 2 3] (types/decode 1007 "{1,2,3}")) "_int4")
(assert (deep= @["a" "b"] (types/decode 1009 `{"a","b"}`)) "quoted elements")
(assert (deep= @[true false] (types/decode 1000 "{t,f}")))
(assert (deep= @[@[1 2] @[3 4]] (types/decode 1007 "{{1,2},{3,4}}")) "nested")
(assert (= "{1,2}" (types/decode 1007 "{1,2}" {:arrays false}))
        ":arrays false leaves the literal alone")

(def with-null (types/decode 1009 "{a,NULL,b}"))
(assert (= 3 (length with-null)) "a NULL element keeps its place")
(assert (nil? (in with-null 1)) "as a nil, which is what it is")
(assert (deep= @["a" "NULL"] (types/decode 1009 `{a,"NULL"}`))
        "a quoted NULL is the four-letter string, not a null")

(assert (deep= @[] (types/decode 1007 "{}")) "the empty array")
(assert (deep= @[1 2 3] (types/decode 1007 "[0:2]={1,2,3}"))
        "an explicit dimension prefix is dropped — janet has nowhere to keep the bounds")
(assert (= "not an array" (types/decode 1009 "not an array"))
        "text that is not a literal is handed through rather than thrown away")

(assert (deep= @[@{"k" 1}] (types/decode 3807 `{"{\"k\": 1}"}`))
        "elements are decoded by the element type, json included")

# -- parameters in -------------------------------------------------------

(assert (nil? (types/encode nil)) "nil is SQL NULL — a nil cell, not a string")
(assert (= "t" (types/encode true)))
(assert (= "f" (types/encode false)))
(assert (= "42" (types/encode 42)) "an integral double has no .0 on it")
(assert (= "1.5" (types/encode 1.5)))
(assert (= "NaN" (types/encode math/nan)))
(assert (= "Infinity" (types/encode math/inf)))
(assert (= "9223372036854775807" (types/encode (int/s64 "9223372036854775807")))
        "an s64 survives as itself")
(assert (= "hello" (types/encode "hello")))
(assert (= "draft" (types/encode :draft)) "a keyword goes in as its name")
(assert (= `\x0102` (types/encode @"\x01\x02")) "a buffer is bytea")
(assert (= `{"k":1}` (string (types/encode {:k 1}))) "a dictionary is json")

(assert (= `{"1","2"}` (types/encode [1 2])) "an array is an array literal")
(assert (= "{NULL}" (types/encode [nil])) "with NULL for a missing element")
(assert (= `{{"a"}}` (types/encode [["a"]]))
        "a nested array is a nested literal — the braces are structure, only the leaves are quoted")

(def [eok eerr] (protect (types/encode (fn [] nil))))
(assert (not eok) "a value with no SQL spelling is refused by name, not guessed at")
(assert (string/find "no SQL spelling" eerr))

(assert (deep= @["1" nil "x"] (types/encode-params [1 nil "x"]))
        "a statement's parameters, in order, nil kept in place")
(assert (deep= @[] (types/encode-params nil)) "no parameters is not an error")

# -- round trips ---------------------------------------------------------

# every value that goes in as a literal must come back as itself: this
# is the property the two halves of this module exist to have
(each v [[1 2 3] ["a,b" `c"d`] [] [[1] [2]]]
  (assert (deep= (map |(if (indexed? $) (map string $) (string $)) v)
                 (map |(if (indexed? $) (map string $) (string $))
                      (types/decode 1009 (types/encode v))))
          (string/format "%q survives a round trip through the array literal" v)))

(print "db-postgres types: ok")
