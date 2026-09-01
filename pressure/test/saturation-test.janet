(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import void/http/wire :as wire)
(import void/pressure :as pressure)
(require "void/pressure/http")

(log/set-level! "void" :error)

# The wave-2 exit criterion (ADR-0019): a real server, a real
# blocked loop, a real socket. Everything else in this suite feeds
# samples in by hand — which is the only way to test a threshold
# without testing a clock — so exactly one test has to close the loop
# and show that the numbers the sampler reads are the ones the process
# actually produces, and that the 503 comes out of a port.
#
# The overload is a fiber that holds the loop for ~25 ms at a time.
# That is what saturation looks like from inside an ev process, whether
# it comes from a synchronous FFI call, a CPU-bound handler or a GC
# pause: nothing else runs, and every request in flight is already late.

(var served 0)

(defn work [req]
  (++ served)
  (ring/text 200 "worked"))

(defn health [req]
  (ring/text 200 "ok"))

(def app-routes
  (router/routes {}
    (router/GET "/work" 'work {:name :work})
    (router/GET "/ops/health" 'health {:name :health :void.pressure/exempt true})))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/pressure-http ">=0.0.1"}
    :contributes {:void.http/route-source [{:name :test/app
                                            :routes app-routes
                                            :env (router/env-ref (curenv))}]}))

# a free port: bind an ephemeral listener, note the number, release it
(def probe (net/listen "127.0.0.1" "0"))
(def port (get (net/localname probe) 1))
(:close probe)

(def events @[])
(pressure/listen! :test (fn [ev] (array/push events (ev :event))))

(def boot
  (plugin/start!
    {:plugins [:void/http :void/pressure :void/pressure-http app-manifest]
     :profile :test
     :config {:env @{}
              :cli {:log {:level :error}
                    :http {:port port :access-log false}
                    :pressure {:sample-interval 0.02
                               :max-loop-lag 10
                               :recovery-samples 2}
                    :pressure-http {:retry-after 2}}}}))

(defn- request [path]
  (def [ok resp]
    (protect
      (with [conn (net/connect "127.0.0.1" (string port))]
        (:write conn (string "GET " path " HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n"))
        (def buf @"")
        (while (net/read conn 4096 buf 5))
        buf)))
  (when ok (string resp)))

(defn- head [path]
  (when-let [raw (request path)]
    [(wire/parse-response-head (buffer raw)) raw]))

(defn- await [pred timeout what]
  (def deadline (+ (os/clock :monotonic) timeout))
  (var got nil)
  (while (and (not got) (< (os/clock :monotonic) deadline))
    (set got (pred))
    (unless got (ev/sleep 0.02)))
  (assert got what)
  got)

(defer (do (pressure/unlisten! :test) (plugin/shutdown! boot 5))

  # the process is healthy and serving
  (def [ok200 _] (head "/work"))
  (assert (= 200 (ok200 :status)) "a quiet process serves")

  # -- saturate ----------------------------------------------------------

  (var spinning true)
  (ev/go
    (fn overload []
      (while spinning
        # the hold is randomised on purpose. A fixed one phase-locks
        # with the sampler's own interval — the sampler's timer expires
        # at the same point of every spin and reads the same lag
        # forever, which is a beautiful artifact and a useless test.
        # Real load has no such courtesy.
        (def until (+ (os/clock :monotonic) 0.02 (* 0.05 (math/random))))
        (while (< (os/clock :monotonic) until) (math/sqrt 2))
        (ev/sleep 0.001))))

  (await pressure/under-pressure? 10
         "a loop held for 25 ms at a time is over a 10 ms lag limit — the sampler sees the process, not a metric about it")
  (assert (index-of :high events) "and says so once, on the edge")

  (set served 0)
  (def [shed raw] (head "/work"))
  (assert (= 503 (shed :status)) "requests are refused")
  (assert (= "2" (get-in shed [:headers "retry-after"]))
          "with Retry-After, so the client that comes back does not make it worse")
  (assert (zero? served) "and the handler never ran")

  (def [alive _] (head "/ops/health"))
  (assert (= 200 (alive :status))
          "/ops/health is exempt and stays up — the load balancer must be able to tell a shedding worker from a dead one")

  (assert (pos? ((pressure/status) :shed)) "the refusals are counted")

  # -- and back ----------------------------------------------------------

  (set spinning false)
  (await |(not (pressure/under-pressure?)) 10
         "with the load gone the process comes back — after the clean samples the hysteresis asks for")
  (assert (index-of :recovered events) "and fires :recovered once")

  (set served 0)
  (def [again _] (head "/work"))
  (assert (= 200 (again :status)) "and serves again")
  (assert (= 1 served)))

(print "saturation-test ok")
