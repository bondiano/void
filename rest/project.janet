(declare-project
  :name "void-rest"
  :description "void/rest — REST/JSON sugar over void/http: schema-driven validation and coercion, RFC 7807 problem+json, pagination/sorting/filtering conventions, defresource (SPEC §5.2)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# void-core (../core) and void-http (../http) must be on the module
# path as well; the test suite wires them up itself via
# test-support/paths.janet.

(declare-source
  :source ["void"])
