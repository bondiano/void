(declare-project
  :name "shop"
  :description "A void e-commerce application — catalog, cart, checkout, payments, admin, JSON API, and the wave-3 enterprise layer."
  :dependencies ["https://github.com/janet-lang/spork.git"
                 "https://github.com/janet-lang/sqlite3.git"])

# In the repository this example runs off the checkout: its module path is
# a projection of the package graph (scripts/packages.janet) — see
# test-support/paths.janet, and `scripts/void routes` from this directory.
# Outside it, the whole framework is one dependency: :dependencies
# ["https://github.com/bondiano/void.git"], plus the driver's own client
# library — janet-lang/sqlite3 above, or nothing at all for Postgres,
# whose libpq is opened through ffi/.
