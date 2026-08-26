(declare-project
  :name "void-htmx"
  :description "void/htmx — htmx integration: hx-helpers, HX-Request fragment answers, OOB swaps, HX-Trigger response headers (SPEC §5.5)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# void-core (../core), void-http (../http) and void-html (../html)
# must be on the module path as well; the test suite wires them up
# itself via test-support/paths.janet.

(declare-source
  :source ["void"])
