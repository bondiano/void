(declare-project
  :name "void-htmx"
  :description "void/htmx — htmx 4 integration: hx-helpers, HX-Request-Type fragment answers, OOB and <hx-partial> swaps, HX-Trigger response headers."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
