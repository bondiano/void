(import ../test-support/paths)
(import void/http/server :as server)
(import void/http/ring :as ring)
(import void/http/wire :as wire)

# -- test app ------------------------------------------------------------

(defn- app [req]
  (case (req :path)
    "/hello" (ring/text 200 "hello")
    "/echo" (ring/text 200 (string (req :body)))
    "/query" (ring/text 200 (string/format "%j" (freeze (req :query))))
    "/chunked" (ring/response 200 ["one" "two" "three"]
                              @{"content-type" "text/plain"})
    "/sse" (ring/sse (coro
                       (yield "first")
                       (ev/sleep 0.05)
                       (yield "second")))
    "/slow" (do (ev/sleep 0.3) (ring/text 200 "slow done"))
    "/boom" (error "unguarded")
    "/nil" nil
    "/go" (ring/redirect "/hello")
    "/gone" (ring/response 204)
    (ring/not-found)))

(def inst
  (server/start
    {:handler app
     :port "0"
     :max-header 512
     :max-body 64
     :read-timeout 0.3
     :idle-timeout 0.5
     :limits-fn (fn [method path]
                  (case path
                    "/slow" {:timeout 0.1}
                    "/echo" {:max-body 32}
                    nil))}))

(def port (string (inst :port)))
(assert (pos? (inst :port)) "ephemeral port resolved")

(defn- connect [] (net/connect "127.0.0.1" port))

(def cbuf
  "Client-side read buffer for the persistent connection below —
  pipelined responses coalesce, so leftover bytes must survive between
  read-response calls."
  @"")

(defn- read-response
  "Read one response off the connection: [head body-string]. Consumes
  the response from `buf` (default cbuf), leaving any pipelined rest."
  [conn &opt buf]
  (default buf cbuf)
  (var head nil)
  (while (nil? head)
    (when (nil? (wire/parse-response-head buf))
      (assert (net/read conn 4096 buf 2) "connection closed before a response head"))
    (set head (wire/parse-response-head buf)))
  (assert (not= :error head) "response head parses")
  (def cl (get-in head [:headers "content-length"]))
  (def need (+ (head :head-size) (if cl (scan-number cl) 0)))
  (while (< (length buf) need)
    (assert (net/read conn 4096 buf 2)))
  (def body (when cl (string/slice buf (head :head-size) need)))
  (def rest (string/slice buf need))
  (buffer/clear buf)
  (buffer/push buf rest)
  [head body])

(defn- fetch
  "One-shot request on its own connection; returns [head raw-rest]."
  [raw]
  (def conn (net/connect "127.0.0.1" port))
  (defer (:close conn)
    (:write conn raw)
    (def buf @"")
    (while (net/read conn 4096 buf 2))
    (def head (wire/parse-response-head buf))
    [head (if (dictionary? head) (string/slice buf (head :head-size)) nil)]))

# -- basics + keep-alive -------------------------------------------------

(def conn (connect))
(:write conn "GET /hello HTTP/1.1\r\nHost: t\r\n\r\n")
(def [h1 b1] (read-response conn))
(assert (= 200 (h1 :status)))
(assert (= "hello" b1))
(assert (= "5" (get-in h1 [:headers "content-length"])))

# same connection serves the next request (keep-alive)
(:write conn "GET /query?a=1&b=x HTTP/1.1\r\nHost: t\r\n\r\n")
(def [h2 b2] (read-response conn))
(assert (= 200 (h2 :status)) "keep-alive: second request on one connection")
(assert (string/find "\"a\" \"1\"" b2) "query string is parsed")

# pipelining: two requests in one write, two responses in order
(:write conn (string "GET /hello HTTP/1.1\r\nHost: t\r\n\r\n"
                     "GET /nope HTTP/1.1\r\nHost: t\r\n\r\n"))
(def [p1 pb1] (read-response conn))
(def [p2 _] (read-response conn))
(assert (= "hello" pb1))
(assert (= 404 (p2 :status)) "handler-level 404 for unknown path")
(:close conn)

