(declare-project
  :name "guestbook"
  :description "A void application."
  :dependencies ["https://github.com/janet-lang/spork.git"])

# In the repository this example runs off the checkout: its module path is
# a projection of the package graph (scripts/packages.janet) — see
# test-support/paths.janet, and `scripts/void routes` from this directory.
# Outside it, the whole framework is one dependency: :dependencies
# ["https://github.com/bondiano/void.git"], which is what `void new`
# writes.