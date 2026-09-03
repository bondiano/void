(declare-project
  :name "void-cli"
  :description "void/cli — the `void` binary: project scaffolding (void new), the netrepl client (void repl) and the :void.core/cli extension point runner (void routes, void openapi export, ...)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet. The suite reaches
# further than the CLI does: it runs `void new` and then boots the
# generated project, which is the full wave-1 plugin list.

(declare-source
  :source ["void"])

(declare-binscript
  :main "bin/void"
  :is-janet true)
