(import ../test-support/paths)
(import void/redis/resp :as resp)

# -- encoding ------------------------------------------------------------

(assert (= "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n"
           (string (resp/encode ["SET" "k" "v"])))
        "a command is an array of blobs, RESP2 spelling")
(assert (= "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$2\r\n42\r\n"
           (string (resp/encode [:SET :k 42])))
        "keywords are names and numbers are their shortest text")
(assert (= "$3\r\n1.5\r\n"
           (string/slice (string (resp/encode ["X" 1.5])) 11))
        "a non-integer keeps its decimal part")
(assert (= "*1\r\n$4\r\nPING\r\n" (string (resp/encode ["PING"]))))

(each bad [nil true false [1 2] {:a 1}]
  (assert (not (first (protect (resp/argument bad))))
          (string/format "%q is refused as an argument, not guessed at" bad)))
(assert (string/find "DEL" (last (protect (resp/argument nil))))
        "and nil says what to do instead")

(assert (= "*1\r\n$4\r\nPING\r\n*1\r\n$4\r\nPING\r\n"
           (string (resp/encode-all [["PING"] ["PING"]])))
        "a pipeline is the commands one after another")

(assert (not (first (protect (resp/encode []))))
        "a command needs a name")

# -- parsing: RESP2 ------------------------------------------------------

(defn- value-of [s] (first (resp/parse s)))
(defn- end-of [s] (last (resp/parse s)))

(assert (= "OK" (value-of "+OK\r\n")) "simple string")
(assert (= 42 (value-of ":42\r\n")) "integer")
(assert (= -9 (value-of ":-9\r\n")) "negative integer")
(assert (= "hello" (value-of "$5\r\nhello\r\n")) "blob")
(assert (= "" (value-of "$0\r\n\r\n")) "an empty blob is a value, not an absence")
(assert (nil? (value-of "$-1\r\n")) "the RESP2 null blob is nil")
(assert (nil? (value-of "*-1\r\n")) "and so is the null array")
(assert (deep= @[1 "abc"] (value-of "*2\r\n:1\r\n$3\r\nabc\r\n")) "array")
(assert (deep= @[@["a" nil]] (value-of "*1\r\n*2\r\n+a\r\n$-1\r\n"))
        "arrays nest, and a nil element stays in its place")
(assert (deep= @[] (value-of "*0\r\n")) "an empty array is an empty array")

(def err (value-of "-WRONGTYPE Operation against a key\r\n"))
(assert (resp/error? err) "an error reply is a value, not a throw")
(assert (= "WRONGTYPE" (err :code)) "the code is what a caller branches on")
(assert (= "Operation against a key" (err :message)))
(assert (= "WRONGTYPE Operation against a key" (resp/error-message err)))
(assert (= "" ((value-of "-\r\n") :code)) "an error with no code is still an error")

# -- parsing: RESP3 ------------------------------------------------------

(assert (nil? (value-of "_\r\n")) "the RESP3 null")
(assert (= true (value-of "#t\r\n")))
(assert (= false (value-of "#f\r\n")))
(assert (= 3.5 (value-of ",3.5\r\n")))
(assert (= math/inf (value-of ",inf\r\n")) "the names IEEE 754 needs")
(assert (= (- math/inf) (value-of ",-inf\r\n")))
(assert (nan? (value-of ",nan\r\n")))
(assert (deep= @{"a" 1 "b" 2} (value-of "%2\r\n+a\r\n:1\r\n+b\r\n:2\r\n"))
        "a map frame is a table")
(assert (deep= @["a" "b"] (value-of "~2\r\n+a\r\n+b\r\n")) "a set frame is an array")
(assert (= "Some string" (value-of "=15\r\ntxt:Some string\r\n"))
        "a verbatim string loses the format hint nothing above acts on")
(assert (= "3492890328409238509324850943850943825024385"
           (value-of "(3492890328409238509324850943850943825024385\r\n"))
        "a big number stays a string: a double would lose the digits it carries")

(def blob-err (value-of "!21\r\nSYNTAX invalid syntax\r\n"))
(assert (resp/error? blob-err) "a blob error is an error")
(assert (= "SYNTAX" (blob-err :code)))

(def push (value-of ">3\r\n$7\r\nmessage\r\n$3\r\nfoo\r\n$3\r\nbar\r\n"))
(assert (resp/push? push) "a push frame is distinguishable from an array")
(assert (deep= @["message" "foo" "bar"] (resp/push-items push)))

(def attr (value-of "|1\r\n+k\r\n+v\r\n"))
(assert (resp/attribute? attr) "and so is an attribute frame")
(assert (deep= @{"k" "v"} (attr :redis/attribute)))

# -- the scanner ---------------------------------------------------------

(assert (deep= [:done 5] (resp/scan "+OK\r\n")))
(assert (= 5 (resp/frame-end "+OK\r\n")))
(assert (= (end-of "*2\r\n:1\r\n$3\r\nabc\r\n") (resp/frame-end "*2\r\n:1\r\n$3\r\nabc\r\n"))
        "the scanner and the PEG agree about where a frame ends")

(assert (nil? (resp/frame-end "+OK")) "an unterminated line is incomplete")
(assert (deep= [:need 4] (resp/scan "+OK"))
        "an unterminated line asks for one more byte at a time")
(assert (deep= [:need 108] (resp/scan "$100\r\nab"))
        "but a cut blob says exactly how many bytes are missing")
(assert (deep= [:need 17] (resp/scan "*3\r\n:1\r\n$3\r\nab"))
        "through nesting, too")
(assert (= 13 (resp/frame-end "+OK\r\n*1\r\n:2\r\n" 5))
        "and it starts wherever the reader is")

(each junk ["@nope\r\n" "$x\r\n" "*x\r\n"]
  (assert (not (first (protect (resp/scan junk))))
          (string/format "%q is malformed, not incomplete — waiting for more of it would hang"
                         junk)))
(assert (string/find "streamed" (last (protect (resp/scan "*?\r\n"))))
        "a streamed aggregate is named rather than mis-parsed")

# -- pipelined replies ---------------------------------------------------

(def [values rest] (resp/parse-all "+a\r\n+b\r\n:3\r\n$4\r\nxy"))
(assert (deep= @["a" "b" 3] values) "every complete frame comes out")
(assert (= 12 rest) "and the incomplete tail is left for the next read")

(def [none pos] (resp/parse-all "$4\r\nxy"))
(assert (and (empty? none) (zero? pos))
        "nothing complete means nothing consumed")

(printf "resp-test: ok")
