### void/http/wire — HTTP/1.1 wire-format primitives.
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
    :path-chr (range "az" "AZ" "09" "!!" "$9" ":;" "==" "@@" "~~" "__")
    # the query part is laxer than the path: clients following the
    # JSON:API/Rails nesting convention send [ ] raw
    # (filter[status]=open), and raw UTF-8 arrives unencoded from
    # plenty of legitimate tooling. A raw "#" stays a 400 in both
    # parts: RFC 3986 §3.5 makes it a fragment delimiter, and a
    # fragment never belongs in a request target.
    :query-chr (+ :path-chr (set "?[]{}|^\"`\\") (range "\x80\xff"))
    :path '(* (some :path-chr) (? (* "?" (any :query-chr))))
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
  * `:http-version` - [major minor] as a tuple: [1 1] or [1 0]. The
     wire here is HTTP/1.x only; the shape is what leaves room for
     [2 0] without a second key.
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
          :http-version [1 version]
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
          :http-version [1 version]
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

(defn url-decode
  ``Percent-decode a string — the inverse of `url-encode`, for the
  places a value arrives already encoded and no query grammar is
  running over it (a cookie value, a `Content-Disposition` filename).

  `+` is left alone unless `space-plus` says otherwise, and that is
  the whole reason this takes an argument: `+` means a space in a
  *query string* and means a plus everywhere else, and a cookie
  carrying base64 (every session token, every JWT) would come back
  corrupted by the query rule.``
  [s &opt space-plus]
  (def str (string s))
  (def out (buffer/new (length str)))
  (var i 0)
  (def n (length str))
  (while (< i n)
    (def b (in str i))
    (cond
      (and (= b (chr "%")) (< (+ i 2) n))
      (if-let [v (scan-number (string "0x" (string/slice str (+ i 1) (+ i 3))))]
        (do (buffer/push-byte out v) (+= i 3))
        (do (buffer/push-byte out b) (++ i)))
      (and space-plus (= b (chr "+")))
      (do (buffer/push-byte out (chr " ")) (++ i))
      (do (buffer/push-byte out b) (++ i))))
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

(defn path-segments
  ``The non-empty segments of a path: `"/one//two/"` -> `@["one"
  "two"]`. What a client does with a `Location` it has to reason about
  and what a caller does with a target it did not build itself; the
  router has its own splitter because it compiles patterns, and this
  is the one for a path in hand.``
  [path]
  (def [p _] (split-path (string path)))
  (filter |(not (empty? $)) (string/split "/" p)))

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
  ``Parse a Cookie header value into a table of cookie names to values.
  Returns an empty table when s is nil or has no cookie pairs.

  Values are percent-decoded, because `ring/cookie-str` percent-encodes
  them on the way out: a cookie whose value came back as `a%20b` after
  being set as `a b` would be a round trip through this framework that
  does not close.``
  [s]
  (def raw (or (-?>> s
                     (peg/match cookie-grammar)
                     (apply table))
               @{}))
  (eachp [k v] raw (put raw k (url-decode v)))
  raw)

(defn cookie-header
  ``Format a `Cookie` request header value from a dictionary or a list
  of pairs:

      (wire/cookie-header {"session" "abc" "theme" "dark"})
      # -> "session=abc; theme=dark"

  Values are percent-encoded, the way `ring/cookie-str` writes them on
  the way out — a client that sends back what a server set must send
  back the same bytes.``
  [cookies]
  (def pairs
    (if (dictionary? cookies)
      (seq [k :in (sorted (map string (keys cookies)))]
        [k (or (get cookies k) (get cookies (keyword k)))])
      (map |[(string (in $ 0)) (in $ 1)] cookies)))
  (string/join
    (seq [[k v] :in pairs] (string k "=" (url-encode (string v))))
    "; "))

(def- same-site-keywords
  {"strict" :strict "lax" :lax "none" :none})

