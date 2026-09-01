### void/db-mysql/types — MySQL values in and out (ADR-0033,
### SPEC.md §5.10).
###
### The text protocol, for the reason void/db-postgres/types gives and
### one more. The reason it shares: text is what the `mysql` client
### sees, what every release keeps stable, and what a driver can decode
### with a lookup table on the column type. The reason it does not: the
### binary protocol here is `mysql_stmt_*`, and reaching it means laying
### out MYSQL_BIND — a struct whose *tail* MySQL and MariaDB have
### genuinely diverged on. A driver with no compile step cannot check a
### struct layout, and a wrong one is a segfault rather than an error.
### ADR-0033 is where that trade is written down.
###
### Going in, that has a consequence with a name: a parameter is not
### sent out of band, it is rendered into the statement. Which is why
### `interpolate` below is written the way it is —
###
###   * every value becomes a literal through `literal`, which quotes
###     and escapes through the connection's own
###     `mysql_real_escape_string`; nothing is formatted by hand and
###     nothing is concatenated by a caller
###   * `?` is only a placeholder where SQL says it is one. The scanner
###     skips string literals, both quoting styles of identifier and
###     all three comment forms, so a `?` inside `'why?'` stays inside
###     it
###   * the placeholder count has to equal the parameter count, or the
###     statement does not run. A mismatch is the shape every
###     interpolation bug has, and it is cheap to refuse
###
### What a column comes back as:
###
###   tinyint(1)                 true / false — see `decode-tiny`
###   tinyint smallint int       number
###   mediumint year
###   bigint                     number, or an int/s64 (int/u64 when
###                              the column is UNSIGNED) past 2^53 — a
###                              bigint that cannot survive a double is
###                              returned intact rather than rounded
###   float double               number
###   decimal numeric            STRING. MySQL's DECIMAL is exact;
###                              handing it back as a double would
###                              quietly lose the property it exists
###                              for. Callers that want a number can
###                              scan-number it and accept that
###   char varchar text enum set string
###   binary varbinary blob      buffer — told apart from the line
###                              above by the BINARY flag, since each
###                              pair shares one type code
###   json                       decoded janet data on MySQL. NOT on
###                              MariaDB, where JSON is an alias for
###                              LONGTEXT and the column arrives as
###                              text; pass it through json/decode
###                              yourself there
###   bit                        number (big-endian, as MySQL sends it)
###   date time datetime         string, as MySQL formatted it — janet
###   timestamp                  has no date type, and a string is at
###                              least lossless
###   NULL                       absent from the row, the way every
###                              void driver reports it
###
### and what a parameter goes in as: nil is NULL, booleans are TRUE and
### FALSE, numbers are decimal, strings/keywords/symbols are quoted
### text, buffers are quoted binary, dictionaries are JSON, and arrays
### are refused — MySQL has no array type and a silent JSON array would
### be a guess. Nothing else has an obvious spelling, so nothing else
### is guessed at.

(import spork/json)
(import ./libmysql :as my)

# -- decoding ------------------------------------------------------------

(def- max-exact-int
  "2^53 — past this a double no longer represents every integer, and a
  bigint has to come back as an int/s64 to survive the trip."
  9007199254740992)

(defn- decode-bigint [s unsigned?]
  (def n (scan-number s))
  (cond
    (and n (< (math/abs n) max-exact-int)) n
    unsigned? (int/u64 s)
    (int/s64 s)))

(defn decode-bit
  ``A BIT(n) column, which the text protocol sends as the raw bytes
  big-endian rather than as digits. Returned as a number while it
  fits one, and as an int/u64 past that — the same rule bigint gets.``
  [s]
  (var n (int/u64 0))
  (each byte s (set n (+ (* n 256) byte)))
  (if (< n (int/u64 max-exact-int)) (scan-number (string n)) n))

(defn- binary? [fld]
  (not (zero? (band (get fld :flags 0) my/BINARY-FLAG))))

(defn- unsigned? [fld]
  (not (zero? (band (get fld :flags 0) my/UNSIGNED-FLAG))))

