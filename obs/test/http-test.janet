# void/obs-http through the inject path (ADR-0017): RED off the route
# table, the root span continuing an inbound traceparent, queue time,
# and the three operator endpoints.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/obs :as obs)
(import void/obs/metrics :as metrics)
(import void/obs/trace :as trace)
(import void/obs/http :as obshttp)
(require "void/http/init")
(require "void/obs/init")
(require "void/obs/http")

(log/set-level! nil :error)

(defn hello [req] (ring/text 200 "hello"))

(defn traced [req]
  # what the handler sees of the request's own trace, or that there is
  # none — the default composition exports nothing and builds no span
  (def span (trace/current))
  (ring/text 200 (if span
                   (string (span :trace-id) " " (req :trace-id)
                           " parent=" (or (span :parent-id) "-")
                           " sampled=" (span :sampled))
                   "no span")))

(defn boom [req] (error "handler exploded"))

(def app-routes
  (router/routes {}
    (router/GET "/hello" 'hello {:name :hello})
    (router/GET "/orders/:id" 'traced
      {:name :orders/show :void.obs/name "orders.show"})
    (router/GET "/quiet" 'traced {:name :quiet :void.obs/sample-rate 0})
    (router/GET "/boom" 'boom {:name :boom})))

(def app
  (plugin/manifest 'test/obs-app
    :version "0.0.1"
    :requires {:void/http ">=0.0.1"}
    :contributes {:void.http/route-source
                  [{:name :test/obs-app :routes app-routes
                    :env (router/env-ref (curenv))}]}))

(defn- start [extra &opt obs-extra]
  (test/start! {:plugins [:void/http :void/obs :void/obs-http app]
                :only [:http/kernel :obs/registry :obs/tracer]
                :config {:cli (merge {:log {:level :error}
                                      :obs (merge {:runtime {:enabled false}}
                                                  (or obs-extra {}))}
                                     extra)}}))

(defn- body [resp] (string (or (resp :body) "")))

# -- RED off the route table --------------------------------------------

(def boot (start {}))
(def c (test/client boot))
(metrics/reset!)

(test/inject c {:uri "/hello"})
(test/inject c {:uri "/hello"})
(assert (= "no span" (body (test/inject c {:uri "/orders/42"})))
        "a request nothing traces runs without a span at all")
(test/inject c {:uri "/nowhere"})
(test/inject c {:method :post :uri "/hello"})

(assert (= 2 (metrics/value obshttp/requests ["hello" :get 200]))
        "requests are counted by route, method and status — the method and the status go in as the keyword and the number they are, and the exposition turns them into text at scrape time")
(assert (= 1 (metrics/value obshttp/requests ["orders.show" :get 200]))
        "and the route label is :void.obs/name where a route sets one")
(assert (= 1 (metrics/value obshttp/requests ["(unmatched)" :get 404]))
        "a request that matched no route is labelled by a constant, never by the path somebody probed — that is the whole cardinality argument")
(assert (= 1 (metrics/value obshttp/requests ["(unmatched)" :post 405]))
        "and a 405 is the same route label with the method that was refused")

# the wire accepts a method as any token of capitals and the server
# interns it — collapsed to :other before it becomes a label or a
# memo-cache key, or a loop of invented methods grows this process
# forever (the metric itself would cap at 1000 series and refuse;
# the cache and the keyword pool it pins would not)
(test/inject c {:method :brew :uri "/hello"})
(test/inject c {:method :yolo :uri "/hello"})
(assert (= 2 (metrics/value obshttp/requests ["(unmatched)" :other 405]))
        "two invented methods are one series — :other, not themselves")

(assert (= :get (obshttp/normalize-method :get)))
(assert (= :trace (obshttp/normalize-method :trace)))
(assert (= :other (obshttp/normalize-method :brew)))
(assert (= :other (obshttp/normalize-method (keyword (string/repeat "A" 200))))
        "however long the token was")

(def d (metrics/value obshttp/duration ["hello" :get]))
(assert (= 2 (d :count)) "durations land in the histogram beside them")
(assert (pos? (d :sum)))
(assert (pos? (get (metrics/value obshttp/queue) :count))
        "and every request carries the queue time it waited before this process started on it")

(assert (zero? ((obshttp/in-flight :collect)))
        "in-flight is back to zero once the requests are done — it is a counter the gauge collects, not a metric write on every request")

(def err (test/inject c {:uri "/boom"}))
(assert (= 500 (err :status)))
(assert (= 1 (metrics/value obshttp/requests ["boom" :get 500]))
        "an exception is counted as the status the client actually got — the :on-response stage sees the rendered response, where a wrapper inside the chain would only see a raised error")

# -- the root span -------------------------------------------------------

(assert (not (obshttp/tracing? @{:headers @{}}))
        "with no exporter configured and no inbound traceparent, a request gets no span: a span nothing reads is the largest single item in what instrumentation costs (SPEC §8.2)")
(assert (obshttp/tracing? @{:headers @{"traceparent" "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}})
        "and a caller who is tracing this request is a consumer")

(def carried
  (body (test/inject c {:uri "/orders/1"
                        :headers {"traceparent" "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"}})))
(assert (string/has-prefix? "4bf92f3577b34da6a3ce929d0e0e4736" carried)
        "an inbound W3C traceparent continues the caller's trace")
(assert (string/find "parent=00f067aa0ba902b7" carried))
(assert (string/find "sampled=true" carried))

(test/stop! boot)

# -- spans that something consumes --------------------------------------

(def traced-boot (start {} {:trace {:always true}}))
(def tc (test/client traced-boot))

(def plain (body (test/inject tc {:uri "/orders/1"})))
(assert (string/find "parent=-" plain)
        "[:obs :trace :always] builds the span whether or not anything exports it")
(assert (string/find "sampled=true" plain))
(def ids (string/split " " plain))
(assert (= (ids 0) (ids 1)) "and the handler sees the same ids on the request table")

(def unsampled
  (body (test/inject tc {:uri "/orders/1"
                         :headers {"traceparent" "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00"}})))
(assert (string/find "sampled=false" unsampled)
        "a caller that decided not to trace this request is honoured too")

(assert (string/find "sampled=false" (body (test/inject tc {:uri "/quiet"})))
        ":void.obs/sample-rate 0 keeps a route out of the traces")

(test/stop! traced-boot)

(def boot-b (start {}))
(def c (test/client boot-b))

# -- the endpoints -------------------------------------------------------

(def m (test/inject c {:uri "/metrics"}))
(assert (= 200 (m :status)))
(assert (string/has-prefix? "text/plain; version=0.0.4" (get-in m [:headers "content-type"])))
(assert (string/find "void_http_requests_total{" (body m)))
(assert (string/find "void_obs_process_uptime_seconds" (body m))
        "the runtime gauges are in the same exposition")

(def h (test/inject c {:uri "/health"}))
(assert (= 200 (h :status)))
(def hv (test/json h))
(assert (= "up" (hv :status)))
(assert (get-in hv [:components :http/kernel]) "every running component reports")
(assert (get-in hv [:components :obs/registry]))

(def r (test/inject c {:uri "/ready"}))
(assert (= 200 (r :status)))
(assert (= "ready" ((test/json r) :status)))

(assert (get-in (plugin/extension boot :void.http/route-meta-key)
                [:void.obs/endpoint])
        "the endpoints declare the key that keeps them answering while the process sheds")
(test/stop! boot)

# -- draining ------------------------------------------------------------

(def boot2 (start {}))
(def c2 (test/client boot2))
(assert (= 200 ((test/inject c2 {:uri "/ready"}) :status)))
(test/stop! boot2)
(assert (= 503 ((test/inject c2 {:uri "/ready"}) :status))
        "a draining process says so on /ready before its connections are cut — that is what takes it out of the load balancer in time")

# -- the token -----------------------------------------------------------

(def boot3 (start {:obs-http {:token "s3cret"}}))
(def c3 (test/client boot3))
(assert (= 401 ((test/inject c3 {:uri "/metrics"}) :status))
        "a metrics endpoint is a map of the inside of a process")
(assert (= 200 ((test/inject c3 {:uri "/metrics"
                                 :headers {"authorization" "Bearer s3cret"}})
                :status)))
(assert (= 401 ((test/inject c3 {:uri "/health"}) :status))
        "the token guards /health too — the folded report maps the inside of the process, endpoint addresses included")
(assert (= 200 ((test/inject c3 {:uri "/health"
                                 :headers {"authorization" "Bearer s3cret"}})
                :status)))
(assert (= 200 ((test/inject c3 {:uri "/ready"}) :status))
        "while /ready stays bare: it is the boolean an orchestrator polls, and nothing else")
(test/stop! boot3)

# -- turned off ----------------------------------------------------------

(def boot4 (start {:obs-http {:endpoints false}}))
(def c4 (test/client boot4))
(each path ["/metrics" "/health" "/ready"]
  (assert (= 404 ((test/inject c4 {:uri path}) :status))
          "with the endpoints off the routes answer 404 — the table is built from static contributions, so off means refuses, not vanishes"))
(test/stop! boot4)

(print "http-test ok")
