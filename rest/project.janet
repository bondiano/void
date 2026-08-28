(declare-project
  :name "void-rest"
  :description "void/rest — REST/JSON sugar over void/http: schema-driven validation and coercion, RFC 7807 problem+json, pagination/sorting/filtering conventions, defresource (SPEC §5.2)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
