(declare-project
  :name "void-db-sqlite"
  :description "void/db-sqlite — the reference :void/db-driver: janet-lang/sqlite3 behind the void/db contract (SPEC §5.10, ROADMAP 2.2)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/sqlite3.git"])

# janet-lang/sqlite3 is declared here — the suite needs the binding —
# but the void bundle deliberately does not depend on it (ADR-0020):
# the driver resolves it on first use, so a machine without sqlite
# installs void and is told at :start, the way libpq's absence is
# (ADR-0011).
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
