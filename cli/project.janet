(declare-project
  :name "void-cli"
  :description "void/cli — the `void` binary: project scaffolding (void new), the netrepl client (void repl) and the :void.core/cli extension point runner (void routes, void openapi export, ...)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# void-core (../core) must be on the module path as well; the test
# suite wires it up itself via test-support/paths.janet.

(declare-source
  :source ["void"])

(declare-binscript
  :main "bin/void"
  :is-janet true)
