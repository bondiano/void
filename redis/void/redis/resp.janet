### void/redis/resp — the RESP wire format, RESP2 and RESP3 (SPEC.md
### §5.10).
###
### Two halves, and the split is the one void/http/wire already makes
### for HTTP: a cheap scanner that finds where a frame ends, and a PEG
### that turns the complete frame into a value. Parsing here is pure —
### functions over buffers, no sockets, no reads; the connection loop
### owns all I/O (./conn).
###
### `scan` walks the frame structure without building anything, and it
### is the half the reader talks to. RESP is length-prefixed, so a blob
### is skipped by arithmetic instead of by looking at its bytes, and a
### truncated frame reports *how many bytes are still missing* rather
### than "not yet": a reader that knows it needs two more megabytes
### asks for them once, where one that only knows "incomplete" rescans
### the whole buffer per chunk — which is how a 10 MB value turns
### quadratic. It also splits the two failures a bare `nil` from
### `peg/match` would conflate: a frame that has not arrived yet, and
### one that never will (a non-redis server on the port, a stream that
### lost sync). The first waits, the second must not.
###
### `parse` is the PEG, and it runs on a frame `scan` has already
### found the end of. Every type is one production, and the two
### aggregate forms fall out of `lenprefix` — which is exactly the
### combinator a length-prefixed protocol wants and the reason the
### grammar is worth having at all:
###
###     :array (* "*" (group (lenprefix :len :value)))
###
### The value mapping, RESP2 and RESP3 together:
###
###     +OK                 string          -ERR msg      error value
###     :12                 number          $5\r\nhello   string
###     $-1, *-1, _         nil             ,1.5          number
###     #t                  boolean         (123...       string (1)
###     =15\r\ntxt:...      string (2)      !21\r\n...    error value
###     *N  ~N              array           %N            table
###     >N                  push value      |N            attribute
###
### (1) a big number is a string on purpose: it is defined as an
###     integer larger than 64 bits, and a Janet number is a double —
###     turning it into one loses the digits it was sent to carry.
### (2) the three-letter format and its colon are stripped; what a
###     verbatim string carries that a blob does not is the hint that
###     it should be displayed as text, and nothing above this layer
###     acts on it.
###
### Errors are values here, not throws: `call` decides that (./conn),
### and a pipeline that collects three replies of which one failed
### needs the other two. Push and attribute frames are values for the
### same reason — the reader dispatches on them, out of band from
### whatever reply it was waiting for.

# -- reply values --------------------------------------------------------

(def- error-peg
  # "WRONGTYPE Operation against a key..." -> ["WRONGTYPE" "Operation..."]
  # The code is the leading upper-case word every redis error carries;
  # a server that omits it leaves the whole line as the message.
  (peg/compile ~(* '(some (range "AZ" "09")) (+ (* " " '(any 1)) -1))))

(defn error-value
  ``An error reply as a value: {:redis/error true :code :message
  :reply}. `code` is the leading upper-case word ("ERR", "WRONGTYPE",
  "NOSCRIPT", "MOVED"), which is the part a caller can branch on — the
  message after it is prose and changes between releases.``
  [line]
  (def parts (peg/match error-peg line))
  (def code (when parts (in parts 0)))
  {:redis/error true
   :code (or code "")
   :message (cond
              (nil? parts) (string line)
              (> (length parts) 1) (in parts 1)
              "")
   :reply (string line)})

(defn error?
  "Is this value an error reply?"
  [v]
  (and (dictionary? v) (truthy? (get v :redis/error))))

(defn error-message
  "The human half of an error reply — the whole line, code included."
  [v]
  (get v :reply ""))

(defn push-value
  "A push frame as a value: {:redis/push [kind ...]}."
  [items]
  {:redis/push items})

(defn push?
  ``Is this an out-of-band push frame? RESP3 delivers pub/sub messages,
  client-side-caching invalidations and monitor output this way, on the
  same connection as ordinary replies — which is why the reader has to
  look at every frame rather than count them.``
  [v]
  (and (dictionary? v) (not (nil? (get v :redis/push)))))

