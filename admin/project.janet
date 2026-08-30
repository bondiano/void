(declare-project
  :name "void-admin"
  :description "void/admin — the back office as a projection of the entity and schema layers: one declaration becomes CRUD routes, forms, filters and bulk actions for a human, and the same declaration becomes MCP tools and resources for an agent (SPEC §5.21, ADR-0029)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# Three plugins in one package (ADR-0020, the void/cache — void/cache-http
# split): `void/admin` needs the kernel, the view layer and authorization;
# `void/admin-jobs` adds the queue, so an admin with no heavy action
# composes none; `void/admin-mcp` adds the agent-facing projection, and
# contributes to the seam void/mcp declared in 4.3 without void/admin
# carrying a line about MCP (ADR-0031, ADR-0029).
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
