(declare-project
  :name "void-db-mysql"
  :description "void/db-mysql — MySQL as the :void/db-driver: libmysqlclient on a worker thread per connection, the blocking client API kept off the ev loop (SPEC §5.10, ADR-0033, ROADMAP 5)."
  :version "0.0.1")

# No jpm dependency pulls libmysqlclient in: it is opened at runtime
# through ffi/ from a configured path ([:db-mysql :library]), so the
# plugin installs on a machine that has no MySQL client library and says
# so at :start rather than at install time — the same arrangement
# void/db-postgres has with libpq (ADR-0011).
#
# Unlike void/db-postgres, there is no native module to build first:
# void/fdwait exists to park on a descriptor libpq owns, and this driver
# parks on a channel instead (ADR-0033).
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
