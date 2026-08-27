### void/db-postgres/types — Postgres values in and out, in the text
### protocol (SPEC.md §5.10, ROADMAP 2.2).
###
### Results are requested in text format, not binary. Binary is
### faster for a handful of types and a per-type reimplementation of
### Postgres' own output functions for everything else; text is what
### psql sees, what every Postgres release keeps stable, and what a
### driver can decode by OID with a lookup table. The cost is a
### round of parsing per value, and it is not where a database call
### spends its time.
###
### What a column comes back as:
###
###   bool                       true / false
###   int2 int4 oid              number
###   int8                       number, or an int/s64 past 2^53 —
###                              a bigint that cannot survive a double
###                              is returned intact rather than rounded
###   float4 float8              number (nan / inf included)
###   numeric money              STRING. Postgres' numeric is exact
###                              decimal; handing it back as a double
###                              would quietly lose the property it
###                              exists for. Callers that want a number
###                              can scan-number it and accept that.
###   text varchar char name     string
###   bytea                      buffer (the \x hex form, decoded)
###   json jsonb                 decoded janet data
###   date time timestamp        string, as Postgres formatted it —
###   timestamptz interval       janet has no date type, and a string
###                              is at least lossless
###   uuid inet macaddr xml ...   string
###   anything[]                 array, elements decoded as above
###   an OID we do not know      string
###
### and what a parameter goes in as: nil is SQL NULL, booleans are
### t/f, numbers and s64/u64 are decimal, strings/keywords/symbols are
### themselves, buffers are bytea hex, dictionaries are JSON, and
### arrays and tuples are Postgres array literals. Nothing else has an
### obvious spelling, so nothing else is guessed at.

(import spork/json)

# -- OIDs ----------------------------------------------------------------

(def oids
  "The type OIDs this module knows by name (pg_type.oid)."
  {:bool 16 :bytea 17 :char 18 :name 19 :int8 20 :int2 21 :int4 23
   :text 25 :oid 26 :json 114 :xml 142 :point 600 :float4 700 :float8 701
   :money 790 :macaddr 829 :inet 869 :cidr 650 :bpchar 1042 :varchar 1043
   :date 1082 :time 1083 :timestamp 1114 :timestamptz 1184 :interval 1186
   :timetz 1266 :bit 1560 :varbit 1562 :numeric 1700 :uuid 2950 :jsonb 3802})

(def array-element
  ``Array OID -> element OID, for the array types worth naming. An
  array of something not in here still decodes — as an array of
  strings, since that is what an unknown element type decodes to
  anyway.``
  {1000 16    # _bool
   1001 17    # _bytea
   1002 18 1003 19
   1005 21    # _int2
   1007 23    # _int4
   1016 20    # _int8
   1009 25    # _text
   1014 1042 1015 1043
   1021 700 1022 701
   1028 26
   199 114 3807 3802
   1182 1082 1183 1083 1115 1114 1185 1184 1187 1186
   1231 1700 2951 2950 791 790
   1041 869 651 650 1040 829
   143 142 1561 1560 1563 1562})

# -- scalars in ----------------------------------------------------------

(def- max-exact-int
  "2^53 — past this a double no longer represents every integer, and
  an int8 has to come back as an int/s64 to survive the trip."
  9007199254740992)

(defn- decode-int8 [s]
  (def n (scan-number s))
  (if (and n (< (math/abs n) max-exact-int)) n (int/s64 s)))

(defn- decode-float [s]
  (case s
    "NaN" math/nan
    "Infinity" math/inf
    "-Infinity" (- math/inf)
    (scan-number s)))

(def- hex-digits
  (let [t @{}]
    (eachp [i c] "0123456789abcdef" (put t c i))
    (eachp [i c] "0123456789ABCDEF" (put t c i))
    (table/to-struct t)))

(defn decode-bytea
  ``Postgres' hex output format (`\\x48656c6c6f`) as a buffer. The
  ancient escape format is not produced by any server since 9.0
  unless bytea_output is turned back, and a caller who does that gets
  the raw string and an explanation.``
  [s]
  (unless (string/has-prefix? "\\x" s)
    (errorf (string "postgres: bytea in the escape format (%q...) — this driver "
                    "reads the hex format; leave bytea_output at 'hex'")
            (string/slice s 0 (min 8 (length s)))))
  (def body (string/slice s 2))
  (def out (buffer/new (div (length body) 2)))
  (var i 0)
  (while (< i (length body))
    (def hi (get hex-digits (body i)))
    (def lo (get hex-digits (body (inc i))))
    (when (or (nil? hi) (nil? lo))
      (errorf "postgres: %q is not hex-encoded bytea" s))
    (buffer/push-byte out (+ (* 16 hi) lo))
    (+= i 2))
  out)

(def- scalar-decoders
  {16 (fn [s] (= "t" s))
   17 decode-bytea
   20 decode-int8
   21 scan-number
   23 scan-number
   26 scan-number
   700 decode-float
   701 decode-float
   114 json/decode
   3802 json/decode})

# -- array literals ------------------------------------------------------

(def- null-marker :void.db-postgres/null)

(defn- unquoted [s]
  (if (= "NULL" (string/ascii-upper s)) null-marker s))

