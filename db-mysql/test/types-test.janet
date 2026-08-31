(import ../test-support/paths)
(import void/db-mysql/libmysql :as my)
(import void/db-mysql/types :as types)

# No client library and no server: this file is about the two halves of
# the text protocol that are pure janet, and one of them is the reason
# ADR-0033 needed writing. A parameter here is rendered INTO the
# statement, so "which `?` is a placeholder" and "what does this value
# become" are not conveniences — they are the driver's whole safety
# story, and they are testable without a database.

# A stand-in for mysql_real_escape_string. The real one is the
# connection's (it knows the charset); this one is enough to tell
# whether `interpolate` calls it where it should.
(defn- esc [b]
  (string/replace-all "'" "\\'" (string/replace-all "\\" "\\\\" (string b))))

(defn- interp [sql params] (types/interpolate sql params esc))

# -- which `?` is a placeholder ------------------------------------------

(assert (deep= @[28 38] (types/placeholder-positions
                          "SELECT * FROM `t` WHERE a = ? AND b = ?"))
        "the ordinary case: two placeholders, two positions")

(assert (empty? (types/placeholder-positions "SELECT 'why?' AS q"))
        "a ? inside a string literal is data")
(assert (= 1 (length (types/placeholder-positions "SELECT 'why?' AS q, ?")))
        "and the real one after it is still found")

(assert (empty? (types/placeholder-positions "SELECT `we?ird` FROM t"))
        "a ? inside a quoted identifier is part of the name")
(assert (empty? (types/placeholder-positions "SELECT \"ans?\" FROM t"))
        (string "double quotes too — they are a string in MySQL and an "
                "identifier under ANSI_QUOTES, and a ? is data in both"))

(assert (empty? (types/placeholder-positions "SELECT 1 -- what?"))
        "a ? in a -- comment is a comment")
(assert (empty? (types/placeholder-positions "SELECT 1 # what?"))
        "MySQL's # comment counts as one")
(assert (empty? (types/placeholder-positions "SELECT 1 /* what? */"))
        "and so does a block comment")
(assert (= 1 (length (types/placeholder-positions "SELECT ? /* ? */")))
        "one real placeholder, one commented out")
(assert (= 2 (length (types/placeholder-positions "SELECT ? -- ?\n, ?")))
        "a line comment ends at the newline")

(assert (= 1 (length (types/placeholder-positions "SELECT 1-1, ?")))
        "a lone minus is arithmetic, not a comment")
(assert (= 1 (length (types/placeholder-positions "SELECT a--1, ?")))
        "and so is a double minus with no space after it — `a--1` is a plus")

(assert (deep= @[19] (types/placeholder-positions "SELECT 'it''s ok', ?"))
        "a doubled quote is one byte of data, and the literal continues")
(assert (deep= @[17] (types/placeholder-positions "SELECT 'back\\\\', ?"))
        "an escaped backslash ends where it should")
(assert (empty? (types/placeholder-positions "SELECT 'q\\' ?'"))
        "an escaped quote does NOT end the literal, so the ? after it is data")

(assert (not (first (protect (types/placeholder-positions "SELECT 'unclosed"))))
        "an unterminated literal is refused rather than scanned past")

# the invariant behind all of the above, stated once: a reported
# position always indexes a literal `?`
(each sql ["SELECT ?, ?" "SELECT 'why?', ?" "SELECT `a?b`, ? # ?"
           "SELECT ? /* ? */ , ?" "SELECT 'it''s', ? -- ?"]
  (each at (types/placeholder-positions sql)
    (assert (= 63 (sql at))
            (string/format "%q: position %d is not a ?" sql at))))

# -- what a value becomes ------------------------------------------------

(assert (= "NULL" (types/literal nil esc)))
(assert (= "TRUE" (types/literal true esc)))
(assert (= "FALSE" (types/literal false esc)))
(assert (= "42" (types/literal 42 esc)))
(assert (= "-7" (types/literal -7 esc)))
(assert (= "'hi'" (types/literal "hi" esc)))
(assert (= "'admin'" (types/literal :admin esc)) "a keyword goes in by its name")
(assert (= "'o\\'brien'" (types/literal "o'brien" esc))
        "a quote in a value is the escaper's business, and it is asked")
(assert (= "'{\"a\":1}'" (types/literal {:a 1} esc)) "a dictionary is JSON")

(assert (= 0.1 (scan-number (types/literal 0.1 esc)))
        "a non-integer keeps enough digits to round-trip a double exactly")
