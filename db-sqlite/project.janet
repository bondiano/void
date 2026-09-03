(declare-project
  :name "void-db-sqlite"
  :description "void/db-sqlite — the reference :void/db-driver: janet-lang/sqlite3 behind the void/db contract."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/sqlite3.git"])

# janet-lang/sqlite3 is declared here — the suite needs the binding — but
# the void bundle deliberately does not depend on it: the driver resolves
# it on first use, so a machine without sqlite installs void and is told
# at :start, the way libpq's absence is.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
