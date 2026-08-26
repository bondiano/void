# End-to-end prefork (ADR-0010): a real void/run! application with
# :workers 2 — the master supervises, both workers bind the same port
# through SO_REUSEPORT and serve requests; SIGTERM drains the whole
# tree. Skipped nothing: this is the ROADMAP 1.1 "полностью" item.

(import ../test-support/paths)
(import void/http/wire :as wire)

# a free port: bind an ephemeral listener, note the number, release it
(def probe (net/listen "127.0.0.1" "0"))
(def port (get (net/localname probe) 1))
(:close probe)

(def master
  (os/spawn ["janet" "test-support/fixtures/prefork-app.janet"] :ep
            (merge (os/environ) {"VOID_TEST_PORT" (string port)})))

(defn- try-get [path]
  (def [ok resp]
    (protect
      (with [conn (net/connect "127.0.0.1" (string port))]
        (:write conn (string "GET " path " HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
        (def buf @"")
        (while (net/read conn 4096 buf 2))
        buf)))
  (when ok resp))

# wait for the workers to boot (two full janet processes)
(var up nil)
(def deadline (+ (os/clock :monotonic) 15))
(while (and (nil? up) (< (os/clock :monotonic) deadline))
  (set up (try-get "/worker"))
  (unless up (ev/sleep 0.2)))
(assert up "a worker starts serving the shared port")

# requests are served by actual workers, not the master
(def workers @{})
(for i 0 10
  (def raw (try-get "/worker"))
  (assert raw "request served")
  (def head (wire/parse-response-head (buffer raw)))
  (assert (= 200 (head :status)))
  (def id (in (peg/match '(* (thru "worker=") '(some :d)) raw) 0))
  (assert id "response names a worker index")
  (put workers id true))
(assert (pos? (length workers)) "responses come from prefork workers")

# SIGTERM the master: supervised workers drain and exit with it
(os/proc-kill master false :term)
(def code (os/proc-wait master))
(assert (zero? code) (string "master exits cleanly on SIGTERM, got " code))

# the shared port is released by every worker
(var still-up nil)
(def gone-deadline (+ (os/clock :monotonic) 5))
(while (and (nil? still-up) (< (os/clock :monotonic) gone-deadline))
  (if (try-get "/worker")
    (ev/sleep 0.2)
    (set still-up :gone)))
(assert (= :gone still-up) "no worker keeps serving after the master stops")

(print "prefork-e2e-test ok")