(def- array-peg
  ``Postgres array output: {a,b,NULL}, elements quoted when they
  contain a delimiter or look like NULL, nested for more dimensions.
  An explicit dimension prefix ([1:3]={...}, from an array whose
  lower bound is not 1) is matched and dropped — the values are still
  the values, and janet has no place to keep the bounds.``
  (peg/compile
    ~{:main (* (? :dims) :array -1)
      :dims (* (some (* "[" (some (+ :d ":")) "]")) "=")
      :d (range "09" "--")
      :array (group (* "{" (? (* :elem (any (* "," :elem)))) "}"))
      :elem (+ :array :quoted :bare)
      :quoted (* `"`
                 (% (any (+ (* "\\" (<- 1))
                            (<- (if-not (set `"\`) 1)))))
                 `"`)
      # `some`, not `any`: an element that matches the empty string
      # matches it inside "{}" too, and the empty array would come back
      # as an array of one empty string. Postgres spells a genuinely
      # empty element "" — the :quoted branch — so nothing is lost.
      :bare (/ (<- (some (if-not (set ",}") 1))) ,unquoted)}))

(defn parse-array
  ``A Postgres array literal as nested janet arrays, with
  `null-marker` where an element is NULL (janet arrays cannot hold
  nil, and a hole would be indistinguishable from a short array).
  Returns nil when the string is not an array literal — the caller
  falls back to handing the raw text through rather than throwing
  away a value it could not classify.``
  [s]
  (when-let [m (peg/match array-peg s)]
    (first m)))

# -- decoding ------------------------------------------------------------

(defn- decode-elements [x decoder]
  (cond
    (= null-marker x) nil
    (array? x) (map |(decode-elements $ decoder) x)
    (decoder x)))

(defn decoder-for
  ``The (fn [text] value) for a column OID, honouring the options:

    :json    false leaves json/jsonb as the text Postgres sent
    :arrays  false leaves array columns as their literal

  Both exist because a decoded value is a *guess* about what the
  caller wanted, and a caller who disagrees should not have to
  re-encode to get the original back.``
  [oid &opt opts]
  (default opts {})
  (def json? (not= false (get opts :json)))
  (def arrays? (not= false (get opts :arrays)))
  (def element (get array-element oid))
  (cond
    (and (not json?) (or (= oid (oids :json)) (= oid (oids :jsonb))))
    string

    (and arrays? element)
    (let [inner (decoder-for element opts)]
      (fn decode-array [s]
        (if-let [parsed (parse-array s)]
          (decode-elements parsed inner)
          s)))

    (or (get scalar-decoders oid) string)))

(defn decode
  "One text value from Postgres, by column OID."
  [oid text &opt opts]
  ((decoder-for oid opts) text))

# -- encoding ------------------------------------------------------------

(defn- number->string [n]
  (cond
    (nan? n) "NaN"
    (= n math/inf) "Infinity"
    (= n (- math/inf)) "-Infinity"
    (and (= n (math/trunc n)) (< (math/abs n) max-exact-int))
    (string/format "%d" n)
    # 17 significant digits round-trip a double exactly
    (string/format "%.17g" n)))

(defn encode-bytea
  "A buffer as the bytea hex literal Postgres parses back to it."
  [b]
  (def out (buffer/new (+ 2 (* 2 (length b)))))
  (buffer/push-string out "\\x")
  (each byte b (buffer/push-string out (string/format "%02x" byte)))
  (string out))

(defn- array-element-literal [s]
  # every non-NULL element is quoted: Postgres accepts a quoted
  # element for any element type, and quoting unconditionally means
  # never having to decide whether this particular text needed it
  (def out (buffer/new (+ 2 (length s))))
  (buffer/push-byte out 34)
  (each c s
    (when (or (= c 34) (= c 92)) (buffer/push-byte out 92))
    (buffer/push-byte out c))
  (buffer/push-byte out 34)
  (string out))

(varfn encode
  "Declared ahead of `array-literal`, which needs it for elements."
  [_] nil)

(defn array-literal
  "A janet array or tuple as a Postgres array literal."
  [xs]
  (string "{"
          (string/join
            (map (fn [x]
                   (cond
                     (nil? x) "NULL"
                     (indexed? x) (array-literal x)
                     (array-element-literal (encode x))))
                 xs)
            ",")
          "}"))

(varfn encode
  ``One parameter value as the text Postgres will parse. nil means
  SQL NULL and is returned as nil — the caller writes a NULL pointer
  into the paramValues cell rather than a string.

  A value with no obvious text spelling is refused by name: guessing
  produces a row that is wrong in a way nobody notices for months.``
  [v]
  (cond
    (nil? v) nil
    (boolean? v) (if v "t" "f")
    (number? v) (number->string v)
    (string? v) v
    (or (keyword? v) (symbol? v)) (string v)
    # a buffer is bytes, and bytes in Postgres are bytea; text that
    # happens to live in a buffer should be (string ...)-ed first
    (buffer? v) (encode-bytea v)
    (indexed? v) (array-literal v)
    # json/encode hands back a buffer; a parameter has to be a string,
    # since its bytes are read through a pointer that must stay put
    (dictionary? v) (string (json/encode v))
    (or (= :core/s64 (type v)) (= :core/u64 (type v))) (string v)
    (errorf (string "postgres: %q has no SQL spelling — pass a string, number, "
                    "boolean, buffer (bytea), array (an array literal), "
                    "dictionary (json) or nil")
            v)))

(defn encode-params
  "Every parameter of a statement, in order."
  [params]
  (map encode (or params [])))
