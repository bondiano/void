(import ../void/http/wire :as wire)

# -- request heads -------------------------------------------------------

(def raw-request
  (string "GET /users?id=1&name=ann HTTP/1.1\r\n"
          "Host: example.com\r\n"
          "Accept:text/html\r\n"
          "X-Dup: a\r\n"
          "x-DUP: b\r\n"
          "\r\n"
          "leftover-bytes"))

(def req (wire/parse-request-head (buffer raw-request)))
(assert (table? req) "well-formed request head parses to a table")
(assert (= "GET" (req :method)) "method is captured")
(assert (= "/users?id=1&name=ann" (req :path)) "path keeps the query string")
(assert (= [1 1] (req :http-version)) "HTTP/1.1 is captured as [major minor]")
(assert (= "example.com" (get-in req [:headers "host"]))
        "header names are lowercased")
(assert (= "text/html" (get-in req [:headers "accept"]))
        "header value without a space after the colon parses")
(assert (deep= @["a" "b"] (get-in req [:headers "x-dup"]))
        "duplicate headers accumulate into an array")
(assert (= (req :head-size) (- (length raw-request) (length "leftover-bytes")))
        "head-size stops at the terminator; leftover bytes are not consumed")

(assert (= [1 0] ((wire/parse-request-head @"GET / HTTP/1.0\r\n\r\n") :http-version))
        "HTTP/1.0 minor version is captured")

(assert (nil? (wire/parse-request-head @"GET / HTTP/1.1\r\nHost: x\r\n"))
        "incomplete head (no terminator yet) parses to nil")
(assert (nil? (wire/parse-request-head @"")) "empty buffer parses to nil")
(assert (= :error (wire/parse-request-head @"BLARG\r\n\r\n"))
        "malformed head parses to :error")
(assert (= :error (wire/parse-request-head @"GET / HTTP/2\r\n\r\n"))
        "non-1.x version is rejected")

# -- head-end ------------------------------------------------------------

(assert (nil? (wire/head-end @"GET / HTTP/1.1\r\n")) "no terminator -> nil")
(assert (= (length "a\r\n\r\n") (wire/head-end @"a\r\n\r\nbody"))
        "head-end points just past the terminator")
(assert (= 5 (wire/head-end @"a\r\n\r\nb\r\n\r\n" 0))
        "head-end finds the first terminator")

# -- response heads ------------------------------------------------------

(def res (wire/parse-response-head
           @"HTTP/1.1 204 No Content\r\nServer: void\r\n\r\n"))
(assert (table? res) "well-formed response head parses to a table")
(assert (= 204 (res :status)) "status is scanned to a number")
(assert (= "No Content" (res :message)) "reason phrase is captured")
(assert (= [1 1] (res :http-version)) "response version is captured")
(assert (= "void" (get-in res [:headers "server"])) "response headers parse")

(assert (nil? (wire/parse-response-head @"HTTP/1.1 200 OK\r\n"))
        "incomplete response head parses to nil")
(assert (= :error (wire/parse-response-head @"ICY 200 OK\r\n\r\n"))
        "malformed response head parses to :error")

# -- split-path / query strings ------------------------------------------

(assert (deep= ["/users" "id=1"] (wire/split-path "/users?id=1"))
        "split-path separates route and query string")
(assert (deep= ["/users" nil] (wire/split-path "/users"))
        "split-path without a query string yields nil")
(assert (deep= ["/u" ""] (wire/split-path "/u?"))
        "bare ? yields an empty query string")

(def q (wire/parse-query "a=1&b=hello%20world&c=x+y&flag&a=2"))
(assert (deep= @["1" "2"] (q "a")) "duplicate query keys accumulate")
(assert (= "hello world" (q "b")) "percent-encoding is decoded")
(assert (= "x y" (q "c")) "+ decodes to space")
(assert (= true (q "flag")) "a key without a value maps to true")

(assert (= "2" ((wire/parse-query "a=1;b=2") "b"))
        "semicolon separates entries too")
(assert (deep= @{} (wire/parse-query "")) "empty query string -> empty table")
(assert (nil? (wire/parse-query nil)) "nil query string -> nil")

