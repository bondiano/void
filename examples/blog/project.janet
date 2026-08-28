(declare-project
  :name "blog"
  :description "A void CRUD application — db, jobs and cache."
  :dependencies ["https://github.com/janet-lang/spork.git"
                 "https://github.com/janet-lang/sqlite3.git"])

# In the repository this example runs off the checkout: its module path
# is a projection of the package graph (scripts/packages.janet,
# ADR-0020) — see test-support/paths.janet, and `scripts/void routes`
# from this directory. Outside it, the whole framework is one
# dependency: :dependencies ["https://github.com/bondiano/void.git"],
# plus the driver's own client library — janet-lang/sqlite3 above, or
# nothing at all for Postgres, whose libpq is opened through ffi/.
