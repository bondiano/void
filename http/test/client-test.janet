# The HTTP client: URL parsing, the bytes it writes, and every
# response framing the kernel can answer with — driven against this
# package's own server, which is the only honest counterpart for it.

(import ../test-support/paths)
(import void/http/client :as client)
(import void/http/server :as server)
(import void/http/ring :as ring)
(import void/http/wire :as wire)
(import void/http/multipart :as multipart)

# -- urls ----------------------------------------------------------------

(def u (client/parse-url "http://example.test:4318/v1/traces?x=1"))
(assert (= "example.test" (u :host)))
(assert (= "4318" (u :port)))
(assert (= "/v1/traces?x=1" (u :target)) "path and query are the request target")

(assert (= "80" ((client/parse-url "http://example.test") :port))
        "a scheme implies its port")
(assert (= "/" ((client/parse-url "http://example.test") :target))
        "a URL with no path asks for /")
(assert (= "::1" ((client/parse-url "http://[::1]:4318/v1/metrics") :host))
        "an IPv6 literal loses its brackets")
(assert (= "4318" ((client/parse-url "http://[::1]:4318/v1/metrics") :port)))

(def [ok err] (protect (client/parse-url "https://collector.example/v1/traces")))
(assert (not ok) "https without :void/tls in the composition is refused")
(assert (string/find ":void/tls" (string err))
        "and the error names the plugin rather than failing at connect time")

# with the seam closed (what :void/tls does on load), the same URL
# parses — and knows its default port
(set client/tls-connect (fn stub [&] (error "never dialed by a parse")))
(assert (= "443" ((client/parse-url "https://collector.example/v1/traces") :port))
        "https parses once TLS is composed, with 443 implied")
(set client/tls-connect nil)

(assert (not (first (protect (client/parse-url "collector:4318"))))
        "a URL without a scheme is not a URL")

# -- the bytes -----------------------------------------------------------

(def head (string (client/format-request
                    {:method :post :target "/v1/traces"
                     :headers {"Content-Type" "application/json"}
                     :authority "127.0.0.1:4318"
                     :body "{}"})))
(assert (string/has-prefix? "POST /v1/traces HTTP/1.1\r\n" head))
(assert (string/find "host: 127.0.0.1:4318\r\n" head) "Host comes from the client's authority")
(assert (string/find "content-type: application/json\r\n" head) "header names go out lowercase")
(assert (string/find "content-length: 2\r\n" head) "a body is always measured")
(assert (string/find "connection: keep-alive\r\n" head))
(assert (string/has-suffix? "\r\n\r\n{}" head) "and the body follows the blank line")

(assert (string/find "connection: close"
                     (string (client/format-request {:method :get :target "/" :close true})))
        "a one-shot request says so on the wire")

# -- a server to talk to -------------------------------------------------

(defn- app [req]
  (case (req :path)
    "/hello" (ring/text 200 "hello")
    "/echo" (ring/response 200 (string (req :body))
                           @{"content-type" (or (get-in req [:headers "content-type"]) "text/plain")})
    "/chunked" (ring/response 200 ["one" "two" "three"] @{"content-type" "text/plain"})
    "/empty" (ring/response 204)
    "/slow" (do (ev/sleep 0.4) (ring/text 200 "late"))
    "/big" (ring/text 200 (string/repeat "x" 4096))
    "/boom" (ring/text 500 "sorry")
    "/close" (ring/response 200 "bye" @{"connection" "close"})
    "/method" (ring/text 200 (req :method))
    "/query" (ring/text 200 (string/format "%j" (freeze (req :query))))
    "/form" (ring/text 200 (string/format "%s|%s"
                                          (or (ring/request-header req "content-type") "-")
                                          (string (req :body))))
    "/upload" (let [bnd (multipart/boundary (ring/request-header req "content-type"))
                    parts (multipart/parse (req :body) bnd)]
                (ring/text 200 (string/format "%j" (freeze (multipart/fields parts)))))
    "/cookies" (ring/text 200 (string/format "%j" (freeze (ring/cookies req))))
    "/set-cookies" (-> (ring/text 200 "set")
                       (ring/set-cookie "session" "abc def"
                                        {:path "/" :max-age 3600
                                         :http-only true :same-site :lax})
                       (ring/set-cookie "theme" "dark" {:path "/"}))
    "/see-other" (ring/response 303 nil @{"location" "/method"})
    "/moved" (ring/response 302 nil @{"location" "/method"})
    "/keep" (ring/response 307 nil @{"location" "/echo"})
    "/relative" (ring/response 302 nil @{"location" "hello"})
    "/loop" (ring/response 302 nil @{"location" "/loop"})
    (ring/not-found)))