# -- cookies -------------------------------------------------------------

(def cookies (wire/parse-cookies "session=abc; theme=dark"))
(assert (= "abc" (cookies "session")) "cookie pairs parse")
(assert (= "dark" (cookies "theme")) "multiple cookies parse")
(assert (deep= @{} (wire/parse-cookies nil)) "nil cookie header -> empty table")
(assert (empty? (wire/parse-cookies "")) "empty cookie header -> empty table")

# -- status messages -----------------------------------------------------

(assert (= "OK" (wire/status-messages 200)) "200 OK")
(assert (= "Not Found" (wire/status-messages 404)) "404 Not Found")
(assert (= "Network Authentication Required" (wire/status-messages 511))
        "table covers the long tail")

# -- response writing ----------------------------------------------------

(defn fake-conn
  "A connection double capturing everything written to it in :out."
  []
  (def out @"")
  {:out out
   :write (fn [self buf] (buffer/push out buf) self)})

(def head (wire/write-head @"" 404 {"content-type" "text/plain"}))
(assert (= "HTTP/1.1 404 Not Found\r\ncontent-type: text/plain\r\n"
           (string head))
        "write-head renders status line and headers, no terminator")

(def multi (wire/write-head @"" 200 {"set-cookie" ["a=1" "b=2"]}))
(assert (string/find "set-cookie: a=1\r\n" (string multi))
        "indexed header value renders each element")
(assert (string/find "set-cookie: b=2\r\n" (string multi))
        "indexed header value renders every element")

(let [conn (fake-conn)
      buf @"HTTP/1.1 204 No Content\r\n"]
  (wire/write-body conn buf nil)
  (assert (= "HTTP/1.1 204 No Content\r\n\r\n" (string (conn :out)))
          "nil body closes the head with a bare terminator")
  (assert (empty? buf) "write-body clears the buffer for reuse"))

(let [conn (fake-conn)]
  (wire/write-body conn @"" "hello")
  (assert (= "Content-Length: 5\r\n\r\nhello" (string (conn :out)))
          "byte body gets Content-Length"))

(let [conn (fake-conn)]
  (wire/write-body conn @"" ["ab" "cdefghijklmnopq"])
  (assert (= "Transfer-Encoding: chunked\r\n\r\n2\r\nab\r\nf\r\ncdefghijklmnopq\r\n0\r\n\r\n"
             (string (conn :out)))
          "iterable body streams as chunked with hex sizes and a final 0 chunk"))

(let [conn (fake-conn)]
  (assert (not (first (protect (wire/write-body conn @"" [42]))))
          "non-byte chunk raises"))


# -- percent decoding, cookies both ways ---------------------------------

(assert (= "a b+c" (wire/url-decode "a%20b+c"))
        "+ is a plus everywhere but a query string, and a cookie carrying base64 must survive")
(assert (= "a b c" (wire/url-decode "a%20b+c" true)) "unless the caller says it is a query")

(assert (= "session=abc; theme=dark%20mode"
           (wire/cookie-header {"session" "abc" "theme" "dark mode"}))
        "a Cookie header is built the way ring/cookie-str writes the values")

(def sc (wire/parse-set-cookie "session=a%20b; Path=/; Domain=example.test; Max-Age=3600; HttpOnly; Secure; SameSite=Lax"))
(assert (= "session" (sc :name)))
(assert (= "a b" (sc :value)) "the value is decoded")
(assert (= "/" (sc :path)))
(assert (= "example.test" (sc :domain)))
(assert (= 3600 (sc :max-age)) "and Max-Age is a number, not the string it arrived as")
(assert (sc :http-only))
(assert (sc :secure))
(assert (= :lax (sc :same-site)))
(assert (nil? (wire/parse-set-cookie "nonsense")) "a malformed header is ignored, not raised")
(assert (nil? (wire/parse-set-cookie "=orphan")) "and so is one with no name")

(assert (= "a b" ((wire/parse-cookies "x=a%20b") "x"))
        "what ring/cookie-str encoded on the way out is decoded on the way in — the round trip closes")
