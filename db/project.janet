(declare-project
  :name "void-db"
  :description "void/db — database kernel: driver contract, fiber-aware pool, SQL-as-data query builder, dyn-scoped transactions, migrations, Data Mapper entity layer with thin AR sugar (SPEC §5.9, ADR-0009).")

# void-core (../core) must be on the module path; void-http (../http)
# only for the optional void/db-http plugin and its tests. The test
# suite wires both up itself via test-support/paths.janet.

(declare-source
  :source ["void"])