(defn push-items
  "The elements of a push frame."
  [v]
  (get v :redis/push))

(defn attribute-value
  "An attribute frame as a value: {:redis/attribute <table>}."
  [table]
  {:redis/attribute table})

(defn attribute?
  ``Is this an attribute frame? RESP3 attributes are metadata attached
  to the *next* reply (key popularity for client-side caching, and
  whatever a future release adds), and a client that does not use them
  is required to skip them — which is what the reader does.``
  [v]
  (and (dictionary? v) (not (nil? (get v :redis/attribute)))))

# -- the scanner ---------------------------------------------------------

(def- line-types
  "Type bytes whose whole frame is one CRLF-terminated line."
  {(chr "+") true (chr "-") true (chr ":") true (chr ",") true
   (chr "#") true (chr "(") true (chr "_") true})

(def- blob-types
  "Type bytes followed by a byte count and that many bytes."
  {(chr "$") true (chr "=") true (chr "!") true})

(def- aggregate-types
  ``Type bytes followed by an element count, and how many frames one
  element is — a map and an attribute carry a key and a value.``
  {(chr "*") 1 (chr "~") 1 (chr ">") 1 (chr "%") 2 (chr "|") 2})

(defn- count-at
  ``The count written between i and j: decimal digits only, with `-1`
  — the protocol's null marker (`$-1`, `*-1`) — as the one negative
  spelling allowed. nil for anything else (`1e3`, `0x10`, `-2`, a
  stray sign): the grammar accepts exactly `(some (range "09"))`, and
  a scanner that took more would hand the parser frames it refuses —
  leaving the connection stuck on a byte it can neither parse nor
  skip.``
  [buf i j]
  (cond
    (>= i j) nil

    (and (= (+ i 2) j)
         (= (chr "-") (in buf i))
         (= (chr "1") (in buf (inc i))))
    -1

    (do
      (var n 0)
      (var ok true)
      (loop [k :range [i j] :while ok]
        (def b (in buf k))
        (if (<= (chr "0") b (chr "9"))
          (set n (+ (* 10 n) (- b (chr "0"))))
          (set ok false)))
      (when ok n))))

(defn scan
  ``Find the end of the RESP frame starting at `start`. Returns

    [:done end]   `end` is the index just past the frame
    [:need n]     the frame is incomplete; retry once the buffer is
                  `n` bytes long — exact when a blob was cut mid-body,
                  one more byte when a line was

  and throws when the bytes are not RESP at all. Nothing is allocated
  per element: a blob is stepped over by its length, so re-scanning a
  partially arrived 10 MB value costs the same as scanning an empty
  one.

  `max-blob`, when given, caps the length any one blob may claim: a
  14-byte header can otherwise promise gigabytes, and the reader would
  obligingly allocate them before a single payload byte arrived. An
  over-claiming header throws — the frame cannot be skipped either,
  so the stream it came from is done for.``
  [buf &opt start max-blob]
  (default start 0)
  (def len (length buf))
  (defn streamed [i]
    (errorf (string "RESP streamed aggregates are not supported (%s? at index %d) — "
                    "this client never asks for one, so a server sending it "
                    "is not the server it claims to be")
            (string/from-bytes (in buf i)) i))
  (defn go [i]
    (if (>= i len)
      [:need (inc i)]
      (let [t (in buf i)
            eol (string/find "\r\n" buf i)]
        (cond
          (nil? eol) [:need (inc len)]

          (in line-types t) [:done (+ eol 2)]

          (in blob-types t)
          (let [n (count-at buf (inc i) eol)]
            (cond
              (and (nil? n) (= (chr "?") (get buf (inc i)))) (streamed i)
              (nil? n) (errorf "RESP blob at index %d has no length: %q"
                               i (string/slice buf i (+ eol 2)))
              # $-1 is RESP2's null blob: a length line and nothing else
              (neg? n) [:done (+ eol 2)]
              (and max-blob (> n max-blob))
              (errorf (string "RESP blob of %d bytes exceeds the [:redis :max-bulk] "
                              "cap of %d — raise the cap if values this large are expected")
                      n max-blob)
              (let [fin (+ eol 2 n 2)]
                (if (<= fin len) [:done fin] [:need fin]))))

          (in aggregate-types t)
          (let [n (count-at buf (inc i) eol)
                per (in aggregate-types t)]
            (cond
              (and (nil? n) (= (chr "?") (get buf (inc i)))) (streamed i)
              (nil? n) (errorf "RESP aggregate at index %d has no length: %q"
                               i (string/slice buf i (+ eol 2)))
              # *-1 is RESP2's null array
              (neg? n) [:done (+ eol 2)]
              (do
                (var pos (+ eol 2))
                (var pending nil)
                (loop [_ :range [0 (* per n)] :while (nil? pending)]
                  (def r (go pos))
                  (if (= :done (in r 0))
                    (set pos (in r 1))
                    (set pending r)))
                (or pending [:done pos]))))

          (errorf (string "not RESP: byte %q at index %d (expected one of "
                          "+-:$*%%~>|=!#,(_)")
                  (string/from-bytes t) i)))))
  (go start))