(def inst (server/start {:handler app :port "0" :idle-timeout 0.4}))
(def base (string "http://127.0.0.1:" (inst :port)))

# -- one-shot requests ---------------------------------------------------

(client/reset-stats!)

(def r (client/get (string base "/hello")))
(assert (= 200 (r :status)))
(assert (= "hello" (r :body)))
(assert (= "text/plain; charset=utf-8" (get-in r [:headers "content-type"])))

(def echoed (client/post (string base "/echo") "payload"
                         {:headers {"content-type" "application/json"}}))
(assert (= "payload" (echoed :body)) "a body goes out and comes back")
(assert (= "application/json" (get-in echoed [:headers "content-type"])))

(def chunked (client/get (string base "/chunked")))
(assert (= "onetwothree" (chunked :body)) "chunked framing is reassembled")

(def empty-resp (client/get (string base "/empty")))
(assert (= 204 (empty-resp :status)))
(assert (nil? (empty-resp :body)) "a 204 has no body to read and the client does not wait for one")

(def failed (client/get (string base "/boom")))
(assert (= 500 (failed :status)) "a 500 is an answer, not an error")

# -- keep-alive ----------------------------------------------------------

(client/reset-stats!)
(def c (client/open {:url base :timeout 2}))
(each _ (range 5)
  (assert (= "hello" ((client/send! c {:method :get :target "/hello"}) :body))))
(assert (= 1 ((client/stats) :connects))
        "five requests on one socket — the connection is reused, not reopened")
(assert (= 5 ((client/stats) :responses)))

# the peer closing an idle socket is the one failure the client repeats
# by itself: the request reached nobody
(def closing (client/send! c {:method :get :target "/close"}))
(assert (= "bye" (closing :body)))
(assert (nil? (c :conn)) "a Connection: close response retires the socket")
(assert (= "hello" ((client/send! c {:method :get :target "/hello"}) :body))
        "and the next request opens a new one")

# an idle timeout on the server closes the parked socket under us
(client/reset-stats!)
(assert (= "hello" ((client/send! c {:method :get :target "/hello"}) :body)))
(ev/sleep 0.6)
(assert (= "hello" ((client/send! c {:method :get :target "/hello"}) :body))
        "a socket the peer dropped while idle is reopened and the request repeated")
(assert (= 1 ((client/stats) :reconnects)) "once, and counted")
(assert (zero? ((client/stats) :failures)) "and it is not a failure")
(client/close! c)

# -- limits and timeouts -------------------------------------------------

(client/reset-stats!)
(def [ok2 err2] (protect (client/get (string base "/slow") {:timeout 0.1})))
(assert (not ok2) "a timeout is an error, not an empty answer")
(assert (string/find "timed out" (string err2)))
(assert (= 1 ((client/stats) :timeouts)))
(assert (= 1 ((client/stats) :failures)))

(def [ok3 err3] (protect (client/get (string base "/big") {:max-body 100})))
(assert (not ok3) "a body past :max-body is refused rather than allocated")
(assert (string/find ":max-body" (string err3)))

(def [ok4 err4] (protect (client/get "http://127.0.0.1:9/nothing" {:timeout 1})))
(assert (not ok4) "a refused connection names the authority")
(assert (string/find "cannot connect" (string err4)))

