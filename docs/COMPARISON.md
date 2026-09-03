# void, compared

An honest comparison with the frameworks you would otherwise use —
written to be shown to a skeptic. Numbers for void are measured and
sourced ([BENCH-v0.1.md](BENCH-v0.1.md), [DEPLOY.md](DEPLOY.md));
claims about other frameworks are kept qualitative on purpose, because
we did not benchmark them beyond the Go baseline recorded in BENCH.
The anti-cases at the bottom are the same ones the
[README](../README.md) leads with — they are part of the design, not a
disclaimer.

## What you ship

| | void | Rails | Phoenix | Laravel | Go net/http | redbean |
|---|---|---|---|---|---|---|
| On the server | one binary, 1.1–2.4 MB measured | Ruby + a gem tree | a BEAM release | PHP + `vendor/` | one binary | one binary (zip with Lua inside) |
| Hello-app RSS | 24–49 MiB across runs (see the benchmarks and their open question) | typically hundreds of MiB | tens to ~150 MiB | depends on FPM workers | small | very small |
| Startup to ready | ~21 ms measured | seconds | ~1 s | per-request (FPM) | ms | ms |
| Migrations on the target | `./app db migrate` — the binary is also the CLI | `rails db:migrate` needs the whole runtime | in the release | `artisan migrate` needs PHP | you write it | you write it |

The single-binary sizes are the measured table in
[DEPLOY.md](DEPLOY.md): 1.14 MB for the scaffold carrying its own CLI,
2.35 MB with the database layer and sqlite compiled in. redbean is the
closest neighbor in spirit here — the honest difference is that
redbean is a webserver with Lua and sqlite, while void is a full
framework (schema layer, jobs, auth, admin, observability) that
happens to compile down to the same deployment shape.

## The development loop

| | void | Rails | Phoenix | Laravel | Go | redbean |
|---|---|---|---|---|---|---|
| REPL into the *running* process | yes — netrepl, on by default in dev, opt-in in prod | `rails console` is a separate process | yes — remote iex is first-class | `tinker` is a separate process | no | Lua repl on the console |
| Redefine a handler live | yes — routes hold symbols, saving the file or redefining in the repl is enough | code reload per request | code reload | code reload | recompile + restart | edit + reload |
| Full-stack tests without sockets | `test/inject` drives the real middleware stack in memory | yes (rack-test) | yes (ConnTest) | yes | `httptest` | — |

Phoenix deserves the credit here: the BEAM had "a REPL into
production" first, and it remains the other framework where that
sentence is true. void's claim is being in that club at a fraction of
the footprint — and with the REPL reachable from a single binary that
contains no source tree.

## Batteries

Legend: **in** — ships in the framework, one vendor; *pkg* — the
community package everyone uses; — absent / do it yourself.

| | void | Rails | Phoenix | Laravel | Go | redbean |
|---|---|---|---|---|---|---|
| ORM / entities + migrations | **in** (data mapper, SQL as data) | **in** | **in** (Ecto) | **in** | *pkg* | sqlite **in** |
| Background jobs + dashboard | **in** (db or redis backend, dashboard included) | **in** (Solid Queue; UI via Mission Control) | *pkg* (Oban; dashboard paid) | **in** (Horizon for redis) | *pkg* | — |
| Auth scaffold | **in** (`void make auth`) | **in** (since 8) | **in** (`phx.gen.auth`) | **in** (starter kits) | — | — |
| Authorization (policies) | **in** (ABAC, deny-by-default gate at boot) | *pkg* (Pundit/CanCan) | *pkg* | **in** (gates/policies) | — | — |
| Observability (metrics/traces/health) | **in** (Prometheus + OTLP + `/health`) | *pkg* | **in** (Telemetry + LiveDashboard) | *pkg* | *pkg* | — |
| Admin panel | **in** — a projection of the entity declarations | *pkg* (Avo/Administrate) | *pkg* | *pkg* (Nova is paid) | — | — |
| The app as an MCP server | **in** — CLI commands become an agent's tools, one declaration | *pkg*, early | *pkg*, early | *pkg*, early | *pkg* | — |
| OpenAPI | **in** — projected from the route table, cannot drift | *pkg* | *pkg* | *pkg* | *pkg* | — |
| Mail, i18n, websockets, file storage, notifications | **in** | **in** | **in** (mail via lib) | **in** | *pkg* | — |

Two cells in that table are the unusual ones. The admin and MCP rows are
the same mechanism: `defresource-admin` registers one frozen
declaration, and it is projected into pages for a person *and* tools for
an agent — same fields, same policies, cannot drift apart . No other
framework in the table treats "the application is also an MCP server" as
a first-class projection today.

## Performance

The recorded baseline ([BENCH-v0.1.md](BENCH-v0.1.md), Apple M4 Max,
single void worker, wrk/wrk2 with coordinated omission accounted for):

- **Plaintext (B0)**: 29,154 RPS sustained max for one worker (up to
  ~43k in short sessions); p50 1.00 ms / p99 2.51 ms at a fixed 16k
  RPS.
- **JSON echo with schema validation (B1)**: 8,981 RPS; p50 1.67 ms /
  p99 3.79 ms at a fixed 6.4k RPS.
- **Go on the same machine, same methodology**: go-json holds p50
  1.26 ms / p99 3.13 ms at the same 6.4k rate, with a 42.5k RPS
  ceiling.

Read honestly: at the same offered rate void's latency is within
~0.7–0.8× of the Go ceiling for this class (an interpreter doing parse
+ validate + serialize on every request), and its p99 tail is GC-bound
— the document names mark-and-sweep on the JSON path as the enemy and
records the budget it set because of it. Max throughput is a different
story: one void worker tops out far below a multi-core Go service, which
is why **>10k RPS per process is an explicit anti-case** — the answer is
prefork workers, and past that, another language.

Methodology caveats are recorded in the document itself and they cut
both ways: absolute throughput numbers vary up to ±30% between
sessions on the same code (latency under wrk2 is stable to ~5%), CI
gates on relative 5% regressions rather than these absolutes, and the
FastAPI baseline was never published — only Go.

## Ecosystem and hiring — the honest minus

This is where void loses, and no framework feature changes it. Janet
is a small language: the package ecosystem is a fraction of a percent
of Ruby's or PHP's, there is no hiring pool, no Stack Overflow depth,
no vendor SDKs — a Stripe or AWS integration is an HTTP client and a
signature you write yourself (the S3 SigV4 in `void/storage` is
exactly that, done for you once). The framework's answer is to need
fewer packages — batteries in the box, FFI straight to the system's
libpq/libssl/librdkafka — but "fewer" is not "none", and a team that
measures by ecosystem should weigh this row heavier than any other in
this document.

## When not to choose void

Verbatim from the README, because they were written first:

- **Teams of 5+ developers** — you will not hire for it.
- **>10k RPS per process** — prefork buys some, then it is another
  language.
- **CPU-heavy workloads** — an interpreter is the wrong tool.
- **Domains that require thick vendor SDKs** — you would be
  reimplementing them.

## When void

The combination is the niche, not any single row above: a single
binary under 5 MB, a live REPL into the production process, and
batteries included — db, jobs, auth, observability, admin, MCP — from
one vendor with two frozen contracts. Server-rendered HTMX
applications of small-to-medium complexity where the cost of
deployment and ownership matters more than peak throughput: internal
tools, solo/indie SaaS on a VPS, webhook and bot hubs, embedded web
UIs, edge boxes. The [deployed example](../examples/hub) is exactly
that shape — and [GETTING-STARTED.md](GETTING-STARTED.md) is the
fifteen minutes it takes to see it yourself.
