### The `void` bundle.
###
### jpm resolves a dependency to a *git repository with a project.janet
### in its root* — there is no notion of a subdirectory. So the monorepo
### installs as one bundle: every package's `void/` tree merges into a
### single <modpath>/void/, the one native module is built, and the CLI
### lands on PATH. void releases one version per wave, so per-package
### pinning would have been a fiction anyway (see the ADR's trade-offs).
###
### The lists below are not written here — they are projections of the
### package graph, so a package added to scripts/packages.janet is
### installed, tested and documented without a second edit.

(import ./scripts/packages :as packages)
# the version lives in one place — void/core — and this is a reading of it
(import ./core/void/core/init :as core)

(declare-project
  :name "void"
  :description ``void — a batteries-included web framework for Janet: HTTP kernel, SSR + htmx, REST + OpenAPI, database, cache, jobs, load shedding, and the `void` CLI.``
  :version core/version
  :url "https://github.com/bondiano/void"
  :repo "git+https://github.com/bondiano/void.git"
  # janet-lang/sqlite3 is deliberately absent: void/db-sqlite is a plugin
  # an application opts into, and a missing library is an error at :start
  # with a readable text, the way libpq is.
  :dependencies (tuple ;(packages/jpm-dependencies)))

# Every package's `void/` tree, in topological order. `cp -rf` merges
# them, and no two packages own the same name under void/.
(declare-source
  :source (packages/source-trees))

# void/fdwait — ~60 lines of C. An HTMX application pays no extra price
# for it: void/core depends on spork, and spork builds nine native modules
# of its own, so a C compiler is already in the baseline.
(declare-native
  :name "void/fdwait/native"
  :source ["fdwait/src/fdwait.c"])

# jpm writes the shebang itself (:is-janet true) — cli/bin/void carries
# none, or the installed binary gets two.
(declare-binscript
  :main "cli/bin/void"
  :is-janet true)