# -- what obs reads ------------------------------------------------------

(client/reset-stats!)
(client/get (string base "/hello"))
(def s (client/stats))
(assert (= 1 (s :requests)))
(assert (= 1 (s :responses)))
(assert (pos? (s :bytes-out)))
(assert (pos? (s :bytes-in)))
(assert (>= (s :request-us) 0) "and the time it took, which is what the exporter's duration metric is")

# -- methods -------------------------------------------------------------

# the kernel lowercases the method it parsed, so that is what comes back
(each [f expected]
  [[client/get "get"] [client/head "head"] [client/options "options"]
   [client/delete "delete"]]
  (def resp (f (string base "/method")))
  (assert (= 200 (resp :status)))
  (unless (= "head" expected)
    (assert (= expected (resp :body))
            (string "the client speaks " expected ", not only GET and POST"))))

(assert (nil? ((client/head (string base "/method")) :body))
        "a HEAD reads the headers and does not wait for a body the server will not send")

(each [f expected]
  [[client/post "post"] [client/put "put"] [client/patch "patch"]]
  (assert (= expected ((f (string base "/method") "x") :body))))

(assert (= "purge" ((client/request {:url (string base "/method") :method :purge}) :body))
        "and any method at all — the wire takes a token, not an enum")

# -- query, form and files as data ---------------------------------------

(def q (client/get (string base "/query") {:query {:tag "cat dog" :page 2}}))
(assert (string/find `"tag" "cat dog"` (q :body))
        "the query is pairs the client encodes, not a string the caller escaped")
(assert (string/find `"page" "2"` (q :body)))

(def q2 (client/request {:url (string base "/query?first=1") :query {:second 2}}))
(assert (and (string/find `"first" "1"` (q2 :body)) (string/find `"second" "2"` (q2 :body)))
        "and it adds to a query the URL already carries rather than replacing it")

(def form (client/post (string base "/form") nil {:form {:name "Ada" :lang "janet"}}))
(assert (string/has-prefix? "application/x-www-form-urlencoded|" (form :body))
        "a :form body brings its own content type")
(assert (string/find "lang=janet" (form :body)))
(assert (string/find "name=Ada" (form :body)))

(def uploaded (client/post (string base "/upload") nil
                           {:multipart [{:name "title" :value "cat"}
                                        {:name "avatar" :filename "me.png"
                                         :content-type "image/png" :value "\x89PNG"}]}))
(assert (string/find `"title" "cat"` (uploaded :body))
        "a file goes up as multipart, framed by the same module the server parses it with")

(def [ok5 err5] (protect (client/request {:url (string base "/form")
                                          :method :post :body "x" :form {:y 1}})))
(assert (not ok5) "two bodies is a mistake the wire cannot represent")
(assert (string/find "one body" (string err5)))

# -- cookies -------------------------------------------------------------

(def sent (client/get (string base "/cookies") {:cookies {"session" "abc" "theme" "dark"}}))
(assert (string/find `"session" "abc"` (sent :body)) "cookies go out as names and values")
(assert (string/find `"theme" "dark"` (sent :body)))

(def setter (client/get (string base "/set-cookies")))
(def jar (client/cookies setter))
(assert (= 2 (length jar)) "every Set-Cookie is parsed, not only the first")
(def session (find |(= "session" ($ :name)) jar))
(assert (= "abc def" (session :value)) "and the value is decoded")
(assert (= 3600 (session :max-age)))
(assert (session :http-only))
(assert (= :lax (session :same-site))
        "attributes and all — without them a caller cannot tell a session cookie from a permanent one")
(assert (= "abc def" ((client/cookie-values setter) "session"))
        "and the name -> value table is what goes back out on the next request")

(def round-trip (client/get (string base "/cookies")
                            {:cookies (client/cookie-values setter)}))
