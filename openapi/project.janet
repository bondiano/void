(declare-project
  :name "void-openapi"
  :description "void/openapi — OpenAPI 3.1 as a pure projection of the route table + schema registry; Swagger UI in dev; export to file (SPEC §5.3)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# void-core (../core), void-http (../http) and void-rest (../rest)
# must be on the module path as well; the test suite wires them up
# itself via test-support/paths.janet.

(declare-source
  :source ["void"])
