(declare-project
  :name "void-kafka"
  :description "void/kafka — Kafka through librdkafka's event API: the library's news arrives on an fd one fiber sleeps on, produce is confirmed by the delivery report, and the bus backend's consumer groups are Kafka's own."
  :version "0.0.1")

# No jpm dependency pulls librdkafka in: it is opened at runtime through
# ffi/ from a configured path ([:kafka :library]), so the plugin installs
# on a machine that has no Kafka client library and says so at :start
# rather than at install time — the same arrangement void/db-postgres has
# with libpq and void/db-mysql with libmysqlclient.
#
# void/fdwait IS an edge and has to be built first (cd fdwait && jpm
# build): the whole integration is a fiber parked on the fd librdkafka
# rings.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet): see test-support/paths.janet.

(declare-source
  :source ["void"])
