# The HTTP client: URL parsing, the bytes it writes, and every
# response framing the kernel can answer with — driven against this
# package's own server, which is the only honest counterpart for it.

(import ../test-support/paths)
(import void/http/client :as client)
(import void/http/server :as server)
(import void/http/ring :as ring)

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
(assert (not ok) "there is no TLS in void (ADR-0010)")
(assert (string/find "ADR-0010" (string err))
        "and the error says what to do instead rather than failing at connect time")

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

(server/stop inst)