(defn parse-set-cookie
  ``Parse one `Set-Cookie` header value into a table:

      {:name "session" :value "abc" :path "/" :domain "example.test"
       :max-age 3600 :expires "Wed, 21 Oct 2026 07:28:00 GMT"
       :secure true :http-only true :same-site :lax}

  The inverse of `ring/cookie-str`, and the half a *client* needs:
  everything past the name and value is an attribute the server is
  asking the caller to honour, and a client that dropped them could
  not tell a session cookie from a permanent one. Returns nil when
  there is no `name=value` at the front — a malformed header is
  ignored rather than raised, the way an inbound `traceparent` is.``
  [value]
  (when value
    (def parts (string/split ";" (string value)))
    (def head (string/trim (first parts)))
    (def eq (string/find "=" head))
    (def name (when eq (string/trim (string/slice head 0 eq))))
    (when (and name (not (empty? name)))
      (def out @{:name name
                 :value (url-decode (string/trim (string/slice head (inc eq))))})
      (each attr (drop 1 parts)
        (def a (string/trim attr))
        (def i (string/find "=" a))
        (def k (string/ascii-lower (if i (string/trim (string/slice a 0 i)) a)))
        (def v (when i (string/trim (string/slice a (inc i)))))
        (case k
          "path" (put out :path v)
          "domain" (put out :domain v)
          "expires" (put out :expires v)
          "max-age" (put out :max-age (scan-number v))
          "secure" (put out :secure true)
          "httponly" (put out :http-only true)
          "samesite" (put out :same-site (get same-site-keywords
                                              (string/ascii-lower (or v "")) v))
          nil))
      out)))

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

(def- header-split-peg
  # CR, LF or NUL inside a header name or value splits the response:
  # a Location built from user input becomes header injection
  (peg/compile '(set "\r\n\0")))

(defn- write-header-line [buf k v]
  (when (or (peg/find header-split-peg (string k))
            (peg/find header-split-peg (string v)))
    (error {:header (string k)
            :message (string/format "response header %q carries CR, LF or NUL"
                                    (string k))}))
  (buffer/format buf "%V: %V\r\n" k v))

(defn write-head
  "Format the response status line and headers into buf, without the
  terminating blank line — write-body appends Content-Length or
  Transfer-Encoding plus the terminator. An indexed headers value
  renders the header once per element (duplicate Set-Cookie entries).
  A header name or value containing CR, LF or NUL raises a structured
  error naming the header — response splitting never reaches the wire.
  Returns buf."
  [buf status headers]
  (buffer/format buf "HTTP/1.1 %d %s\r\n"
                 status (get status-messages status "Unknown"))
  (eachp [k v] headers
    (if (indexed? v)
      (each ve v (write-header-line buf k ve))
      (write-header-line buf k v)))
  buf)

(defn write-body
  "Finish and send a response whose head is already formatted in buf:
  append Content-Length (byte-sequence body), Transfer-Encoding: chunked
  (iterable body — each element one chunk, may be lazy for streaming) or
  neither (nil body), then write everything to conn. Zero-length chunks
  are skipped (an empty chunk is the wire terminator). A failed write
  with a fiber body cancels the fiber before re-raising, so a defer
  inside the producer runs when the consumer hangs up. Clears buf so
  the connection loop can reuse it."
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
      (def [ok err]
        (protect
          (do
            (each chunk body
              (assert (bytes? chunk) "expected byte chunk")
              # a zero-length chunk would render as "0\r\n\r\n" — the
              # body terminator — and every later chunk would parse as
              # the start of the next response on the connection
              (unless (empty? chunk)
                (buffer/format buf "%x\r\n%V\r\n" (length chunk) chunk)
                (:write conn buf)
                (buffer/clear buf)))
            (buffer/format buf "0\r\n\r\n")
            (:write conn buf))))
      (unless ok
        # the consumer is gone with the producer parked mid-yield:
        # cancel it so a defer inside a coro body (an SSE subscription,
        # a room membership) releases what it holds instead of leaking
        # until process exit
        (when (and (fiber? body) (= :pending (fiber/status body)))
          (protect (cancel body :void.http/consumer-gone)))
        (error err))))
  (buffer/clear buf))
