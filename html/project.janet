(declare-project
  :name "void-html"
  :description "void/html — SSR view layer: hiccup pipeline (components, layouts, partials), form helpers from schemas, fingerprinted asset manifest, temple engine."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
