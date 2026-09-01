(declare-project
  :name "void-obs"
  :description "void/obs — observability: a metric registry with a cardinality cap, spans in a dyn with W3C trace context, an event-loop lag histogram, log sampling and file sinks, auto-instrumentation of the data plugins, /metrics /health /ready for void/http, and OTLP export of spans and metrics to a collector — JSON by default, protobuf via [:obs-otlp :encoding] (SPEC §5.13 and §8.4)."
  :version "0.0.1")

# void/obs itself is core-only plus one import: void/pressure's loop-lag
# meter (`void/pressure/sample`), the way void/bench/probe takes it —
# the module, never the plugin, so an application that observes does not
# thereby start shedding. void/obs-http is the half that needs the HTTP
# kernel and is a separate plugin in this package, the split void/cache
# and void/pressure already make; void/obs-otlp is the third, and it
# needs void/http for the other direction — the client (ADR-0027).
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
