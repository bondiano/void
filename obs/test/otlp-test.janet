# The OTLP projection: what a span and a metric snapshot look like on
# the wire. Pure — no socket, no boot, no collector. The transport is
# otlp-export-test.janet.

(import ../test-support/paths)
(import spork/json)
(import void/obs/metrics :as metrics)
(import void/obs/trace :as trace)
(import void/obs/otlp :as otlp)

(metrics/clear-registry!)

# -- timestamps ----------------------------------------------------------

(assert (= "1756400000250000000" (otlp/nano-str 1756400000.25))
        "seconds and the fraction are formatted apart — a nanosecond epoch is past what a double can carry")
(assert (= 19 (length (otlp/nano-str 1756400000.25))))
(assert (= "0000000000" (string/slice (otlp/nano-str 1756400000) 9))
        "a whole second still gets its nine digits")
(assert (= "1999999999" (otlp/nano-str 1.9999999999))
        "and a fraction that rounds up to a whole second is clamped rather than carried into the seconds")

# -- attributes ----------------------------------------------------------

(def attrs (otlp/attributes {:service.name "shop" :port 8080 :ratio 0.25
                             :debug false :level :warn}))
(defn- attr [as key]
  (get (find |(= key ($ "key")) as) "value"))

(assert (= {"stringValue" "shop"} (attr attrs "service.name")))
(assert (= {"intValue" "8080"} (attr attrs "port"))
        "an integer goes out as a string — the field is an int64 and JSON has no such number")
(assert (= {"doubleValue" 0.25} (attr attrs "ratio")))
(assert (= {"boolValue" false} (attr attrs "debug"))
        "false is a value, not a missing attribute")
(assert (= {"stringValue" "warn"} (attr attrs "level"))
        "a keyword is its name")

# -- one span ------------------------------------------------------------

(def span
  @{:name "orders.show"
    :trace-id "4bf92f3577b34da6a3ce929d0e0e4736"
    :span-id "00f067aa0ba902b7"
    :parent-id "00f067aa0ba902b6"
    :kind :server
    :status :ok
    :sampled true
    :started-at 1756400000
    :duration 0.0125
    :attrs @{:http.route "orders.show" :http.status-code 200}})

(def s (otlp/span->otlp span))
(assert (= "4bf92f3577b34da6a3ce929d0e0e4736" (s "traceId")))
(assert (= "00f067aa0ba902b6" (s "parentSpanId")))
(assert (= 2 (s "kind")) "a :server span is SPAN_KIND_SERVER")
(assert (= "1756400000000000000" (s "startTimeUnixNano")))
(def end-ns (s "endTimeUnixNano"))
(assert (= "1756400000" (string/slice end-ns 0 10)) "the end is in the same second")
(assert (< 12000000 (scan-number (string/slice end-ns 10)) 13000000)
        "and the start plus 12.5 ms — to the resolution a double has left at epoch scale, which is where the last digits of a nanosecond timestamp go")
(assert (= 0 (get-in s ["status" "code"]))
        "an ok span is UNSET: OTLP's OK means an application said so, and void's :ok only means nothing went wrong")

(def failed (otlp/span->otlp (merge (table/clone span)
                                    @{:status :error
                                      :attrs @{:error "connection refused"}})))
(assert (= 2 (get-in failed ["status" "code"])))
(assert (= "connection refused" (get-in failed ["status" "message"]))
        "and the message is the error the span was marked with")

(def root (table/clone span))
(put root :parent-id nil)
(assert (nil? ((otlp/span->otlp root) "parentSpanId"))
        "a root span has no parent field at all, rather than an empty one")

# -- a batch -------------------------------------------------------------

(def resource (otlp/attributes {:service.name "shop"}))
(def batch (otlp/traces-request [span span] resource))
(def scope-spans (get-in batch ["resourceSpans" 0 "scopeSpans" 0]))
(assert (= 2 (length (scope-spans "spans"))))
(assert (= "void/obs" (get-in scope-spans ["scope" "name"]))
        "one scope, because one library produced all of it")

(def decoded (json/decode (otlp/encode batch)))
(assert (= "4bf92f3577b34da6a3ce929d0e0e4736"
           (get-in decoded ["resourceSpans" 0 "scopeSpans" 0 "spans" 0 "traceId"]))
        "and the whole thing survives the encoder a collector will read it with")