(assert (= "ey+J/9" ((wire/parse-cookies "jwt=ey+J/9") "jwt"))
        "and a + in a cookie stays a +, because that is what session tokens are made of")

(assert (= ["one" "two"] (tuple ;(wire/path-segments "/one//two/?x=1")))
        "path segments drop the empties and the query")
(assert (empty? (wire/path-segments "/")))

# -- header injection stops at the writer --------------------------------
#
# A Location (or any header) built from user input must not be able to
# split the response: CR, LF and NUL are refused with a structured
# error naming the header, before a single byte reaches the socket.

(each bad ["/a\r\nSet-Cookie: admin=1" "/a\rx" "/a\nx" "va\0lue"]
  (def [ok err] (protect (wire/write-head @"" 302 {"location" bad})))
  (assert (not ok) (string/format "header value %q is refused" bad))
  (assert (= "location" (get err :header)) "and the error names the header"))

(def [nok nerr] (protect (wire/write-head @"" 200 {"x\r\ny" "v"})))
(assert (not nok) "a header *name* carrying CRLF is refused too")
(assert (= "x\r\ny" (get nerr :header)))

(def [lok lerr] (protect (wire/write-head @"" 200 {"set-cookie" ["a=1" "b=2\r\nc"]})))
(assert (not lok) "each element of an indexed header value is checked")
(assert (= "set-cookie" (get lerr :header)))

# -- an empty chunk is the wire terminator, so the writer skips it -------
#
# "0\r\n\r\n" mid-body would end the response early and let the rest be
# parsed as the next response on the connection — request smuggling
# behind a proxy.

(let [conn (fake-conn)]
  (wire/write-body conn @"" ["one" "" "two"])
  (assert (= "Transfer-Encoding: chunked\r\n\r\n3\r\none\r\n3\r\ntwo\r\n0\r\n\r\n"
             (string (conn :out)))
          "a zero-length chunk is skipped, not framed as the terminator"))

(let [conn (fake-conn)]
  (wire/write-body conn @"" (coro (yield "") (yield "later")))
  (assert (= "Transfer-Encoding: chunked\r\n\r\n5\r\nlater\r\n0\r\n\r\n"
             (string (conn :out)))
          "a fiber body yielding \"\" keeps its framing intact"))

# -- a failed write cancels a fiber body so its defer runs ---------------

(do
  (var cleaned false)
  (def body (coro (defer (set cleaned true) (forever (yield "tick")))))
  (var writes 0)
  (def dying {:write (fn [_ _] (++ writes) (when (> writes 1) (error "broken pipe")))})
  (def [ok err] (protect (wire/write-body dying @"" body)))
  (assert (not ok) "the write error still reaches the caller")
  (assert cleaned "the producer's defer ran — its subscription is released")
  (assert (not= :pending (fiber/status body)) "the producer is not left parked"))

# -- the query part takes what real clients send -------------------------
#
# filter[status]=open is the JSON:API/Rails nesting convention, and raw
# UTF-8 arrives unencoded from plenty of tooling. The path part stays
# strict, and a raw # is a fragment delimiter in either part.

(defn- head-of [target]
  (wire/parse-request-head (buffer "GET " target " HTTP/1.1\r\nHost: t\r\n\r\n")))

(each target ["/s?filter[status]=open" "/s?q=caf\xC3\xA9" "/s?a=1|2"
              "/s?a={}" "/s?a=x^y" "/s?a=\"b\"" "/s?a=`b`" "/s?a=b\\c"]
  (def h (head-of target))
  (assert (table? h) (string/format "%q parses" target))
  (assert (= target (h :path)) "and the target survives whole"))

(assert (deep= @{"filter[status]" "open"}
               (wire/parse-query (get (wire/split-path ((head-of "/s?filter[status]=open") :path)) 1)))
        "and the bracketed key comes out of the query grammar intact")

(each target ["/s?a=b#c" "/s[x]" "/s{y}" "/bad\x01path"]
  (assert (= :error (head-of target))
          (string/format "%q is still a 400" target)))

(print "wire-test: all assertions passed")
