(declare-project
  :name "void-datastar"
  :description "void/datastar — the Datastar experiment: SSE patch events, data-* attribute builders, and the Biff idiom — the handler keeps returning the full page, the plugin morphs the live DOM with it (SPEC §5.5, ADR-0037)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# What has to be on the module path is a projection of the package
# graph (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
