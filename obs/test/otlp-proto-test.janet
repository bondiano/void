# The protobuf half of the OTLP seam: the same payloads
# otlp-test.janet checks as JSON, encoded as protobuf and read back
# through void/proto against the vendored OTLP descriptors. Pure — no
# socket, no boot, no collector.

(import ../test-support/paths)
(import void/obs/metrics :as metrics)
(import void/obs/otlp :as otlp)
(import void/obs/otlp-proto :as otlp-proto)
(import void/proto :as proto)

(metrics/clear-registry!)

# -- hex ids --------------------------------------------------------------

(assert (= "U86SnQ4ORzY=" (otlp-proto/hex->base64 "53ce929d0e0e4736"))
        "OTLP/JSON spells ids in hex; the proto3 JSON mapping reads bytes as base64")
(assert (not (first (protect (otlp-proto/hex->base64 "53ce929d0e0e473"))))
        "an odd-length id is an error, not a truncation")
(assert (not (first (protect (otlp-proto/hex->base64 "zzce929d0e0e4736"))))
        "and so is one that is not hex")

# -- traces: one payload, two encodings -----------------------------------

(def span
  @{:name "orders.show"
    :trace-id "4bf92f3577b34da6a3ce929d0e0e4736"
    :span-id "00f067aa0ba902b7"
    :parent-id "00f067aa0ba902b6"
    :kind :server
    :status :error
    :started-at 1756400000
    :duration 0.0125
    :attrs @{:http.route "orders.show" :http.status-code 500 :error "boom"}})

(def resource (otlp/attributes {:service.name "shop" :process.pid 42}))
(def payload (otlp/traces-request [span] resource))

(def bytes (otlp/encode payload :protobuf))
(assert (bytes? bytes))
(assert (pos? (length bytes)))

(def back (proto/decode otlp-proto/traces-message bytes))
(def rs (get-in back [:resource_spans 0]))
(assert (= "shop" (get-in (find |(= "service.name" ($ :key))
                                (get-in rs [:resource :attributes]))
                          [:value :string_value]))
        "the resource rides along")

(def s (get-in rs [:scope_spans 0 :spans 0]))
(assert (= "\x4b\xf9\x2f\x35\x77\xb3\x4d\xa6\xa3\xce\x92\x9d\x0e\x0e\x47\x36"
           (s :trace_id))
        "the trace id is its 16 raw bytes on the wire, not 32 hex characters")
(assert (= 8 (length (s :span_id))))
(assert (= "\x00\xf0\x67\xaa\x0b\xa9\x02\xb6" (s :parent_span_id)))
(assert (= "orders.show" (s :name)))
(assert (= :SPAN_KIND_SERVER (s :kind)))
(assert (= :STATUS_CODE_ERROR (get-in s [:status :code])))
(assert (= "boom" (get-in s [:status :message])))
(assert (= (int/u64 "1756400000000000000") (s :start_time_unix_nano))
        "a nanosecond timestamp survives as a real uint64, not a rounded double")
# the duration is exact to what the wall clock's double gives at epoch
# scale — the same window otlp-test.janet allows the JSON spelling
(def dur-ns (int/to-number (- (s :end_time_unix_nano) (s :start_time_unix_nano))))
(assert (< 12000000 dur-ns 13000000))
(defn- attr [as key]
  (get (find |(= key ($ :key)) as) :value))
(assert (= "orders.show" (get (attr (s :attributes) "http.route") :string_value)))
(assert (= (int/s64 500) (int/s64 (get (attr (s :attributes) "http.status-code") :int_value)))
        "an integer attribute is an int64 on the wire")

# -- metrics: the same snapshot, projected the third way ------------------

(def hits (metrics/counter :void.test/otlp-proto-hits {:doc "hits" :labels [:route]}))
(metrics/inc! hits [:home] 3)
(def lat (metrics/histogram :void.test/otlp-proto-lat {:doc "lat" :buckets [0.1 1]}))
(metrics/observe! lat [] 0.5)
(metrics/observe! lat [] 5)

(def mpayload (otlp/metrics-request (metrics/snapshot) resource 1756400000 1756400060))
(def mback (proto/decode otlp-proto/metrics-message (otlp/encode mpayload :protobuf)))
(def ms (get-in mback [:resource_metrics 0 :scope_metrics 0 :metrics]))
(defn- metric [name] (find |(= name ($ :name)) ms))

(def counter (metric "void_test_otlp_proto_hits"))
(assert counter "the metric keeps its Prometheus name — one series to everybody downstream")
(assert (get-in counter [:sum :is_monotonic]))
(assert (= :AGGREGATION_TEMPORALITY_CUMULATIVE (get-in counter [:sum :aggregation_temporality])))
(def cpoint (get-in counter [:sum :data_points 0]))
(assert (= 3 (cpoint :as_double)))
(assert (= "home" (get (attr (cpoint :attributes) "route") :string_value)))
(assert (= (int/u64 "1756400000000000000") (cpoint :start_time_unix_nano))
        "cumulative points carry the process start")

(def hist (metric "void_test_otlp_proto_lat"))
(def hpoint (get-in hist [:histogram :data_points 0]))
(assert (= 2 (hpoint :count)))
(assert (= 5.5 (hpoint :sum)))
(assert (deep= @[0.1 1] (hpoint :explicit_bounds)))
(assert (deep= @[0 1 1] (hpoint :bucket_counts))
        "one more count than there are bounds: the last holds the overflow")

# -- the seam itself ------------------------------------------------------

(assert (= "application/x-protobuf" (otlp/content-types :protobuf)))
(assert (= "application/json" (otlp/content-types :json)))
(assert (deep= (otlp/encode payload) (otlp/encode payload :json))
        "the default is still JSON")
(assert (not (first (protect (otlp/encode payload :msgpack))))
        "a third encoding is still an error naming the two")
(assert (not (first (protect (otlp-proto/encode-payload {"spans" []}))))
        "a payload that is neither signal is refused, not guessed")

(print "otlp-proto ok")
