(declare-project
  :name "void-db-postgres"
  :description "void/db-postgres — Postgres as the :void/db-driver: async libpq on the ev loop through void/fdwait, no thread pool (SPEC §5.10, ADR-0011, ROADMAP 2.2)."
  :version "0.0.1")

# No jpm dependency pulls libpq in: it is opened at runtime through
# ffi/ from a configured path ([:db-postgres :libpq]), so the plugin
# installs on a machine that has no Postgres client library and says
# so at :start rather than at install time.
#
# void-core (../core), void-db (../db) and void-fdwait (../fdwait —
# sources plus the native module in its build/ tree) must be on the
# module path; the test suite wires them up itself via
# test-support/paths.janet. void/fdwait is the one hard prerequisite:
# build it first (cd ../fdwait && jpm build).

(declare-source
  :source ["void"])
