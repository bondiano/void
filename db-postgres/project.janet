(declare-project
  :name "void-db-postgres"
  :description "void/db-postgres — Postgres as the :void/db-driver: async libpq on the ev loop through void/fdwait, no thread pool (SPEC §5.10, ADR-0011, ROADMAP 2.2)."
  :version "0.0.1")

# No jpm dependency pulls libpq in: it is opened at runtime through
# ffi/ from a configured path ([:db-postgres :libpq]), so the plugin
# installs on a machine that has no Postgres client library and says
# so at :start rather than at install time.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet. void/fdwait is the one hard
# prerequisite, and it is C: build it first (janet
# scripts/bootstrap.janet, or cd ../fdwait && jpm build).

(declare-source
  :source ["void"])
