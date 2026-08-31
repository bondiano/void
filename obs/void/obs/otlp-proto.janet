### void/obs/otlp-proto — the protobuf half of the OTLP seam
### (ADR-0027, ROADMAP 4.1).
###
### ADR-0027 shipped the exporter on OTLP/JSON and left
### `[:obs-otlp :encoding]` as a seam with one legal value, promising
### that the binary encoding would land as a second projection of the
### same payload data and that `encode` would be the only function to
### learn about it. This module is that projection: the OTLP `.proto`
### files from the opentelemetry-proto repository (vendored under
### ./otlp-protos, pinned to v1.5.0), baked into descriptors by
### `defproto`, and one function that turns the payload ./otlp already
### builds into the bytes a collector reads as
### `application/x-protobuf`.
###
### **The payload stays JSON-shaped, and that is the point.** ./otlp
### builds one payload — string keys, lowerCamelCase, 64-bit integers
### as strings — and this module reads it through void/proto's proto3
### JSON mapping (`from-json`) before encoding, so there is no second
### span->otlp and no second metric->otlp to drift from the first.
### The one place OTLP/JSON deviates from the proto3 JSON mapping is
### handled here by name: span and trace ids travel as **hex** in
### OTLP/JSON (the OTLP spec says so) but are `bytes` fields on the
### wire, and the mapping would read them as base64 — so the three id
### fields are re-spelled before the mapping sees them.
###
### **A module, not a plugin, and loaded only when asked.** ./otlp
### requires this file the first time `:protobuf` is configured, so an
### application on the JSON default never parses a line of these
### `.proto` files — and a single binary, which has no module tree to
### require from, hands the module over with `otlp/use-module!` the
### way db-sqlite's `use-module!` works (docs/DEPLOY.md).

(import spork/base64)
(import void/proto :as proto)

(proto/defproto "otlp-protos/opentelemetry/proto/collector/trace/v1/trace_service.proto"
  {:paths ["otlp-protos"]})
(proto/defproto "otlp-protos/opentelemetry/proto/collector/metrics/v1/metrics_service.proto"
  {:paths ["otlp-protos"]})

(def traces-message
  "The message an OTLP/HTTP POST to /v1/traces carries."
  :opentelemetry.proto.collector.trace.v1/ExportTraceServiceRequest)

(def metrics-message
  "The message an OTLP/HTTP POST to /v1/metrics carries."
  :opentelemetry.proto.collector.metrics.v1/ExportMetricsServiceRequest)

# -- hex ids -------------------------------------------------------------

(defn hex->base64
  ``A hex string as the base64 the proto3 JSON mapping reads for a
  `bytes` field. OTLP/JSON spells trace and span ids in hex — its one
  named deviation from the mapping — and void's tracer holds them that
  way, so the ids are re-spelled here and nowhere else.``
  [s]
  (def n (length s))
  (when (odd? n)
    (errorf "obs otlp: %q is not a hex id (odd length)" s))
  (def raw (buffer/new (div n 2)))
  (loop [i :range [0 n 2]]
    (def b (scan-number (string "0x" (string/slice s i (+ i 2)))))
    (unless b (errorf "obs otlp: %q is not a hex id" s))
    (buffer/push-byte raw b))
  (base64/encode (string raw)))

(defn- rekey-span [span]
  (def out (merge span))
  (each k ["traceId" "spanId" "parentSpanId"]
    (when-let [v (get span k)]
      (put out k (hex->base64 v))))
  out)

(defn- rekey-ids [payload]
  {"resourceSpans"
   (seq [rs :in (get payload "resourceSpans" [])]
     (merge rs
            {"scopeSpans"
             (seq [ss :in (get rs "scopeSpans" [])]
               (merge ss {"spans" (map rekey-span (get ss "spans" []))}))}))})

# -- the projection ------------------------------------------------------

(defn encode-payload
  ``An export payload — the same data `json/encode` would send — as
  protobuf bytes. Which service request it is is read off the payload
  itself: `traces-request` and `metrics-request` each have exactly one
  top-level key, and it names the message.``
  [payload]
  (cond
    (get payload "resourceSpans")
    (proto/encode traces-message (proto/from-json traces-message (rekey-ids payload)))

    (get payload "resourceMetrics")
    (proto/encode metrics-message (proto/from-json metrics-message payload))

    (errorf "obs otlp: %q is neither a traces nor a metrics payload"
            (tuple ;(keys payload)))))
