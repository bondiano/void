(declare-project
  :name "void-pressure"
  :description "void/pressure — load shedding: an event-loop lag / RSS sampler, thresholds with recovery hysteresis, and a 503 + Retry-After for void/http while the process is over them (SPEC §5.23, ADR-0019, ROADMAP 2.6)."
  :version "0.0.1")

# No dependencies. The sampler and the state machine are plain Janet;
# void/pressure-http imports void/http and is a separate plugin in
# this package, so a worker or a CLI that wants the sampler (and the
# jobs it runs shedding under pressure) never drags the HTTP kernel in
# — what void/cache-http is to void/cache.
#
# void-core (../core) must be on the module path, plus ../http for
# that second plugin; the test suite wires them up itself via
# test-support/paths.janet.

(declare-source
  :source ["void"])