(defn decode-tiny
  ``TINYINT, and the one heuristic in this file. MySQL's BOOLEAN is an
  alias for TINYINT(1) and the server keeps no record of which word
  the migration used, so `true` and `1` are the same column and no
  driver can tell them apart from the wire. Every MySQL client library
  worth using resolves it the same way — display width 1 means a
  boolean — and this one does too, with the difference that it says so
  and that [:db-mysql :booleans] false turns it off.

  A column declared TINYINT(1) to hold -3..3 is the case the heuristic
  gets wrong. Declare it TINYINT (no width, which is width 4) and the
  question does not arise.``
  [s fld booleans?]
  (if (and booleans? (= 1 (get fld :length)))
    (not= "0" s)
    (scan-number s)))

(defn decoder-for
  ``The function that turns one column's text into a janet value, for
  a field descriptor (`libmysql/field`) and the decoding options
  {:json true :booleans true}.``
  [fld &opt opts]
  (default opts {})
  (def json? (not= false (get opts :json)))
  (def booleans? (not= false (get opts :booleans)))
  (def bin? (binary? fld))
  (case (get fld :type)
    :tiny (fn [s] (decode-tiny s fld booleans?))
    :short scan-number
    :long scan-number
    :int24 scan-number
    :year scan-number
    :longlong (let [u (unsigned? fld)] (fn [s] (decode-bigint s u)))
    :float scan-number
    :double scan-number
    :bit decode-bit
    :json (if json? json/decode string)
    # exact decimal stays exact: see the header
    :decimal string
    :newdecimal string
    # each of these type codes covers a text column and a binary one,
    # and the BINARY flag is the only thing that tells them apart
    :string (if bin? buffer string)
    :var-string (if bin? buffer string)
    :varchar (if bin? buffer string)
    :blob (if bin? buffer string)
    :tiny-blob (if bin? buffer string)
    :medium-blob (if bin? buffer string)
    :long-blob (if bin? buffer string)
    :geometry buffer
    string))

(defn decode
  "One text value from MySQL, by field descriptor."
  [fld text &opt opts]
  ((decoder-for fld opts) text))

# -- encoding ------------------------------------------------------------

(defn- number->literal [n]
  (cond
    # MySQL has no NaN and no infinity, and a column that received one
    # would hold something else — a rounded maximum, or nothing
    (nan? n) (error "mysql: NaN has no SQL spelling")
    (or (= n math/inf) (= n (- math/inf)))
    (error "mysql: an infinity has no SQL spelling")
    (and (= n (math/trunc n)) (< (math/abs n) max-exact-int))
    (string/format "%d" n)
    # 17 significant digits round-trip a double exactly
    (string/format "%.17g" n)))

(defn literal
  ``One parameter as the SQL literal MySQL will parse. `escape` is
  (fn [bytes] escaped) — `mysql_real_escape_string` bound to the
  connection, which is what makes the escaping correct rather than
  plausible: it is the connection that knows the character set, and a
  multi-byte charset is where a hand-written escaper gets it wrong.

  A value with no obvious spelling is refused by name. Guessing
  produces a row that is wrong in a way nobody notices for months.``
  [v escape]
  (defn quoted [bytes] (string "'" (escape bytes) "'"))
  (cond
    (nil? v) "NULL"
    (boolean? v) (if v "TRUE" "FALSE")
    (number? v) (number->literal v)
    (string? v) (quoted v)
    (or (keyword? v) (symbol? v)) (quoted (string v))
    # a buffer is bytes, and it is quoted exactly like text — the
    # escape is binary-safe and the column decides how to read it
    (buffer? v) (quoted v)
    (or (= :core/s64 (type v)) (= :core/u64 (type v))) (string v)
    (dictionary? v) (quoted (string (json/encode v)))
    (indexed? v)
    (errorf (string "mysql: %q is an array, and MySQL has no array type — "
                    "pass a JSON dictionary, or one parameter per element")
            v)
    (errorf (string "mysql: %q has no SQL spelling — pass a string, number, "
                    "boolean, buffer, dictionary (json) or nil")
            v)))

# -- placeholders --------------------------------------------------------

