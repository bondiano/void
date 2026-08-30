(declare-project
  :name "void-mcp"
  :description "void/mcp — the application as an MCP server: :void.core/cli commands projected into tools, registered schemas and the health report into resources, JSON-RPC over stdio and over an ordinary HTTP route (SPEC §5.18, ADR-0031)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# spork is here for json, which is the wire format — MCP is JSON-RPC
# and nothing else. void/openapi is imported as a *module*, never as a
# plugin: ./registry converts a registered schema into JSON Schema with
# void/openapi/jsonschema, the way void/obs takes void/pressure's
# loop-lag meter without composing the shedder. void/mcp-http imports
# void/http and void/mcp-obs imports void/obs — two more plugins in
# this package, the void/cache — void/cache-http split, so an agent
# talking to a jobs worker over stdio drags neither in.
#
# What has to be on the module path is a projection of the package
# graph (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