(defn frame-end
  "The index just past the first complete frame at `start`, or nil
  while it is incomplete. `scan` is the same answer with the missing
  byte count attached."
  [buf &opt start]
  (def r (scan buf start))
  (when (= :done (in r 0)) (in r 1)))

# -- the PEG -------------------------------------------------------------

(defn- blob-body
  ``The payload of a length-prefixed blob. `lenprefix` reads its count
  from a pattern it matches *itself*, so the capture spans the count
  line too — the first CRLF is where the payload starts.``
  [captured]
  (string/slice captured (+ 2 (string/find "\r\n" captured))))

(defn- verbatim-body
  "A verbatim string without its `txt:` (or `mkd:`) format hint."
  [captured]
  (def s (blob-body captured))
  (if (and (>= (length s) 4) (= (chr ":") (in s 3)))
    (string/slice s 4)
    s))

(defn- double-value
  "A RESP3 double: a number, or one of the three names IEEE 754 has for
  values a decimal literal cannot spell."
  [line]
  (case line
    "inf" math/inf
    "+inf" math/inf
    "-inf" (- math/inf)
    "nan" math/nan
    (or (scan-number line)
        (errorf "RESP double is not a number: %q" line))))

(defn- to-table
  "The flat [k v k v ...] of a map frame as a table."
  [items]
  (def out @{})
  (loop [i :range [0 (length items) 2]]
    (put out (in items i) (get items (inc i))))
  out)

(defn- attribute-frame
  "An attribute frame's flat [k v ...] as an attribute value."
  [items]
  (attribute-value (to-table items)))

