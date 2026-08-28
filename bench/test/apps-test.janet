# Smoke the bench mini-apps through the runner's own lifecycle helpers:
# spawn, wait for the port, raw HTTP round-trip, graceful stop. No load
# generator involved — the методика runs are CI's bench workflow, this
# only proves the apps and the orchestration work.
(import ../test-support/paths)
(import spork/json)
(import void/bench/runner :as runner)
(import void/bench/pg :as pg)

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
  (assert (string/find "Hello, World!" resp) "b0 body is the plaintext hello")

  # -- the runtime probe (§8.2 loop-lag / GC budgets) -------------------

  (def stats (runner/read-probe 8190 true))
  (assert stats "an app carrying bench/probe answers the runner's probe read")
  (assert (pos? (stats :samples)) "with samples it took while it was up")
  (assert (number? (get-in stats [:loop-lag :p99]))
          "and a loop-lag distribution — the only place §8.2's loop-lag and GC budgets can be read from")
  (def after-reset (runner/read-probe 8190))
  (assert (< (after-reset :samples) (stats :samples))
          "?reset=1 opens a fresh window, which is how the runner brackets the fixed-rate runs"))

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

# -- B2 / B3: the database benchmarks ------------------------------------
#
# They need a server and say so: without one they skip loudly, exactly
# as the runner does, because a benchmark that quietly measures nothing
# is worse than one that did not run.

(if-not (pg/available?)
  (printf "b2/b3 smoke: SKIPPED (set %s or %s to a conninfo)"
          pg/env-var pg/fallback-env-var)
  (do
    (def b2 (runner/wait-ready
              (runner/start-target :test-b2
                                   {:port 8192
                                    :cmd "exec janet apps/b2-pg-query/main.janet"})
              60))
    (defer (runner/stop-target b2)
      (def resp (http-request 8192
                              "GET /db HTTP/1.1\r\nhost: bench\r\nconnection: close\r\n\r\n"))
      (assert (string/has-prefix? "HTTP/1.1 200" resp) "b2 answers 200")
      (def body (json/decode (string/slice resp (+ 4 (string/find "\r\n\r\n" resp))) true))
      (assert (and (number? (body :id)) (number? (body :number)) (string? (body :label)))
              "b2 returns one seeded row — the table is created and filled by the app itself"))

    (def b3 (runner/wait-ready
              (runner/start-target :test-b3
                                   {:port 8193
                                    :cmd "exec janet apps/b3-pg-ssr/main.janet"})
              60))
    (defer (runner/stop-target b3)
      (def resp (http-request 8193
                              "GET /rows HTTP/1.1\r\nhost: bench\r\nconnection: close\r\n\r\n"))
      (assert (string/has-prefix? "HTTP/1.1 200" resp) "b3 answers 200")
      (assert (string/find "text/html" resp) "with server-rendered HTML")
      (def body (string/slice resp (+ 4 (string/find "\r\n\r\n" resp))))
      (assert (string/has-prefix? "<!DOCTYPE html>" body))
      # §8.2 names ~15KB, and a payload that quietly halves would make
      # the B3 budget a budget for a different benchmark
      (assert (< 14000 (length body) 17000)
              (string/format "b3 renders ~15KB (§8.2), got %d bytes" (length body))))))

(print "apps-test (db) ok")