(def- quote-byte 39)      # '
(def- dquote-byte 34)     # "
(def- backtick-byte 96)   # `
(def- backslash-byte 92)  # \
(def- question-byte 63)   # ?
(def- newline-byte 10)
(def- dash-byte 45)       # -
(def- hash-byte 35)       # #
(def- slash-byte 47)      # /
(def- star-byte 42)       # *

(defn- skip-quoted
  ``Past the closing delimiter of a literal or a quoted identifier
  that starts at `i`. Both escape forms are honoured: a doubled
  delimiter, and — for the two string quotes — a backslash, which
  MySQL treats as an escape everywhere except under
  NO_BACKSLASH_ESCAPES. Skipping one there costs nothing, because
  ./worker refuses that mode outright.``
  [sql i delim backslashes?]
  (var j (inc i))
  (var done false)
  (while (and (not done) (< j (length sql)))
    (def c (sql j))
    (cond
      (and backslashes? (= c backslash-byte)) (+= j 2)
      (= c delim)
      (if (= delim (get sql (inc j)))
        (+= j 2)                       # a doubled delimiter is one byte of data
        (do (set done true) (++ j)))
      (++ j)))
  (unless done
    (errorf "mysql: unterminated %s literal in the statement"
            (cond (= delim quote-byte) "'" (= delim dquote-byte) `"` "`")))
  j)

(defn- skip-line-comment [sql i]
  (var j i)
  (while (and (< j (length sql)) (not= newline-byte (sql j))) (++ j))
  j)

(defn- skip-block-comment [sql i]
  (var j (+ i 2))
  (while (and (< j (dec (length sql)))
              (not (and (= star-byte (sql j)) (= slash-byte (sql (inc j))))))
    (++ j))
  (min (length sql) (+ j 2)))

(defn placeholder-positions
  ``Where the `?` placeholders of a statement are — the ones SQL reads
  as placeholders, which is why this is a scanner and not
  `string/find-all`. A `?` inside a literal, inside a quoted
  identifier or inside any of MySQL's three comment forms (`-- `, `#`
  and `/* */`) is data, and data is left alone.``
  [sql]
  (def out @[])
  (var i 0)
  (def n (length sql))
  (while (< i n)
    (def c (sql i))
    (cond
      (= c question-byte) (do (array/push out i) (++ i))
      (= c quote-byte) (set i (skip-quoted sql i quote-byte true))
      (= c dquote-byte) (set i (skip-quoted sql i dquote-byte true))
      (= c backtick-byte) (set i (skip-quoted sql i backtick-byte false))
      # `--` is a comment only when a whitespace follows it, which is
      # what keeps `a--1` (a minus a negative one) arithmetic
      (and (= c dash-byte) (= dash-byte (get sql (inc i)))
           (let [after (get sql (+ i 2))]
             (or (nil? after) (<= after 32))))
      (set i (skip-line-comment sql i))
      (= c hash-byte) (set i (skip-line-comment sql i))
      (and (= c slash-byte) (= star-byte (get sql (inc i))))
      (set i (skip-block-comment sql i))
      (++ i)))
  out)

(defn interpolate
  ``A statement and its parameters as the one string MySQL is sent.
  Every parameter goes through `literal`, so nothing reaches the
  server as anything but a quoted, escaped literal or a number.

  The counts have to match. A statement with more placeholders than
  parameters is the bug this refuses to run — silently binding NULL
  to the rest is how an interpolating driver corrupts a table.``
  [sql params escape]
  (def ps (or params []))
  (def spots (placeholder-positions sql))
  (unless (= (length spots) (length ps))
    (errorf (string "mysql: the statement has %d placeholder%s and %d "
                    "parameter%s were passed")
            (length spots) (if (= 1 (length spots)) "" "s")
            (length ps) (if (= 1 (length ps)) "" "s")))
  (when (empty? spots) (break (string sql)))
  (def out (buffer/new (+ (length sql) (* 8 (length spots)))))
  (var from 0)
  (eachp [k at] spots
    (buffer/push-string out (string/slice sql from at))
    (buffer/push-string out (literal (in ps k) escape))
    (set from (inc at)))
  (buffer/push-string out (string/slice sql from))
  (string out))
