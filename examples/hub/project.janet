(declare-project
  :name "hub"
  :description "A void application."
  # One dependency: void installs as a single bundle (ADR-0020), and
  # everything it needs — spork, and the framework's own packages —
  # comes with it. "jpm --local deps" pins this version in ./jpm_tree,
  # which the void binary uses in preference to the tree it was
  # installed into.
  :dependencies ["https://github.com/bondiano/void.git"])

# "jpm --local build" writes build/hub — one file, no janet on the
# target and nothing to install (docs/DEPLOY.md). jpm marshals the
# "main" of the entry below into the executable and links the native
# modules it finds statically, which is why main.janet reads the
# profile at run time rather than into a value.
(declare-executable
  :name "hub"
  :entry "main.janet"
  :install false)
