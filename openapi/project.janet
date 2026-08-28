(declare-project
  :name "void-openapi"
  :description "void/openapi — OpenAPI 3.1 as a pure projection of the route table + schema registry; Swagger UI in dev; export to file (SPEC §5.3)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
