# void

> *void — everything Janet keeps, one import away*

A batteries-included web framework for [Janet](https://janet-lang.org/): Laravel/Spring-level capabilities, Lisp-idiomatic architecture, REPL-driven development as a first-class mode. Everything is extensible through plugins in the spirit of Spring auto-configuration — but with data instead of annotations and classpath scanning.

> The name comes from Janet canon (*The Good Place*): Janet's boundless void, where everything is stored — "batteries included" as a character. Not affiliated with Void Linux.

## Status

**Pre-alpha / design phase.** The full specification lives in [SPEC.md](SPEC.md). The async-libpq feasibility risk has been retired by a working prototype (SPEC.md, Appendix A).

## Where void fits

Single binary < 5 MB, RSS < 50 MB, a live REPL into the production process, and batteries included (db / jobs / auth / observability / MCP). The sweet spot: server-rendered HTMX applications of small-to-medium complexity where cost of deployment and ownership matters more than peak throughput — internal tools and admin panels, solo/indie SaaS on a VPS, webhook and bot hubs, embedded web UIs.

**Honest anti-cases:** teams of 5+ developers, >10k RPS per process, CPU-heavy workloads, domains that require thick vendor SDKs.

## Repository layout

Monorepo of scoped Janet packages, each installable on its own via jpm:

| Directory | Package | Wave |
|---|---|---|
| `core/` | `void/core` — component system, config, schema, plugin API, hooks | 0 |
| `dev/` | `void/dev` — netrepl, file watcher, `void/test` fixtures and factories | 0 |
| `http/` | `void/http` — HTTP kernel: net/ev server (keep-alive, limits, chunked, SSE, graceful drain), PEG router with symbol handlers and metadata merge, phased middleware, sessions/static/multipart, prefork workers (ADR-0015, 0010) | 1 |

Upcoming waves (see SPEC.md §6): `void/html`, `void/rest`, `void/openapi`, `void/cli`, then data (`void/db`, drivers, `void/jobs`), enterprise (`void/obs`, `void/auth`, `void/authz`, `void/bus`), protocols and `void/admin`.

## Development

Requires [Janet](https://janet-lang.org/) ≥ 1.41 and jpm.

```sh
cd core
jpm deps       # install dependencies (spork)
jpm test       # run tests
```
