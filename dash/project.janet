(declare-project
  :name "void-dash"
  :description "void/dash — the dev dashboard as a fourth projection of what the process already tells a REPL: composition, components, config with provenance, routes, deploy shape, health, a log ring with a live tail, fixed-memory history with sparklines, and a tap inspector for values sent from code or the REPL."
  :version "0.0.1")

# One plugin in one package. The dashboard is a *reader*: every page is
# a projection of plugin/inspect, plugin/why, config/explain,
# hooks/handlers, deploy/survey, boot :system, routes-table and
# explain-route — the same values Prometheus, MCP and the CLI already
# read. What it adds of its own is bounded memory: three ring buffers
# (logs, history samples, tapped values) and a sampler fiber.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
