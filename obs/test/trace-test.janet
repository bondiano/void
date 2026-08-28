# Spans: ids, W3C trace context in and out, the sampling decision taken
# once at the root and inherited, the dyn that makes propagation free,
# and the exporters a finished sampled span reaches.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/obs/metrics :as metrics)
(import void/obs/trace :as trace)

(log/set-level! "void.obs" :error)

# -- ids -----------------------------------------------------------------

(def t1 (trace/new-trace-id))
(def t2 (trace/new-trace-id))
(assert (= 32 (length t1)) "a trace id is 16 bytes of hex, as W3C requires")
(assert (= 16 (length (trace/new-span-id))))
(assert (not= t1 t2) "and two of them differ")

# -- parsing an inbound traceparent -------------------------------------

(def valid "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
(def p (trace/parse-traceparent valid))
(assert (= "4bf92f3577b34da6a3ce929d0e0e4736" (p :trace-id)))
(assert (= "00f067aa0ba902b7" (p :parent-id)))
(assert (p :sampled) "flag 01 says the caller is tracing this request")
(assert (not ((trace/parse-traceparent
                "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")
              :sampled)))
(assert (= "4bf92f3577b34da6a3ce929d0e0e4736"
           ((trace/parse-traceparent (string/ascii-upper valid)) :trace-id))
        "hex is case-insensitive on the wire and lower-case in the process")

(each bad ["" "nonsense" "00-short-00f067aa0ba902b7-01"
           "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7"
           "ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"
           "00-00000000000000000000000000000000-00f067aa0ba902b7-01"
           "00-4bf92f3577b34da6a3ce929d0e0e4736-0000000000000000-01"]
  (assert (nil? (trace/parse-traceparent bad))
          (string "a malformed header is ignored, never an error: " bad)))
(assert (nil? (trace/parse-traceparent nil)))

# -- starting spans ------------------------------------------------------

(def root (trace/start "root" {:parent nil :sampled true}))
(assert (= 32 (length (root :trace-id))))
(assert (nil? (root :parent-id)) "a root span has no parent")
(assert (= "00-" (string/slice (trace/traceparent root) 0 3)))
(assert (string/has-suffix? "-01" (trace/traceparent root)) "and says it is sampled")

(def child (trace/start "child" {:parent root}))
(assert (= (root :trace-id) (child :trace-id)) "a child stays in its parent's trace")
(assert (= (root :span-id) (child :parent-id)))
(assert (child :sampled) "and inherits the decision — a trace is never half-exported")

(def remote (trace/start "server" {:parent nil :remote p}))
(assert (= (p :trace-id) (remote :trace-id))
        "an inbound traceparent makes this span the local root of somebody else's trace")
(assert (= (p :parent-id) (remote :parent-id)))
(assert (remote :sampled) "a caller that decided to trace this request gets the whole trace")

(def unsampled (trace/start "cold" {:parent nil :sample-rate 0}))
(assert (not (unsampled :sampled)))
(assert (string/has-suffix? "-00" (trace/traceparent unsampled)))
(assert (not ((trace/start "cold-child" {:parent unsampled}) :sampled))
        "and the no travels down too")

# -- the dyn is the propagation mechanism --------------------------------

(assert (nil? (trace/current)) "outside a span there is no current span")
(assert (= {} (trace/context)) "and no correlation ids to put in the log context")

(metrics/reset! :void.obs/spans-total)
(def seen @[])
(trace/set-exporters! [{:name :test/collect :fn (fn [s] (array/push seen s))}])

(def out
  (trace/with-span "outer" {:parent nil :sampled true}
    (assert (trace/current) "the span is bound for the extent of the body")
    (def ctx (log/context))
    (assert (ctx :trace-id) "and its ids are in the log context — every record inside a request carries them")
    (assert (= (ctx :span-id) ((trace/current) :span-id)))
    (trace/attr! :db.system "postgres")
    (trace/with-span "inner" {}
      (assert (= ((trace/current) :parent-id) (ctx :span-id))
              "a nested span parents itself on the fiber's current one, with no argument threaded through"))
    :value))

(assert (= :value out) "the body's value is the form's value")
(assert (nil? (trace/current)) "and the binding is gone afterwards")
(assert (= 2 (length seen)) "both spans reached the exporter")
(assert (= "inner" ((first seen) :name)) "the inner one first — it finished first")
(assert (= "postgres" (get-in (last seen) [:attrs :db.system])))
(assert (number? ((last seen) :duration)))

# -- errors --------------------------------------------------------------

(array/clear seen)
(def [ok err]
  (protect (trace/with-span "boom" {:parent nil :sampled true}
             (error "kaboom"))))
(assert (not ok) "an error inside a span still reaches the caller")
(assert (string/find "kaboom" (string err)) "unchanged")
(assert (= :error ((first seen) :status)) "and the span is marked failed")
(assert (string/find "kaboom" (string (get-in (first seen) [:attrs :error]))))

# -- an unsampled span is created, counted, and not exported ------------

(array/clear seen)
(trace/with-span "quiet" {:parent nil :sampled false} nil)
(assert (empty? seen) "an unsampled span never reaches an exporter")
(assert (metrics/value trace/spans-total ["quiet" :ok])
        "but it is counted — 'is this path being taken at all' is answered whether or not anything exports spans")

# -- a broken exporter may not fail the request -------------------------

(trace/set-exporters! [{:name :test/broken :fn (fn [_] (error "exporter down"))}
                       {:name :test/collect :fn (fn [s] (array/push seen s))}])
(array/clear seen)
(assert (first (protect (trace/with-span "guarded" {:parent nil :sampled true} 1)))
        "an exporter that throws does not fail the span it was watching")
(assert (= 1 (length seen)) "and the exporters after it still run")

# -- outbound propagation ------------------------------------------------

(trace/set-exporters! [])
(def headers
  (trace/with-span "client" {:parent nil :sampled true}
    (trace/inject! @{"content-type" "application/json"})))
(assert (headers "traceparent") "inject! writes the context into an outgoing request's headers")
(assert (= "application/json" (headers "content-type")) "and leaves the rest alone")
(assert (empty? (trace/headers)) "outside a span there is nothing to inject")

(print "trace-test ok")
