(declare-project
  :name "void-rest"
  :description "void/rest — REST/JSON sugar over void/http: schema-driven validation and coercion, RFC 7807 problem+json, pagination/sorting/filtering conventions, defresource."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
