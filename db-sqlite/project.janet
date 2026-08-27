(declare-project
  :name "void-db-sqlite"
  :description "void/db-sqlite — the reference :void/db-driver: janet-lang/sqlite3 behind the void/db contract (SPEC §5.10, ROADMAP 2.2)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/sqlite3.git"])

# void-core (../core) and void-db (../db) must be on the module path
# as well; the test suite wires them up itself via
# test-support/paths.janet.

(declare-source
  :source ["void"])
