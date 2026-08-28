(declare-project
  :name "void-dev"
  :description "void/dev — canonical dev-mode plugin: in-process netrepl, file watcher with component auto-restart, void/test fixtures and schema factories."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