# -- an empty body is framed, or a keep-alive client waits forever -------
#
# A response with no body and no Content-Length ends when the
# connection does (RFC 9112 §6.3). On a keep-alive connection that is a
# client hanging until its own timeout — and `ring/redirect` has no
# body, so it is every redirect an application ever sends. The bodyless
# statuses are the exception: 204 must carry no Content-Length at all.

(def kconn (connect))
(:write kconn "POST /go HTTP/1.1\r\nHost: t\r\n\r\n")
(def [hgo bgo] (read-response kconn))
(assert (= 302 (hgo :status)))
(assert (= "/hello" (get-in hgo [:headers "location"])))
(assert (= "0" (get-in hgo [:headers "content-length"]))
        "a bodyless redirect says so with Content-Length: 0")
(assert (or (nil? bgo) (empty? bgo)))

# and the proof that it is framed: the same connection answers again,
# which a client could not have got to if it were still waiting for the
# redirect's body
(:write kconn "GET /hello HTTP/1.1\r\nHost: t\r\n\r\n")
(def [hafter bafter] (read-response kconn))
(assert (= "hello" bafter) "the connection carries on after an empty response")
(:close kconn)

(def [h204 _] (fetch "GET /gone HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
(assert (= 204 (h204 :status)))
(assert (nil? (get-in h204 [:headers "content-length"]))
        "204 carries no Content-Length — RFC 9110 §8.6 forbids one")

# -- HTTP/1.0 closes by default ------------------------------------------

(def [h10 b10] (fetch "GET /hello HTTP/1.0\r\n\r\n"))
(assert (= 200 (h10 :status)))
(assert (= "close" (get-in h10 [:headers "connection"]))
        "1.0 without keep-alive closes")

# connection: close honored on 1.1
(def [hc _] (fetch "GET /hello HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
(assert (= "close" (get-in hc [:headers "connection"])))

# -- request bodies ------------------------------------------------------

(def [he be] (fetch (string "POST /echo HTTP/1.1\r\nHost: t\r\n"
                            "Content-Length: 5\r\nConnection: close\r\n\r\nhello")))
(assert (= "hello" be) "content-length body echoed")

(def [hch bch] (fetch (string "POST /echo HTTP/1.1\r\nHost: t\r\n"
                              "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                              "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")))
(assert (= "hello world" bch) "chunked request body echoed")

# trailers after the last chunk are consumed
(def [htr btr] (fetch (string "POST /echo HTTP/1.1\r\nHost: t\r\n"
                              "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                              "2\r\nok\r\n0\r\nx-check: 1\r\n\r\n")))
(assert (= "ok" btr) "chunked body with trailers")

# 100-continue is acknowledged
(do
  (def c (connect))
  (:write c (string "POST /echo HTTP/1.1\r\nHost: t\r\nContent-Length: 2\r\n"
                    "Expect: 100-continue\r\n\r\n"))
  (def buf @"")
  (net/read c 4096 buf 2)
  (assert (string/has-prefix? "HTTP/1.1 100 Continue\r\n\r\n" buf)
          "interim 100 arrives before the body is sent")
  (:write c "hi")
  (def rest @"")
  (while (net/read c 4096 rest 2))
  (def head (wire/parse-response-head (buffer (string/slice buf 25) rest)))
  (assert (= 200 (head :status)))
  (:close c))

# -- limits and malformed input ------------------------------------------

(def [h431 _] (fetch (string "GET /hello HTTP/1.1\r\nHost: t\r\nX-Big: "
                             (string/repeat "a" 600) "\r\n\r\n")))
(assert (= 431 (h431 :status)) "oversized head -> 431")

(def [h413 _] (fetch (string "POST /hello HTTP/1.1\r\nHost: t\r\n"
                             "Content-Length: 100\r\n\r\n" (string/repeat "b" 100))))
(assert (= 413 (h413 :status)) "global max-body -> 413")

(def [h413r _] (fetch (string "POST /echo HTTP/1.1\r\nHost: t\r\n"
                              "Content-Length: 50\r\n\r\n" (string/repeat "b" 50))))
(assert (= 413 (h413r :status)) "route max-body from :limits-fn -> 413")

(def [h400 _] (fetch "BLARG\r\n\r\n"))
(assert (= 400 (h400 :status)) "malformed head -> 400")

(def [hsmug _] (fetch (string "POST /echo HTTP/1.1\r\nHost: t\r\n"
                              "Content-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n"
                              "0\r\n\r\n")))
(assert (= 400 (hsmug :status)) "TE+CL smuggling shape -> 400")

(def [hte _] (fetch (string "POST /echo HTTP/1.1\r\nHost: t\r\n"
                            "Transfer-Encoding: gzip\r\n\r\n")))
(assert (= 501 (hte :status)) "unknown transfer-encoding -> 501")

# mid-request read timeout -> 408
(do
  (def c (connect))
  (:write c "GET /hello HTTP/1.1\r\nHost: t\r\n")   # head never finishes
  (def buf @"")
  (while (net/read c 4096 buf 2))
  (assert (= 408 ((wire/parse-response-head buf) :status)) "stalled head -> 408")
  (:close c))

# idle keep-alive connections are closed silently
(do
  (def c (connect))
  (:write c "GET /hello HTTP/1.1\r\nHost: t\r\n\r\n")
  (read-response c)
  (def buf @"")
  (while (net/read c 4096 buf 2))
  (assert (empty? buf) "idle timeout closes without bytes")
  (:close c))

# -- HEAD ----------------------------------------------------------------

(do
  (def c (connect))
  (:write c "HEAD /hello HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  (def buf @"")
  (while (net/read c 4096 buf 2))
  (def head (wire/parse-response-head buf))
  (assert (= 200 (head :status)))
  (assert (= "5" (get-in head [:headers "content-length"]))
          "HEAD keeps the GET content-length")
  (assert (= (length buf) (head :head-size)) "HEAD sends no body")
  (:close c))

# -- streaming responses -------------------------------------------------

(def [hstream raw] (fetch "GET /chunked HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
(assert (= "chunked" (get-in hstream [:headers "transfer-encoding"])))
(assert (= "3\r\none\r\n3\r\ntwo\r\n5\r\nthree\r\n0\r\n\r\n" raw)
        "iterable body streams as chunks")

# SSE: the first event arrives before the producer finishes
(do
  (def c (connect))
  (:write c "GET /sse HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  (def buf @"")
  (net/read c 4096 buf 2)
  (assert (string/find "data: first" buf) "first event streams immediately")
  (assert (not (string/find "data: second" buf)) "second event not yet produced")
  (while (net/read c 4096 buf 2))
  (assert (string/find "data: second" buf) "second event follows")
  (assert (string/find "text/event-stream" buf))
  (:close c))

# -- handler faults ------------------------------------------------------

(def [hboom _] (fetch "GET /boom HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
(assert (= 500 (hboom :status)) "unguarded panic still answers 500")

(def [hnil _] (fetch "GET /nil HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
(assert (= 500 (hnil :status)) "nil response -> 500")

(def [hslow bslow] (fetch "GET /slow HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
(assert (= 503 (hslow :status)) ":void.http/timeout via limits-fn -> 503")

# -- graceful drain ------------------------------------------------------

(def slow-conn (connect))
(:write slow-conn "GET /slow HTTP/1.1\r\nHost: t\r\nX-No-Timeout: 1\r\n\r\n")
(ev/sleep 0.05)   # in flight now
(def idle-conn (connect))
(:write idle-conn "GET /hello HTTP/1.1\r\nHost: t\r\n\r\n")
(read-response idle-conn)   # now idle in keep-alive

(server/stop inst 2)

(assert (zero? (server/connections inst)) "drain leaves no connections")
(def leftover @"")
(while (net/read idle-conn 4096 leftover 1))
(assert (empty? leftover) "idle connection dropped at drain")
(:close idle-conn)
(:close slow-conn)

(assert (not (first (protect (net/connect "127.0.0.1" port))))
        "listener is closed after stop")

(print "server-test ok")
