# Contributing to void

Every package tests with `jpm test` from its own directory; CI
additionally dry-runs the full composition (`janet
scripts/dry-run.janet`) and checks that
[docs/CONTRACTS.md](docs/CONTRACTS.md) matches the declarations (`janet
scripts/gen-contracts.janet && git diff --exit-code docs/CONTRACTS.md`).

Bootstrap a checkout once — it installs the external dependencies every
package declares and builds `void/fdwait`, the repository's one native
module, which both gates need because they load `void/db-postgres`:

```sh
janet scripts/bootstrap.janet          # add --local to keep it out of
                                       # the system tree
```

Nothing else is installed: a package's test suite reaches the others
through `test-support/paths.janet`, two lines that project the package
graph in [`scripts/packages.janet`](scripts/packages.janet). **That
graph is the only place an edge between packages is written** — the
bundle's source list, every suite's module path, the CI test steps and
the dry-run gate all read it, and `janet scripts/packages.janet check`
refuses a graph that disagrees with the tree on disk. A new package, or
a new dependency between two, is one edit there.

The CLI runs off the checkout too, so there is no install/edit loop:

```sh
scripts/void new myapp
cd myapp && ../scripts/void routes
```

One example does not work that way, on purpose. `examples/hub` (the
wave-6 application) has no `test-support/paths.janet`: it imports
`void/...` from an **installed** tree, the way somebody who never cloned
this repository does. A `jpm test` of the checkout therefore proves
nothing about the install, and that is the gap it exists to close:

```sh
janet scripts/install-tree.janet              # bundle -> ./.void-tree
eval "$(janet scripts/install-tree.janet --export)"
cd examples/hub && jpm test
```

The cost is the point: a change to the framework reaches the hub only
after `install-tree` runs again. In CI the same two lines are the
"clean machine" job, which is where `janet scripts/packages.janet
ci-installed` is run — and the reason an installed example is marked
`:installed` in the graph rather than merely lacking a paths file.

`void/db-postgres`'s integration tests need a server, named by
`VOID_TEST_PG` — a conninfo or a `postgres://` URL. Without one they
announce themselves as skipped instead of failing; CI sets it against a
service container, which is where they are a real gate. What can be
tested without a server (the connection string, the type codecs, the
plugin's declarations) always runs.

## Frozen contracts and deprecation {#deprecation}

Since v0.1 the Plugin API and Route Metadata contracts are **frozen** .
The normative registry is [docs/CONTRACTS.md](docs/CONTRACTS.md),
generated from the declarations. What freezing means in practice:

**Allowed without ceremony (additive):**

- adding a **new** extension point or a **new** metadata key (namespaced,
  declared through `:void.http/route-meta-key`);
- adding `:optional` fields to an existing point's contribution schema;
- widening a schema so every previously valid contribution stays valid
  (e.g. `:keyword` → `[:or :keyword [:vector :keyword]]`).

**Never allowed:** renaming a point/key in place, removing or
un-optionalizing a schema field, tightening validation, or changing a
key's `:merge` strategy. Any of those is a **new contract name** plus a
deprecation period for the old one:

1. Declare the replacement under a new name
   (`:void.http/middleware2`, `:void.rest/problems2`, ...).
2. Keep the old name working as an alias for at least one minor
   release: extension points list it in `:aliases` —
   `(defextension-point :void.http/middleware2 ... :aliases [:void.http/middleware])`
   — and the host folds contributions to the old name into the new
   point with a boot warning naming the contributing plugin.
3. Document the migration in docs/CONTRACTS.md (the generator renders
   `:aliases` automatically) and in the release notes.
4. Remove the alias no earlier than the next minor release; removal is
   a breaking change and bumps `:void-api` if the mechanics change.

Reserved names (the "waves 2+" tables in CONTRACTS.md) are part of the
freeze: don't repurpose them.

## Performance rules

Every plugin, before merge:

1. **No blocking syscalls or FFI on the ev loop.** Anything that can
   block goes through readiness-waits (`void/fdwait` pattern) or
   `ev/thread`.
2. **Hot-path allocations are budgeted.** Reuse buffers; don't build
   intermediate strings per request when a buffer push does.
3. **Everything computable at build time happens at build time** —
   route tables, middleware chains, merged metadata are precompiled;
   nothing merges on the hot path.
4. **A plugin that ships middleware ships a bench line**: run
`void bench b1` with and without the middleware and record "B1 with my
middleware = −X%" in the PR (see [bench/README.md](bench/README.md);
budgets and thresholds are in [docs/BENCH-v0.1.md](docs/BENCH-v0.1.md)).

CI runs B0/B1 with a 5% relative regression gate (merge-base vs head on
the same runner); absolute budgets are verified on the recorded
reference environment (`bench/results/baseline.jdn`).

## Commit style

`feat:` / `fix:` / `refactor:` / `test:` / `chore:` / `docs:` / `style:`
/ `perf:` / `revert:` — one logical change per commit.

## Language

Code, docstrings, comments and everything under `docs/` are English.
A commit subject is English or Russian — one of the two, not a mix;
`scripts/gen-changelog.janet` carries the English of the Russian ones,
keyed by hash, so the changelog reads in one language. The design
record (the specification, the wave plan, the decision records) is
kept outside the repository and is not something a contribution has
to read or cite: what a decision settled is written into the code's
docstrings and the documents here, which is where the reasons are
expected to live.

## Definition of Done (any plugin)

1. Manifest passes `plugin/dry-run`; removing the plugin from
   `:plugins` leaves no trace.
2. Config schema + tests for invalid configs; secrets never print.
3. `plugin/inspect` shows every contribution.
4. Tests: unit + integration through `void/test` fixtures; middleware
   ships its bench line.
5. Docs: the plugin's declarations carry `:doc` strings — CONTRACTS.md
   regenerates from them.
6. Nothing blocking on the ev loop.
