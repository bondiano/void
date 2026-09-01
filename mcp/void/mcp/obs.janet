### void/mcp-obs — this process's metrics as an MCP resource (SPEC.md
### §5.18).
###
### The third plugin of the package, and the smallest: one
### contribution to `:void.mcp/resource`. It is separate because the
### edge is — an application that composes MCP without observability
### should not be made to compose observability, and one that has both
### should not have to wire them together.
###
### The exposition is the *same projection of the same snapshot* that
### `GET /metrics` renders (ADR-0021): an agent asking what the
### process is doing and a scraper asking the same question get the
### same numbers, in the same text, with no second rendering to keep
### in step. Which is also why this is a resource and not a tool:
### reading metrics changes nothing, and a resource is what MCP calls
### something you read.

(import void/core/plugin :as plugin)
(import void/obs/metrics :as metrics)
(import void/obs/prometheus :as prometheus)

(plugin/contribute! :void.mcp/resource
  {:name :void.obs/metrics
   :uri "void://metrics"
   :title "metrics"
   :doc "Every metric this process holds, in the Prometheus text exposition — the same bytes GET /metrics serves"
   :mime-type prometheus/content-type
   :read (fn read-metrics [] (prometheus/render (metrics/snapshot)))})

(plugin/defplugin void/mcp-obs
  :doc "This process's Prometheus exposition as an MCP resource: the same projection of the same snapshot GET /metrics renders, published to an agent that asks what the process is doing."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/mcp ">=0.0.1" :void/obs ">=0.0.1"})
