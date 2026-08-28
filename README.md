# void

> *void — everything Janet keeps, one import away*

A batteries-included web framework for [Janet](https://janet-lang.org/): Laravel/Spring-level capabilities, Lisp-idiomatic architecture, REPL-driven development as a first-class mode. Everything is extensible through plugins in the spirit of Spring auto-configuration — but with data instead of annotations and classpath scanning.

> The name comes from Janet canon (*The Good Place*): Janet's boundless void, where everything is stored — "batteries included" as a character. Not affiliated with Void Linux.

## Status

**v0.1 — the wave-1 vertical slice.** You can build server-rendered HTMX applications: `void new myapp && cd myapp && void dev` gives you a schema-validated form app with hot reload (live handler redefinition *and* automatic route-table rebuilds) and a netrepl into the running process. The Plugin API and Route Metadata contracts are **frozen** — the registry is [docs/CONTRACTS.md](docs/CONTRACTS.md) (generated from the declarations, drift-checked in CI), the deprecation procedure is in [CONTRIBUTING.md](CONTRIBUTING.md).

The full specification lives in [docs/SPEC.md](docs/SPEC.md), the wave plan in [docs/ROADMAP.md](docs/ROADMAP.md), performance budgets and the recorded baseline in [docs/BENCH-v0.1.md](docs/BENCH-v0.1.md). The async-libpq feasibility risk has been retired by a working prototype (SPEC, Appendix A).

## Quick start

```sh
jpm install https://github.com/bondiano/void.git   # the whole framework, one bundle

void new guestbook
cd guestbook
jpm --local deps    # pin this void in ./jpm_tree (the binary prefers it)
void dev            # dev profile: file watcher + netrepl + the app
void routes         # the route table, `void routes --keys` with metadata
void repl           # repl into the running process
```

Every line of that runs on a clean machine as a CI job, not as a
paragraph here (ADR-0020). Installing needs a C compiler — spork, which
`void/core` depends on, builds nine native modules of its own, and void
adds one (`void/fdwait`, ~60 lines).

The generated app — the same one as [`examples/guestbook`](examples/guestbook) — is a server-rendered HTMX guestbook: one map schema drives the form markup, the coercing validation (`form/check`) and the re-render-with-errors loop; the POST route answers htmx requests with the bare fragment (`:void.htmx/partial`). Out of the box every request carries a request-id bound to the log context and an access-log record lands through `void/core/log` on the `:on-response` lifecycle stage (ADR-0016/0018); tests drive the full stack in memory with `test/inject` — no sockets (ADR-0017).

## Where void fits

Single binary < 5 MB, RSS < 50 MB, a live REPL into the production process, and batteries included (db / jobs / auth / observability / MCP). The sweet spot: server-rendered HTMX applications of small-to-medium complexity where cost of deployment and ownership matters more than peak throughput — internal tools and admin panels, solo/indie SaaS on a VPS, webhook and bot hubs, embedded web UIs.

**Honest anti-cases:** teams of 5+ developers, >10k RPS per process, CPU-heavy workloads, domains that require thick vendor SDKs.

## Repository layout

Monorepo of scoped Janet packages. They install as **one** jpm bundle
named `void` and release one version per wave — jpm resolves a
dependency to a git repository with a `project.janet` in its root, and
has no notion of a subdirectory (ADR-0020). The edges between the
packages are declared once, as data, in
[`scripts/packages.janet`](scripts/packages.janet); the bundle's source
list, every test suite's module path, the CI steps and the dry-run gate
are projections of it.

| Directory | Package | Wave |
|---|---|---|
| `core/` | `void/core` — component system, config, schema, plugin API, hooks, structured logger (`void/core/log`, ADR-0018) | 0 |
| `dev/` | `void/dev` — netrepl, file watcher, `void/test` fixtures/factories and the `test/inject` full-stack client (ADR-0017) | 0 |
| `http/` | `void/http` — HTTP kernel: net/ev server (keep-alive, limits, chunked, SSE, graceful drain), PEG router with symbol handlers and metadata merge, phased middleware, sessions/static/multipart, prefork workers (ADR-0015, 0010) | 1 |
| `html/` | `void/html` — SSR view layer: hiccup pipeline (function components, layouts, partials), form helpers projected from schemas, fingerprinted asset manifest with dev passthrough, temple as the alternative engine behind `:void.html/engine` | 1 |
| `htmx/` | `void/htmx` — htmx integration: hx-attribute builders, HX-\* request predicates and response headers, OOB swaps, fragment-without-layout answers on routes marked `:void.htmx/partial` | 1 |
| `rest/` | `void/rest` — REST/JSON sugar over void/http: `:void.schema/*` route metadata drives request coercion+validation and response serialization, RFC 7807 problem+json, `defresource` CRUD groups, pagination/sorting/filtering conventions | 1 |
| `openapi/` | `void/openapi` — OpenAPI 3.1 as a pure projection of the route table + schema registry, `/openapi.json` + Swagger UI in dev, export for CI | 1 |
| `cli/` | `void/cli` — the `void` binary: commands as the `:void.core/cli` extension point, subset bootstrap via `:needs`, `void new` / `void dev` / `void routes` / `void repl` | 1 |
| `bench/` | `void/bench` — bench-suite (ADR-0014): B\* mini-apps (B0 plaintext, B1 JSON, B2 Postgres query, B3 Postgres + SSR), wrk/wrk2 методика, Go/FastAPI calibration baselines, 5% regression thresholds in CI, and `bench/probe` — a fiber inside the app under load, because the loop-lag and GC budgets of §8.2 cannot be seen from outside the process | 1 |
| `db/` | `void/db` — database kernel (ADR-0009): the `:void/db-driver` contract, fiber-aware pool with metrics, SQL as data, dyn-scoped transactions (plus `:void.db/txn` route metadata in `void/db-http`), migrations, Data Mapper entity layer with thin AR sugar and an N+1 guard | 2 |
| `db-sqlite/` | `void/db-sqlite` — the reference driver: janet-lang/sqlite3 behind the contract, per-connection pragmas, RETURNING when the library has it, and the binding's sharp edges (no URI filenames, so `:memory:` is one connection) turned into boot errors rather than surprises | 2 |
| `fdwait/` | `void/fdwait` — the monorepo's one native module (~60 lines of C, ADR-0011): park a fiber until a descriptor owned by a C library is readable or writable, without touching it. What `ev/` cannot express, and the reason an FFI database driver needs no thread pool | 2 |
| `db-postgres/` | `void/db-postgres` — Postgres over libpq's non-blocking API, driven from the ev loop through `void/fdwait`: prepared statements, real isolation levels and savepoints, single-row streaming, pipeline mode, LISTEN/NOTIFY on its own connection, cancellation, and TLS because libpq does it | 2 |
| `redis/` | `void/redis` — RESP2/RESP3 in pure Janet on the ev loop (no native code, no client library): the wire format as a length-driven scanner plus a PEG, a fiber-aware pool, pipelining, value codecs behind `:void.redis/codec`, Lua scripts, and pub/sub on a connection of its own. `void/redis-http` (same package) contributes the `:redis` session store, which is what lets sessions and prefork workers coexist | 2 |
| `cache/` | `void/cache` — the cache: the `:void/cache-store` contract and the `:void/cache` interface over it, an in-process store with TTLs and an exact LRU, read-through (`remember`) and memoization (`wrap`) with single-flight, and a store failure that degrades to a miss rather than to a 500. `void/cache-redis` (same package) puts it in redis; `void/cache-http` caches responses of routes marked `:void.cache/response` | 2 |
| `jobs/` | `void/jobs` — background jobs: the `:void/jobs-backend` contract (eight functions over records, exactly one of which has to be atomic) and the `:void/jobs` interface over it, an in-process backend, `defjob` with retries, backoff+jitter, priorities, delays, uniqueness and a dead letter queue, parent-child flows, per-queue rate limiting and concurrency with group keys for fair scheduling, and `defschedule` cron that fires once across a fleet. `void/jobs-db` (same package) keeps the queue in the database, claiming with `FOR UPDATE SKIP LOCKED` where there is one; `void/jobs-redis` keeps it in redis, claiming with a Lua script that promotes, skips capped groups and marks the job running in one round trip | 2 |
| `pressure/` | `void/pressure` — load shedding (ADR-0019): a fiber samples event-loop lag and RSS, thresholds with a recovery bar under them keep one boolean, and `:void.pressure/check` contributions cover what the runtime cannot measure. `void/pressure-http` (same package) turns that boolean into a fast 503 + `Retry-After` in phase 100 — before parsing, sessions or a pooled connection — while routes marked `:void.pressure/exempt` are never wrapped, so `/health` answers *while* the process refuses everything else. What it costs a request that is not being shed: nothing measurable — `janet main.janet b1 b1-pressure` in `bench/` puts the two rows side by side (SPEC §8.5) and the delta sits inside run-to-run noise | 2 |

`examples/` holds one example application per wave (they double as smoke tests in CI): `examples/demo` (the wave-0 toy plugin), `examples/guestbook` (the wave-1 HTMX guestbook).

Upcoming waves (see [docs/SPEC.md](docs/SPEC.md) §6): enterprise (`void/obs`, `void/auth`, `void/authz`, `void/bus`), protocols and `void/admin`.

## Development

Requires [Janet](https://janet-lang.org/) ≥ 1.41, jpm and a C compiler.

```sh
janet scripts/bootstrap.janet   # external deps + build void/fdwait
cd core && jpm test             # any package; the module path is wired
                                # from the graph, nothing is installed
```

Contributors never install void to use it — `scripts/void` is the CLI
running straight off the checkout, so an edit in `core/` is live in the
next command:

```sh
scripts/void new myapp
cd myapp && ../scripts/void routes
```

`void/db-postgres` needs a Postgres to test against:

```sh
cd db-postgres && jpm test    # config/types run everywhere; the rest
                              # skips without a server

VOID_TEST_PG="postgres://void:void@127.0.0.1:5432/void_test" jpm test
```

libpq itself is opened at runtime through `ffi/` (`brew install libpq`,
`apt install libpq5`) — nothing links against it, and a machine without
it is told so at boot rather than at install time. `janet-lang/sqlite3`
is the same deal for `void/db-sqlite`: the bundle leaves the binding out
on purpose, and the driver resolves it on first use, so an application
that never lists `:void/db-sqlite` in its `:plugins` never needs it.
