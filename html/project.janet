(declare-project
  :name "void-html"
  :description "void/html — SSR view layer: hiccup pipeline (components, layouts, partials), form helpers from schemas, fingerprinted asset manifest, temple engine (SPEC §5.4)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# void-core (../core) and void-http (../http) must be on the module
# path as well; the test suite wires them up itself via
# test-support/paths.janet.

(declare-source
  :source ["void"])
