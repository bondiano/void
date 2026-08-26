# Smoke the bench mini-apps through the runner's own lifecycle helpers:
# spawn, wait for the port, raw HTTP round-trip, graceful stop. No load
# generator involved — the методика runs are CI's bench workflow, this
# only proves the apps and the orchestration work.
(import ../test-support/paths)
(import void/bench/runner :as runner)

(defn- http-request [port req]
  (def s (net/connect "127.0.0.1" (string port)))
  (defer (:close s)
    (net/write s req)
    (def buf @"")
    (var chunk (net/read s 4096))
    (while chunk
      (buffer/push buf chunk)
      (set chunk (net/read s 4096)))
    (string buf)))

# -- B0 plaintext --------------------------------------------------------

(def b0 (runner/wait-ready
          (runner/start-target :test-b0
                               {:port 8190
                                :cmd "exec janet apps/b0-plaintext/main.janet"})
          30))
(defer (runner/stop-target b0)
  (def resp (http-request 8190
                          "GET / HTTP/1.1\r\nhost: bench\r\nconnection: close\r\n\r\n"))
  (assert (string/has-prefix? "HTTP/1.1 200" resp) "b0 answers 200")
  (assert (string/find "Hello, World!" resp) "b0 body is the plaintext hello"))

# -- B1 JSON echo --------------------------------------------------------

(def payload (slurp "payloads/b1-order.json"))

(def b1 (runner/wait-ready
          (runner/start-target :test-b1
                               {:port 8191
                                :cmd "exec janet apps/b1-json-echo/main.janet"})
          30))
(defer (runner/stop-target b1)
  (def resp
    (http-request 8191
                  (string "POST /echo HTTP/1.1\r\nhost: bench\r\n"
                          "content-type: application/json\r\n"
                          "content-length: " (length payload) "\r\n"
                          "connection: close\r\n\r\n" payload)))
  (assert (string/has-prefix? "HTTP/1.1 200" resp) "b1 echoes 200")
  (assert (string/find "481516" resp) "b1 echoes the order id")
  (assert (string/find "KB-0042-BLK" resp) "b1 echoes the items")

  (def bad
    (http-request 8191
                  (string "POST /echo HTTP/1.1\r\nhost: bench\r\n"
                          "content-type: application/json\r\n"
                          "content-length: 15\r\n"
                          "connection: close\r\n\r\n"
                          `{"id": "nope"}` " ")))
  (assert (string/has-prefix? "HTTP/1.1 422" bad)
          "b1 rejects a schema-violating body with 422")
  (assert (string/find "application/problem+json" bad)
          "the rejection is problem+json"))

(print "apps-test ok")