(assert (not (first (protect (types/literal math/nan esc))))
        (string "NaN has no MySQL spelling, and a column that took one "
                "would hold something else"))
(assert (not (first (protect (types/literal math/inf esc)))))
(assert (not (first (protect (types/literal [1 2] esc))))
        "MySQL has no array type, and a silent JSON array would be a guess")
(assert (not (first (protect (types/literal (fn [] 1) esc))))
        "and anything else is refused by name rather than stringified")

# -- putting them together -----------------------------------------------

(assert (= "INSERT INTO `t` (a,b,c,d) VALUES ('o\\'brien',42,TRUE,NULL)"
           (interp "INSERT INTO `t` (a,b,c,d) VALUES (?,?,?,?)" ["o'brien" 42 true nil]))
        "every parameter is a literal, and nothing else in the statement moved")

(assert (= "SELECT 'why?' AS q, 'x'" (interp "SELECT 'why?' AS q, ?" ["x"]))
        "the ? that was data stays data")

(assert (= "SELECT 1" (interp "SELECT 1" []))
        "a statement with no placeholders is handed over untouched")

(def [ok err] (protect (interp "SELECT ?, ?" [1])))
(assert (not ok) "more placeholders than parameters does not run")
(assert (string/find "2 placeholders and 1 parameter" err)
        "and the message says which way round it was")
(assert (not (first (protect (interp "SELECT ?" [1 2]))))
        "nor do more parameters than placeholders")

# the shape of the attack this whole file is about
(def injected "'; DROP TABLE users; -- ")
(def statement (interp "SELECT * FROM `t` WHERE name = ?" [injected]))
(assert (= "SELECT * FROM `t` WHERE name = '\\'; DROP TABLE users; -- '" statement))
(assert (empty? (types/placeholder-positions statement))
        (string "and the result contains no placeholder: what went in as a "
                "value is a literal, entire — re-scanning it finds one "
                "string and no statement"))

# -- decoding ------------------------------------------------------------

(defn- fld [type &opt extra]
  (merge {:name "c" :type type :length 11 :flags 0} (or extra {})))

(assert (= 7 (types/decode (fld :long) "7")))
(assert (= 7 (types/decode (fld :short) "7")))
(assert (= 1.5 (types/decode (fld :double) "1.5")))
(assert (= "hi" (types/decode (fld :var-string) "hi")))

(assert (= true (types/decode (fld :tiny {:length 1}) "1"))
        (string "TINYINT(1) is how MySQL stores a BOOLEAN, and the server "
                "keeps no record of which word the migration used"))
(assert (= false (types/decode (fld :tiny {:length 1}) "0")))
(assert (= 1 (types/decode (fld :tiny {:length 4}) "1"))
        "a TINYINT of any other width is a number")
(assert (= 1 (types/decode (fld :tiny {:length 1}) "1" {:booleans false}))
        "and [:db-mysql :booleans] false turns the heuristic off entirely")

(assert (= "12345678901234567890.1"
           (types/decode (fld :newdecimal) "12345678901234567890.1"))
        (string "DECIMAL stays a string: it is exact, and a double would "
                "quietly lose the property it exists for"))

(assert (= 9007199254740993
           (scan-number (string (types/decode (fld :longlong) "9007199254740993"))))
        "a bigint past 2^53 comes back intact rather than rounded")
(assert (= :core/s64 (type (types/decode (fld :longlong) "9007199254740993"))))
(assert (= :core/u64 (type (types/decode (fld :longlong {:flags my/UNSIGNED-FLAG})
                                         "18446744073709551615")))
        "and an UNSIGNED one is unsigned")
(assert (= 42 (types/decode (fld :longlong) "42"))
        "while one that fits a double is an ordinary number")

(assert (= "2026-08-31 12:00:00" (types/decode (fld :datetime) "2026-08-31 12:00:00"))
        "janet has no date type, and the server's own formatting is lossless")

(assert (buffer? (types/decode (fld :blob {:flags my/BINARY-FLAG}) "\xff\x00"))
        (string "a BLOB and a TEXT share a type code, and the BINARY flag "
                "is what tells them apart"))
(assert (string? (types/decode (fld :blob) "text")))

(assert (deep= @{"a" 1} (types/decode (fld :json) "{\"a\":1}")))
(assert (= "{\"a\":1}" (types/decode (fld :json) "{\"a\":1}" {:json false}))
        "and [:db-mysql :json] false leaves it as text")

(assert (= 258 (types/decode-bit "\x01\x02"))
        "BIT arrives as raw bytes, big-endian, rather than as digits")

(print "db-mysql types-test ok")
