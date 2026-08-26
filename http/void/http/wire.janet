### void/http/wire — HTTP/1.1 wire-format primitives (SPEC §5.1, ADR-0015).
###
### The layer inherited from spork/http: PEG grammars for request and
### response heads, query strings and cookies, the status-message table
### and the auto-chunked body writer. Parsing here is pure — functions
### over buffers, no sockets, no reads: the connection loop (keep-alive,
### limits, timeouts, graceful drain) lives in the server and owns all
### I/O. spork/http stays a behavioural reference; this is a fork of
### ideas, divergences are not synced back (the first one: the HTTP/1.x
### minor version is captured — keep-alive semantics depend on it).
###
### Derived from spork/http (https://github.com/janet-lang/spork),
### Copyright (c) 2022 Calvin Rose and contributors, MIT license.

# -- head grammars -------------------------------------------------------

(def- http-grammar
  ~{:ws (some (set " \t"))
    :any-ws (any (set " \t"))
    :rn "\r\n"
    :method '(some (range "AZ"))
    :version (/ ':d ,scan-number)
    :path-chr (range "az" "AZ" "09" "!!" "$9" ":;" "==" "?@" "~~" "__")
    :path '(some :path-chr)
    :printable (range "\x20~" "\t\t")
    :headers (* (any :header) :rn)
    # lower case header names since http headers are case-insensitive
    :header-name (/ '(some (range "\x219" ";~")) ,string/ascii-lower)
    :header-value '(any :printable)
    :header (* :header-name ":" :any-ws :header-value :rn)
    :request-status (* :method :ws :path :ws "HTTP/1." :version :any-ws :rn)
    :response-status (* "HTTP/1." :version :ws (/ ':d+ ,scan-number)
                        :ws '(any :printable) :rn)})

(def request-peg
  "PEG for parsing HTTP request heads. Captures: method, path, minor
  version, then header name/value pairs."
  (peg/compile
    (table/to-struct
      (merge {:main ~(* :request-status :headers)} http-grammar))))

(def response-peg
  "PEG for parsing HTTP response heads. Captures: minor version, status,
  message, then header name/value pairs."
  (peg/compile
    (table/to-struct
      (merge {:main ~(* :response-status :headers)} http-grammar))))

(defn- accum-key-values
  "Accumulate key-value pairs based on arg index (even = key, odd =
  value) into a table, combining duplicate keys into arrays of values
  rather than overwriting. Used for both query strings and headers."
  [& args]
  (def tab @{})
  (loop [i :range [0 (length args) 2]
         :let [k (in args i) v (get args (inc i))]]
    (if-let [item (in tab k)]
      (if (array? item)
        (array/push item v)
        (put tab k @[item v]))
      (put tab k v)))
  tab)

# -- head parsing --------------------------------------------------------

(def head-terminator "The bytes that end an HTTP/1.1 head." "\r\n\r\n")

(defn head-end
  "Index just past the \\r\\n\\r\\n head terminator in buf, or nil while
  the head is incomplete. `start` lets an incremental reader resume the
  search near the tail instead of rescanning the whole buffer."
  [buf &opt start]
  (default start 0)
  (when-let [pos (string/find head-terminator buf start)]
    (+ pos (length head-terminator))))

(defn parse-request-head
  ``Parse an HTTP request head from the start of buf. Returns nil while
  the head terminator has not arrived yet, :error on a malformed head,
  otherwise a table with:
  * `:method` - HTTP method, as a string.
  * `:path` - raw request target, query string included.
  * `:http-version` - minor HTTP/1.x version as an integer (0 or 1).
  * `:headers` - table mapping lowercase header names to values;
     repeated headers accumulate into arrays.
  * `:head-size` - bytes consumed by the head, terminator included.
     Bytes past it belong to the body or the next pipelined request.``
  [buf]
  (when-let [end (head-end buf)]
    (if-let [matches (peg/match request-peg buf)]
      (let [[method path version] matches]
        @{:method method
          :path path
          :http-version version
          :headers (accum-key-values ;(array/remove matches 0 3))
          :head-size end})
      :error)))

(defn parse-response-head
  ``Parse an HTTP response head from the start of buf. Returns nil while
  the head is incomplete, :error on a malformed head, otherwise a table
  with `:status`, `:message`, `:http-version`, `:headers` and
  `:head-size` (same conventions as parse-request-head).``
  [buf]
  (when-let [end (head-end buf)]
    (if-let [matches (peg/match response-peg buf)]
      (let [[version status message] matches]
        @{:status status
          :message message
          :http-version version
          :headers (accum-key-values ;(array/remove matches 0 3))
          :head-size end})
      :error)))

# -- chunked transfer coding ---------------------------------------------

(def- chunk-head-peg
  # "1a3;ext=1\r\n" -> size; chunk extensions are skipped (they carry
  # no meaning we consume, but must not break parsing)
  (peg/compile
    ~(* (/ '(some :h) ,|(scan-number $ 16))
        (any (* ";" (any (if-not "\r" 1))))
        "\r\n")))

(defn parse-chunk-head
  ``Parse one chunk-size line ("1a3;ext\r\n") at `start` in buf.
  Returns [size consumed] where consumed counts the size line only,
  nil while the line is still incomplete, :error on a malformed line.``
  [buf &opt start]
  (default start 0)
  (if-let [nl (string/find "\r\n" buf start)]
    (if-let [m (peg/match chunk-head-peg buf start)]
      [(first m) (- (+ nl 2) start)]
      :error)
    nil))

# -- url encoding --------------------------------------------------------

(def- unreserved
  # RFC 3986 unreserved characters, kept literal by url-encode
  (do
    (def t @{})
    (each [lo hi] [[(chr "a") (chr "z")] [(chr "A") (chr "Z")] [(chr "0") (chr "9")]]
      (for b lo (inc hi) (put t b true)))
    (each b "-_.~" (put t b true))
    (freeze t)))

(defn url-encode
  "Percent-encode everything outside the RFC 3986 unreserved set."
  [s]
  (def out (buffer/new (length s)))
  (each b s
    (if (in unreserved b)
      (buffer/push out b)
      (buffer/format out "%%%02X" b)))
  (string out))

(defn encode-query
  "Encode a dictionary into a query string (no leading ?). A true value
  renders the bare key, an indexed value repeats the key."
  [params]
  (def parts @[])
  (each k (sorted (keys params))
    (def push-one
      (fn [v]
        (array/push parts
                    (if (= true v)
                      (url-encode (string k))
                      (string (url-encode (string k)) "=" (url-encode (string v)))))))
    (def v (params k))
    (if (indexed? v) (each e v (push-one e)) (push-one v)))
  (string/join parts "&"))

# -- query strings and cookies -------------------------------------------

(def query-string-grammar
  "Grammar that parses a query string (sans url path and ? character)
  and returns a table."
  (peg/compile
    ~{:qchar (+ (* "%" (/ (number (* :h :h) 16) ,string/from-bytes))
                (* "+" (constant " ")))
      :kchar (+ :qchar (* (not (set "&=;")) '1))
      :vchar (+ :qchar (* (not (set "&;")) '1))
      :key (accumulate (some :kchar))
      :value (accumulate (any :vchar))
      :entry (* :key (+ (* "=" :value) (constant true)) (+ (set ";&") -1))
      :main (/ (any :entry) ,accum-key-values)}))

(defn split-path
  "Split a raw request target into [route query-string]; query-string is
  nil when the target has no ? character."
  [path]
  (if-let [q (string/find "?" path)]
    [(string/slice path 0 q) (string/slice path (inc q))]
    [path nil]))

(defn parse-query
  "Parse a query string (without the leading ?) into a table. Values are
  percent-decoded, + becomes space, duplicate keys accumulate into
  arrays, a key without a value maps to true. Returns nil when qs is nil
  or unparseable."
  [qs]
  (when qs
    (when-let [m (peg/match query-string-grammar qs)]
      (first m))))

(def cookie-grammar
  "Grammar to parse a Cookie header value to a series of keys and values."
  (peg/compile
    {:content '(some (if-not (set "=;") 1))
     :eql "="
     :sep '(between 1 2 (set "; "))
     :main '(some (* (<- :content) :eql (<- :content) (? :sep)))}))

(defn parse-cookies
  "Parse a Cookie header value into a table of cookie names to values.
  Returns an empty table when s is nil or has no cookie pairs."
  [s]
  (or (-?>> s
            (peg/match cookie-grammar)
            (apply table))
      @{}))

# -- status messages -----------------------------------------------------

(def status-messages
  "Mapping of HTTP status codes to their reason phrases."
  {100 "Continue"
   101 "Switching Protocols"
   102 "Processing"
   200 "OK"
   201 "Created"
   202 "Accepted"
   203 "Non-Authoritative Information"
   204 "No Content"
   205 "Reset Content"
   206 "Partial Content"
   207 "Multi-Status"
   208 "Already Reported"
   226 "IM Used"
   300 "Multiple Choices"
   301 "Moved Permanently"
   302 "Found"
   303 "See Other"
   304 "Not Modified"
   305 "Use Proxy"
   307 "Temporary Redirect"
   308 "Permanent Redirect"
   400 "Bad Request"
   401 "Unauthorized"
   402 "Payment Required"
   403 "Forbidden"
   404 "Not Found"
   405 "Method Not Allowed"
   406 "Not Acceptable"
   407 "Proxy Authentication Required"
   408 "Request Timeout"
   409 "Conflict"
   410 "Gone"
   411 "Length Required"
   412 "Precondition Failed"
   413 "Payload Too Large"
   414 "URI Too Long"
   415 "Unsupported Media Type"
   416 "Range Not Satisfiable"
   417 "Expectation Failed"
   421 "Misdirected Request"
   422 "Unprocessable Entity"
   423 "Locked"
   424 "Failed Dependency"
   426 "Upgrade Required"
   428 "Precondition Required"
   429 "Too Many Requests"
   431 "Request Header Fields Too Large"
   451 "Unavailable For Legal Reasons"
   500 "Internal Server Error"
   501 "Not Implemented"
   502 "Bad Gateway"
   503 "Service Unavailable"
   504 "Gateway Timeout"
   505 "HTTP Version Not Supported"
   506 "Variant Also Negotiates"
   507 "Insufficient Storage"
   508 "Loop Detected"
   510 "Not Extended"
   511 "Network Authentication Required"})

# -- response writing ----------------------------------------------------

(defn write-head
  "Format the response status line and headers into buf, without the
  terminating blank line — write-body appends Content-Length or
  Transfer-Encoding plus the terminator. An indexed headers value
  renders the header once per element (duplicate Set-Cookie entries).
  Returns buf."
  [buf status headers]
  (buffer/format buf "HTTP/1.1 %d %s\r\n"
                 status (get status-messages status "Unknown"))
  (eachp [k v] headers
    (if (indexed? v)
      (each ve v (buffer/format buf "%V: %V\r\n" k ve))
      (buffer/format buf "%V: %V\r\n" k v)))
  buf)

(defn write-body
  "Finish and send a response whose head is already formatted in buf:
  append Content-Length (byte-sequence body), Transfer-Encoding: chunked
  (iterable body — each element one chunk, may be lazy for streaming) or
  neither (nil body), then write everything to conn. Clears buf so the
  connection loop can reuse it."
  [conn buf body]
  (cond
    (nil? body)
    (do
      (buffer/push buf "\r\n")
      (:write conn buf))

    (bytes? body)
    (do
      (buffer/format buf "Content-Length: %d\r\n\r\n%V" (length body) body)
      (:write conn buf))

    # default - iterate chunks
    (do
      (buffer/format buf "Transfer-Encoding: chunked\r\n\r\n")
      (each chunk body
        (assert (bytes? chunk) "expected byte chunk")
        (buffer/format buf "%x\r\n%V\r\n" (length chunk) chunk)
        (:write conn buf)
        (buffer/clear buf))
      (buffer/format buf "0\r\n\r\n")
      (:write conn buf)))
  (buffer/clear buf))
