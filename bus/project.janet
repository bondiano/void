(declare-project
  :name "void-bus"
  :description "void/bus — messaging: a message is a plain table, a topic is a keyword, delivery guarantees are declared by the backend, and the transactional outbox is the one sanctioned way to publish what a transaction wrote (SPEC §5.22, ADR-0012)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# spork, for its JSON codec — the interchange half of :void.bus/codec —
# and for nothing else. The router, the in-process backend and the
# outbox are plain Janet; void/bus-db imports void/db and void/bus-jobs
# imports void/jobs, and both are separate plugins in this package, so
# an application whose messages never leave the process pays for
# neither.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
