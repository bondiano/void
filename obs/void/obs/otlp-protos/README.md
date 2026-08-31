# Vendored OTLP `.proto` files

From [open-telemetry/opentelemetry-proto](https://github.com/open-telemetry/opentelemetry-proto),
pinned to **v1.5.0**, unmodified (Apache-2.0 — each file carries its
header):

- `opentelemetry/proto/common/v1/common.proto`
- `opentelemetry/proto/resource/v1/resource.proto`
- `opentelemetry/proto/trace/v1/trace.proto`
- `opentelemetry/proto/metrics/v1/metrics.proto`
- `opentelemetry/proto/collector/trace/v1/trace_service.proto`
- `opentelemetry/proto/collector/metrics/v1/metrics_service.proto`

They live inside the module tree (not next to it) because
`../otlp-proto.janet` bakes them into descriptors with `proto/defproto`
at module compile, and a module compiles wherever the package is
installed — the files travel with it. Only a composition that
configures `[:obs-otlp :encoding] :protobuf` ever loads that module
(ADR-0027).

To bump the pin: replace the files from the new tag, update the version
above and in `../otlp-proto.janet`'s docstring, and run
`obs/test/otlp-proto-test.janet` — field numbers are the compatibility
contract, so a bump that round-trips is a bump that works.
