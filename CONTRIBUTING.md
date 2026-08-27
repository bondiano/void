# Contributing to void

Wave-based development: see [docs/ROADMAP.md](docs/ROADMAP.md) for what
is in flight and [docs/SPEC.md](docs/SPEC.md) for the design. Every
package tests with `jpm test` from its own directory; CI additionally
dry-runs the full composition (`janet scripts/dry-run.janet`) and checks
that [docs/CONTRACTS.md](docs/CONTRACTS.md) matches the declarations
(`janet scripts/gen-contracts.janet && git diff --exit-code docs/CONTRACTS.md`).

## Frozen contracts and deprecation {#deprecation}

Since v0.1 the Plugin API and Route Metadata contracts are **frozen**
(SPEC part II §1.5). The normative registry is
[docs/CONTRACTS.md](docs/CONTRACTS.md), generated from the declarations.
What freezing means in practice:

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

## Performance rules (SPEC §8.5)

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
   `void bench b1` with and without the middleware and record
   "B1 with my middleware = −X%" in the PR (see
   [bench/README.md](bench/README.md); budgets and thresholds are
   ADR-0014 / [docs/BENCH-v0.1.md](docs/BENCH-v0.1.md)).

CI runs B0/B1 with a 5% relative regression gate (merge-base vs head on
the same runner); absolute §8.2 budgets are verified on the recorded
reference environment (`bench/results/baseline.jdn`).

## Commit style

`feat:` / `fix:` / `refactor:` / `test:` / `chore:` / `docs:` /
`style:` / `perf:` / `revert:` — one logical change per commit; the
ROADMAP checkboxes update in the same commit that lands the work.

## Definition of Done (any plugin)

1. Manifest passes `plugin/dry-run`; removing the plugin from
   `:plugins` leaves no trace.
2. Config schema + tests for invalid configs; secrets never print.
3. `plugin/inspect` shows every contribution.
4. Tests: unit + integration through `void/test` fixtures; middleware
   ships its bench line (§8.5 rule 4).
5. Docs: the plugin's declarations carry `:doc` strings — CONTRACTS.md
   regenerates from them.
6. Nothing blocking on the ev loop (§8.5 rule 1).
