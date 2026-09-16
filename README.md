# void

<p align="center">
  <img src="https://raw.githubusercontent.com/bondiano/void/main/docs/logo.png" alt="void" width="240">
</p>

<p align="center">
  <a href="https://github.com/bondiano/void/actions/workflows/ci.yml"><img src="https://github.com/bondiano/void/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://bondiano.github.io/void/"><img src="https://img.shields.io/badge/docs-bondiano.github.io%2Fvoid-2b6cb0" alt="Documentation"></a>
  <a href="https://janet-lang.org/"><img src="https://img.shields.io/badge/janet-%E2%89%A5%201.41-7c3aed" alt="Janet ≥ 1.41"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-16a34a" alt="MIT"></a>
</p>

**The one-person framework for [Janet](https://janet-lang.org/)** — for the developer who writes the thing, ships it, and is also the one paged about it. Declare an entity once and the form, the JSON API, the OpenAPI document, the admin page and an agent's MCP tool are all projections of that one declaration; there is nothing to keep in sync because there is only one of it. The whole application compiles to a single binary under 5 MB that starts in ms, carries its own CLI, and keeps a REPL open into the process serving production traffic.

Batteries are included and they come from one vendor: HTTP, SSR, a database layer, jobs, auth, observability, a back office. Everything past that is a plugin — and a plugin is data, not an annotation and not a classpath scan, so what a composition contains is a value the CLI can print back at you.

> *void — everything Janet keeps, one import away.* The name comes from Janet canon (*The Good Place*): Janet's boundless void, where everything is stored — "batteries included" as a character.


## It provides

- an HTTP kernel on Janet's event loop — keep-alive, chunked, SSE, graceful drain, prefork workers (`void/http`)
- a PEG router with symbol handlers, so a redefined handler is live in the running process
- server-rendered views as hiccup, with forms projected from schemas (`void/html`)
- htmx 4 integration, including fragment-without-layout answers on a route (`void/htmx`)
- JSON APIs with schema-driven coercion, RFC 7807 problems and `defresource` CRUD (`void/rest`)
- OpenAPI 3.1 as a pure projection of the route table (`void/openapi`)
- a database layer with SQL as data, migrations, pooling and dyn-scoped transactions — SQLite, Postgres, MySQL/MariaDB (`void/db`)
- Redis in pure Janet, a cache with read-through and single-flight, background jobs with retries and a dead-letter queue (`void/redis`, `void/cache`, `void/jobs`)
- load shedding driven by event-loop lag and RSS (`void/pressure`)
- authentication with identity as data, an OAuth 2.1 / OIDC client, and ABAC policies that are pure functions (`void/auth`, `void/oauth`, `void/authz`)
- CSRF that follows the credential rather than the verb, security headers, and crypto off the event loop (`void/security`, `void/crypto`)
- mail, notifications over any set of channels, and a message bus with a transactional outbox (`void/mail`, `void/notify`, `void/bus`)
- WebSocket as a route, protobuf as data and Connect-RPC where a method is a route (`void/ws`, `void/proto`, `void/grpc`)
- the application as an MCP server, projected from the commands operators already run (`void/mcp`)
- a back office and a service dashboard, both projections of the schema layer (`void/admin`, `void/dash`)
- observability with capped metric cardinality, Prometheus exposition and W3C traces (`void/obs`)
- file storage where a key is data, and i18n where a dictionary is a contribution (`void/storage`, `void/i18n`)
- the `void` binary: scaffolding, a netrepl into the running process, and a single-file build with no Janet on the target (`void/cli`)

## Quick start

Installing needs a C compiler: spork, which `void/core` depends on, builds nine native modules of its own, and void adds one. Janet's `ev/` parks a fiber on a socket the runtime owns, and has no way to say "wake me when *this* descriptor is readable" — which is exactly what a C library like libpq or librdkafka hands you. `void/fdwait` is that missing primitive, and it is why an FFI driver in void is fibers all the way down instead of a thread pool wrapped around a blocking call.

```sh
jpm install https://github.com/bondiano/void.git   # the whole framework, one bundle

void new guestbook
cd guestbook
jpm --local deps    # pin this void in ./jpm_tree (the binary prefers it)
void dev            # dev profile: file watcher + netrepl + the app
```

Open <http://localhost:8080>. Then, while it keeps running:

```sh
void routes         # the route table; --keys adds metadata, --chain <path>
                    # the middleware chain with phases, plugins and refusals
void repl           # repl into the running process
void doctor         # what this machine is missing, in sentences and an exit code

void make resource Product name:string price:int notes:text?
                    # entity + form + views + routes + migration + a suite
void make auth      # register/login/logout, password reset and address
                    # verification, over void/auth — plus their suite
void plugins lock   # writes void.lock; `void plugins check` fails CI on a drift
jpm --local build   # -> build/guestbook: one file, no janet on the target
```

Every line of that runs on a clean machine as a CI job, not as a paragraph here.

### What the generated app is

One schema drives the form markup, the coercing validation and the re-render-with-errors loop:

```janet
(def Entry
  {:name [:string {:min 1 :max 40}]
   :message [:string {:min 1 :max 400}]})

(defn create-entry [req]
  (form/submit Entry (req :form)
    {:ok (fn [v]
           (array/push entries v)
           (html/page (guestbook-view) {:layout layout}))
     :invalid (fn [values errors]
                (html/page (guestbook-view values errors) {:layout layout}))}))

(router/defroutes :guestbook/routes
  (GET "/" home)
  ;; a swap into an element gets the bare fragment; a plain form POST
  ;; still gets the full page
  (POST "/entries" create-entry
        {:name :entries/create :void.htmx/partial true}))
```

Handlers are registered as symbols, so redefining one in the REPL — or saving the file with the watcher running — takes effect in the running process; route and metadata edits rebuild the table on the fly. Out of the box every request carries a request-id bound to the log context. The whole application is [`examples/guestbook`](examples/guestbook).

## Where void fits

The shape it fits is a server-rendered application that one person has to ship, run and keep running: internal tools, solo and indie SaaS on a VPS, webhook and bot hubs, embedded and edge web UIs. The neighbours each miss that shape from a different side — Spring is a gigabyte of JVM, Rails and Laravel are an interpreter plus a dependency tree whose assembly you own, Go is fast and ships neither batteries nor a REPL, and redbean has the deployment shape without a framework above it. The combination is the niche, not any one of those rows.

One worker sustains **29k RPS** on plaintext and **9k** on a JSON path that parses, validates against a schema and serializes, with p99 2.51 ms at a fixed 16k — measured, sourced and gated in CI ([docs/BENCH-v0.1.md](docs/BENCH-v0.1.md)); prefork multiplies that across cores. Throughput is not why you would pick void, but it is not the reason to skip it either.

**Honest anti-cases:** teams of 5+ developers — you will not hire for it. Peak throughput as the product — one worker tops out far below a multi-core Go service, and a spec written as an RPS-per-core number belongs in a compiled language. A hard p99 SLO — the tail on allocation-heavy JSON paths is GC-bound and runs about 2.8× Go's. CPU-heavy work, and domains that need thick vendor SDKs, where you would be reimplementing them. What counts as success here is deliberately not adoption: the time from an idea to a working deploy for one developer, how much of the vertical fits without leaving the stack, and the stability of the two frozen contracts. The long version is [docs/COMPARISON.md](docs/COMPARISON.md).

## Packages

A monorepo of scoped Janet packages. They install as **one** jpm bundle named `void` and release one version per wave — jpm resolves a dependency to a git repository with a `project.janet` in its root, and has no notion of a subdirectory. The edges between packages are declared once, as data, in [`scripts/packages.janet`](scripts/packages.janet); the bundle's source list, every suite's module path, the CI steps and the dry-run gate are projections of it.

### Kernel

| Package | What it is |
| --- | --- |
| [`void/core`](core) | component system, config, schema, plugin API, hooks, structured logging |
| [`void/dev`](dev) | netrepl, file watcher, test fixtures and factories, full-stack test client |
| [`void/cli`](cli) | the `void` binary — commands as an extension point, with subset bootstrap |
| [`void/fdwait`](fdwait) | the one native module: park a fiber on a descriptor a C library owns, so an FFI driver needs no thread pool |

### Web

| Package | What it is |
| --- | --- |
| [`void/http`](http) | HTTP kernel: ev server, PEG router, phased middleware, sessions, static, multipart, prefork |
| [`void/html`](html) | SSR view layer: hiccup, layouts, partials, forms projected from schemas |
| [`void/htmx`](htmx) | htmx 4: attribute builders, `HX-*` predicates, OOB and `<hx-partial>` swaps |
| [`void/datastar`](datastar) | the Datastar experiment: the handler keeps returning the page, the middleware morphs it |
| [`void/rest`](rest) | REST/JSON: schema-driven coercion, RFC 7807, `defresource`, pagination |
| [`void/openapi`](openapi) | OpenAPI 3.1 projected from the route table, Swagger UI in dev |
| [`void/ws`](ws) | WebSocket (RFC 6455) — a websocket is a route, so it meets auth and security first |
| [`void/i18n`](i18n) | dictionaries as data, merged by an explicit precedence |

### Data

| Package | What it is |
| --- | --- |
| [`void/db`](db) | driver contract, fiber-aware pool, SQL as data, migrations, dyn-scoped transactions |
| [`void/db-sqlite`](db-sqlite) | the reference driver, with the binding's sharp edges turned into boot errors |
| [`void/db-postgres`](db-postgres) | libpq's non-blocking API on the ev loop: prepared statements, streaming, LISTEN/NOTIFY |
| [`void/db-mysql`](db-mysql) | MySQL and MariaDB — blocking all the way down, so a connection gets a worker thread |
| [`void/redis`](redis) | RESP2/RESP3 in pure Janet: pool, pipelining, Lua, pub/sub on its own connection |
| [`void/cache`](cache) | store contract, in-process LRU with TTLs, read-through and memoization with single-flight |
| [`void/jobs`](jobs) | `defjob` with retries, backoff, priorities, uniqueness and a dead-letter queue |
| [`void/storage`](storage) | files and uploads — a key is data, in an ordinary text column |
| [`void/pressure`](pressure) | load shedding from event-loop lag and RSS, as a fast 503 |

### Security

| Package | What it is |
| --- | --- |
| [`void/auth`](auth) | identity as data in a dyn; `:session`, `:bearer` and `:jwt` strategies |
| [`void/oauth`](oauth) | the OAuth 2.1 / OIDC client: two routes and one hook |
| [`void/authz`](authz) | ABAC — a policy is a pure function, attributes are pulled and memoized per decision |
| [`void/security`](security) | CSRF that follows the credential rather than the verb, plus headers and limits |
| [`void/crypto`](crypto) | SHA-2, HMAC, scrypt / argon2id / PBKDF2 off the event loop, RS256/ES256 |
| [`void/tls`](tls) | outbound TLS through the system libssl; inbound stays at the reverse proxy |

### Messaging

| Package | What it is |
| --- | --- |
| [`void/mail`](mail) | mail as data: a message is a table all the way to the socket |
| [`void/notify`](notify) | one notification, several channels — a channel is a contribution |
| [`void/bus`](bus) | messages as facts, `defhandler` subscriptions, a transactional outbox |
| [`void/kafka`](kafka) | librdkafka through its event API, so none of its threads touches Janet |
| [`void/proto`](proto) | protobuf in pure Janet, over descriptors as data — no generated classes |
| [`void/grpc`](grpc) | Connect-RPC over the kernel: a method is a route, gRPC compatibility without HTTP/2 |

### Operations

| Package | What it is |
| --- | --- |
| [`void/obs`](obs) | metrics with cardinality capped by construction, Prometheus, W3C traces |
| [`void/admin`](admin) | the back office as another projection of the schema layer |
| [`void/dash`](dash) | the service dashboard: the kernel's own data as pages, with a live log tail |
| [`void/mcp`](mcp) | the application as an MCP server, projected from CLI commands and schemas |
| [`void/bench`](bench) | the B0–B4 bench suite, its wrk method, calibration baselines and CI thresholds |

## Examples

One application per wave, all of them smoke tests in CI:

| Example | What it shows |
| --- | --- |
| [`examples/demo`](examples/demo) | the smallest plugin there is |
| [`examples/counter`](examples/counter) | the Datastar experiment, live |
| [`examples/guestbook`](examples/guestbook) | the generated app: one schema, a form, htmx partials |
| [`examples/blog`](examples/blog) | CRUD with relations and migrations — its suite runs twice, on SQLite and on Postgres, over the same assertions; `admin.janet` is four declarations, one policy and one function |
| [`examples/shop`](examples/shop) | the whole framework in one process: a storefront and a checkout that takes money |
| [`examples/hub`](examples/hub) | the deployed one — signed GitHub webhooks in, chat out, `docker compose up`: two web replicas, a worker, Postgres, a bucket and a proxy. It runs off an *installed* void rather than this checkout |

## Documentation

All of it is also a website — [bondiano.github.io/void](https://bondiano.github.io/void/) — generated from this repository by `scripts/gen-site.janet`.

| Document | |
| --- | --- |
| [Getting started](docs/GETTING-STARTED.md) | the first hour, with output taken from a real run |
| [Cookbook](docs/cookbook/README.md) | forms, auth, jobs, deploy — off the examples |
| [Idea → deploy](docs/IDEA-TO-DEPLOY.md) | the whole path, checked against the files the template writes |
| [Deploy](docs/DEPLOY.md) | the single-binary story and `[:deploy :shape]` |
| [Contracts](docs/CONTRACTS.md) | the two frozen contracts, generated from the declarations |
| [Comparison](docs/COMPARISON.md) | where void sits next to Rails, Phoenix, Spring and redbean |
| [Benchmarks](docs/BENCH-v0.1.md) | the budgets and the recorded baseline |
| [Contributing](CONTRIBUTING.md) | the commit protocol and the deprecation procedure |

## Development

Requires [Janet](https://janet-lang.org/) ≥ 1.41, jpm and a C compiler.

```sh
janet scripts/bootstrap.janet   # external deps + build void/fdwait
cd core && jpm test             # any package; the module path is wired
                                # from the graph, nothing is installed
```

Contributors never install void to use it — `scripts/void` is the CLI running straight off the checkout, so an edit in `core/` is live in the next command:

```sh
scripts/void new myapp
cd myapp && ../scripts/void routes
```

Drivers that are clients of a real server run their config and type suites everywhere and skip the rest — loudly — without one. CI is where they are a gate:

```sh
cd db-postgres && jpm test
VOID_TEST_PG="postgres://void:void@127.0.0.1:5432/void_test" jpm test

cd db-mysql && jpm test
VOID_TEST_MYSQL="mysql://void:void@127.0.0.1:3306/void_test" jpm test

cd kafka && jpm test
VOID_TEST_KAFKA="127.0.0.1:9092" jpm test
```

Native libraries are opened at runtime through `ffi/` — nothing links against them, and a machine without one is told so at boot rather than at install time:

| Library | macOS | Debian/Ubuntu |
| --- | --- | --- |
| libpq | `brew install libpq` | `apt install libpq5` |
| libmysqlclient *(or MariaDB Connector/C, a first-class answer rather than a fallback)* | `brew install mysql-client` | `apt install libmysqlclient21` |
| librdkafka | `brew install librdkafka` | `apt install librdkafka1` |

`janet-lang/sqlite3` is the same deal: the bundle leaves the binding out on purpose and `void/db-sqlite` resolves it on first use, so an application that never lists `:void/db-sqlite` in its `:plugins` never needs it.

## License

[MIT](LICENSE)
