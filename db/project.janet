(declare-project
  :name "void-db"
  :description "void/db — database kernel: driver contract, fiber-aware pool, SQL-as-data query builder, dyn-scoped transactions, migrations, Data Mapper entity layer with thin AR sugar.")

# void-http is here for the optional void/db-http plugin only — same
# package, separate plugin, so an application without HTTP pays
# nothing for it.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