(def- value-grammar
  ~{:crlf "\r\n"
    :line (* '(any (if-not "\r\n" 1)) :crlf)
    :len (* (/ '(some (range "09")) ,scan-number) :crlf)
    :blob-body (/ (<- (lenprefix :len 1)) ,blob-body)

    :simple (* "+" :line)
    :error (/ (* "-" :line) ,error-value)
    :integer (* ":" (/ :line ,scan-number))
    :double (* "," (/ :line ,double-value))
    :boolean (* "#" (+ (* "t" :crlf (constant true))
                       (* "f" :crlf (constant false))))
    :big-number (* "(" :line)
    :null (* "_" :crlf (constant nil))

    :blob (+ (* "$-1" :crlf (constant nil)) (* "$" :blob-body :crlf))
    :blob-error (/ (* "!" :blob-body :crlf) ,error-value)
    :verbatim (/ (* "=" (<- (lenprefix :len 1)) :crlf) ,verbatim-body)

    :array (+ (* "*-1" :crlf (constant nil))
              (* "*" (group (lenprefix :len :value))))
    :set (* "~" (group (lenprefix :len :value)))
    :map (/ (* "%" (group (lenprefix :len (* :value :value)))) ,to-table)
    :push (/ (* ">" (group (lenprefix :len :value))) ,push-value)
    :attribute (/ (* "|" (group (lenprefix :len (* :value :value)))) ,attribute-frame)

    :value (+ :blob :simple :integer :array :map :error :push
              :double :boolean :null :set :verbatim :blob-error
              :attribute :big-number)

    :main (* :value (position))})

(def value-peg
  "PEG for one RESP frame. Captures the value, then the index just past
  it."
  (peg/compile value-grammar))

(defn parse
  ``Decode the frame at `start` into [value end]. Returns nil when the
  bytes there are not one complete frame — `scan` is what tells the
  two reasons for that apart, and the reader calls it first, so a nil
  here means the caller skipped that step.``
  [buf &opt start]
  (default start 0)
  (when-let [m (peg/match value-peg buf start)]
    [(in m 0) (in m 1)]))

(defn parse-all
  ``Every complete frame in `buf`, as [values end] — `end` is where the
  first incomplete frame begins, so a reader can keep the tail and
  carry on. What a pipeline of N commands answers with is N frames in
  one buffer, and this is how they come apart.``
  [buf &opt start]
  (default start 0)
  (def out @[])
  (var pos start)
  (var more true)
  (while more
    (if (>= pos (length buf))
      (set more false)
      (let [r (scan buf pos)]
        (if (= :done (in r 0))
          (let [[v end] (parse buf pos)]
            (array/push out v)
            (set pos end))
          (set more false)))))
  [out pos])

# -- encoding ------------------------------------------------------------

(defn argument
  ``One command argument as bytes. Strings and buffers go as they are,
  a keyword or symbol as its name (so commands can be written
  `[:set :key v]`), a number as the shortest text that reads back as
  itself. Everything else is refused rather than guessed at: `nil` in
  particular, because a redis value is bytes and there is no byte
  string that means "absent" — deleting the key is a different
  command, and a client that silently sent "" would hide the
  difference.``
  [v]
  (cond
    # keywords and symbols are byte sequences in Janet, so they have to
    # be named before `bytes?` claims them — a codec that handed one
    # back unchanged would be returning a keyword where it promised
    # bytes
    (keyword? v) (string v)
    (symbol? v) (string v)
    (bytes? v) v
    (number? v) (if (= v (math/trunc v))
                  (string/format "%d" v)
                  (string v))
    (nil? v) (error "nil is not a redis argument — pass \"\" for an empty value, or use DEL")
    (boolean? v) (errorf (string "%q is not a redis argument — redis has no booleans on the "
                                 "wire; send 1/0, or \"true\"/\"false\", and decide which "
                                 "where the value is read")
                         v)
    (errorf "%q cannot be a redis argument (bytes, number, keyword or symbol)" v)))

(defn encode
  ``A command as RESP bytes, appended to `into` when given.

      (resp/encode ["SET" "user:1" "alice" "EX" 60])
      # -> @"*5\r\n$3\r\nSET\r\n$6\r\nuser:1\r\n..."

  The request is always a RESP2 array of blobs, RESP3 connection or
  not: the protocol version a client asks for in HELLO changes what
  the *server* may answer with, never what it accepts.``
  [args &opt into]
  (def out (or into @""))
  (when (empty? args) (error "a redis command needs at least a name"))
  (buffer/format out "*%d\r\n" (length args))
  (each a args
    (def bytes (argument a))
    (buffer/format out "$%d\r\n" (length bytes))
    (buffer/push out bytes)
    (buffer/push out "\r\n"))
  out)

(defn encode-all
  "Several commands into one buffer — the write half of pipelining."
  [commands &opt into]
  (def out (or into @""))
  (each c commands (encode c out))
  out)