(assert (string/find `"session" "abc def"` (round-trip :body))
        "a four-line jar is all the caller needs, and the policy stays theirs")

(def kept (client/open {:url base :cookies {"session" "abc"}}))
(assert (string/find `"session" "abc"` ((client/send! kept {:target "/cookies"}) :body))
        "a client can carry cookies for every request on it")
(client/close! kept)

# -- headers on the way back ---------------------------------------------

(assert (= "text/plain; charset=utf-8" (client/header setter "Content-Type"))
        "a header is read by name, in any case")
(assert (= 2 (length (client/header-values setter "set-cookie")))
        "and a repeated header keeps all of its values")

# -- redirects, when asked -----------------------------------------------

(def not-followed (client/get (string base "/moved")))
(assert (= 302 (not-followed :status))
        "a 30x comes back as a 30x: following one is a policy the caller owns")
(assert (client/redirect? not-followed))

(client/reset-stats!)
(def followed (client/post (string base "/moved") "payload" {:follow 3}))
(assert (= 200 (followed :status)))
(assert (= "get" (followed :body))
        "a 302 turns a POST into a GET, the way every other client resolved this decades ago")
(assert (= (string base "/method") (followed :url)) "the response says which URL answered")
(assert (= [(string base "/moved")] (tuple ;(followed :redirects)))
        "and which ones it went through")
(assert (= 1 ((client/stats) :redirects)))

(assert (= "get" ((client/post (string base "/see-other") "payload" {:follow 3}) :body))
        "a 303 is always a GET — the status exists to say the answer is elsewhere")

(def preserved (client/post (string base "/keep") "payload" {:follow 3}))
(assert (= "payload" (preserved :body))
        "a 307 keeps the method and the body, which is why it was added")

(assert (= "hello" ((client/get (string base "/relative") {:follow 2}) :body))
        "a relative Location resolves against the URL it came from")

(def [ok6 err6] (protect (client/get (string base "/loop") {:follow 2})))
(assert (not ok6) "running out of hops is an error, not a 30x pretending to be an answer")
(assert (string/find "redirected more than 2 times" (string err6)))

# a redirect that crosses to another origin must not carry credentials
(def other (server/start {:handler (fn [req] (ring/text 200 (string/format "%j" (freeze (req :headers)))))
                          :port "0"}))
(def elsewhere (string "http://127.0.0.1:" (other :port) "/landed"))
(def sender (server/start {:handler (fn [_] (ring/response 302 nil @{"location" elsewhere}))
                           :port "0"}))
(def crossed (client/get (string "http://127.0.0.1:" (sender :port) "/go")
                         {:follow 2
                          :headers {"authorization" "Bearer hunter2"
                                    "x-trace" "keep-me"}
                          :cookies {"session" "abc"}}))
(assert (not (string/find "hunter2" (crossed :body)))
        "the Authorization header does not follow a redirect to another host")
(assert (not (string/find "session=abc" (crossed :body))) "and neither do the cookies")
(assert (string/find "keep-me" (crossed :body))
        "while an ordinary header does — dropping everything would break the caller's own protocol")
(server/stop sender)
(server/stop other)

# -- composing urls ------------------------------------------------------

(assert (= "http://example.test:4318/v1/traces?tenant=acme"
           (client/url {:host "example.test" :port 4318 :path "/v1/traces"
                        :query {:tenant "acme"}}))
        "url is the inverse of parse-url")
(assert (= "http://example.test/x" (client/url {:host "example.test" :port 80 :path "x"}))
        "and it leaves out a port the scheme already implies")

(assert (= "http://a.test/one/three" (client/resolve-url "http://a.test/one/two?x=1" "three")))
(assert (= "http://a.test/root" (client/resolve-url "http://a.test/one/two" "/root")))
(assert (= "http://b.test/p" (client/resolve-url "http://a.test/one/two" "//b.test/p")))
(assert (= "http://c.test/z" (client/resolve-url "http://a.test/one/two" "http://c.test/z")))

(server/stop inst)
