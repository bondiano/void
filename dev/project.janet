(declare-project
  :name "void-dev"
  :description "void/dev — canonical dev-mode plugin: in-process netrepl, file watcher with component auto-restart, void/test fixtures and schema factories."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# void-core (../core) must be on the module path as well; the test
# suite wires it up itself via test-support/paths.janet.

(declare-source
  :source ["void"])