# -- metrics -------------------------------------------------------------

(def requests (metrics/counter :void.http/requests-total
                {:doc "HTTP requests" :labels [:route :method :status]}))
(metrics/inc! requests ["orders.show" "get" "200"] 42)

(def in-flight (metrics/gauge :void.http/requests-in-flight {:doc "In flight"}))
(metrics/set! in-flight nil 3)

(def duration (metrics/histogram :void.http/request-duration-seconds
                {:doc "Duration" :labels [:route] :buckets [0.01 0.1 1]}))
(each v [0.005 0.05 0.5 5] (metrics/observe! duration ["orders.show"] v))

(def never (metrics/counter :void.test/never-fired {:doc "nothing happened"}))

(def payload (otlp/metrics-request (metrics/snapshot) resource 1756400000 1756400060))
(def exported (get-in payload ["resourceMetrics" 0 "scopeMetrics" 0 "metrics"]))
(defn- by-name [name] (find |(= name ($ "name")) exported))

(def counter (by-name "void_http_requests_total"))
(assert counter "the exported name is the Prometheus one — a series must not be called two things")
(assert (get-in counter ["sum" "isMonotonic"]) "a counter is a monotonic sum")
(assert (= 2 (get-in counter ["sum" "aggregationTemporality"]))
        "cumulative, because that is what the registry holds")
(def point (get-in counter ["sum" "dataPoints" 0]))
(assert (= 42 (point "asDouble")))
(assert (= "1756400000000000000" (point "startTimeUnixNano"))
        "and every cumulative point carries the moment the process started counting")
(assert (= "1756400060000000000" (point "timeUnixNano")))
(assert (= ["route" "method" "status"] (tuple ;(map |($ "key") (point "attributes"))))
        "labels become attributes in declared order")
(assert (= ["orders.show" "get" "200"]
           (tuple ;(map |(get-in $ ["value" "stringValue"]) (point "attributes"))))
        "carrying the values the series was written with")

(assert (get-in (by-name "void_http_requests_in_flight") ["gauge" "dataPoints"])
        "a gauge is a gauge")

(def hist (get-in (by-name "void_http_request_duration_seconds") ["histogram" "dataPoints" 0]))
(assert (= "4" (hist "count")) "count and bucket counts are strings — uint64 again")
(assert (= [0.01 0.1 1] (tuple ;(hist "explicitBounds"))))
(assert (= ["1" "1" "1" "1"] (tuple ;(hist "bucketCounts")))
        "one more bucket than there are bounds: the last holds the 5 s observation, which no bound caught")
(assert (= 5.555 (hist "sum")))
(assert (= "s" (get (by-name "void_http_request_duration_seconds") "unit"))
        "the unit is read off the name, because void measures in Prometheus base units everywhere")

(assert (nil? (by-name "void_test_never_fired"))
        "a metric that never fired is announced to a scraper but pushed to nobody — an empty data point list is a walk for nothing")

(assert (= 3 (otlp/data-points payload))
        "and what the exporter reports as exported is points, not metric names")

# -- the encoding seam ---------------------------------------------------

(assert (pos? (length (otlp/encode payload :protobuf)))
        "protobuf is a second projection of this same payload — the seam the exporter left now has its second value (otlp-proto-test.janet reads the bytes back)")
(assert (not (first (protect (otlp/encode payload :msgpack))))
        "and a third encoding is still refused by name")

# -- a span the tracer really produced -----------------------------------

(metrics/clear-registry!)
(trace/set-exporters! [])
(def real (trace/start "job.run" {:kind :consumer :attrs {:queue "mail"}}))
(trace/end! real)
(def encoded (json/decode (otlp/encode (otlp/traces-request [real] resource))))
(def rs (get-in encoded ["resourceSpans" 0 "scopeSpans" 0 "spans" 0]))
(assert (= "job.run" (rs "name")))
(assert (= 5 (rs "kind")))
(assert (= 32 (length (rs "traceId"))) "32 hex characters, as W3C requires")
(assert (= 16 (length (rs "spanId"))))
(assert (< 0 (scan-number (string/slice (rs "startTimeUnixNano") 0 10)))
        "and the timestamps are real seconds since the epoch, not monotonic ones")
