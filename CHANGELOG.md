# Changelog

> A projection of the git history (`scripts/gen-changelog.janet`), not a manuscript: every commit in this repository is already named `type: what`, and the tags mark the release boundaries. The file is regenerated at a release; it is not edited by hand — the edit goes where it was projected from.

> v0.3 and v0.4 are missing here: the repository once rebuilt its history, and those tags still point at commits it no longer contains. A tag the history does not hold cannot be a boundary, so the release below covers everything that accumulated since the previous *live* tag.

## Unreleased

after v0.5

### Added

- the service pages — an operator's dark theme, and the real reason they looked broken: the dash and admin asset routes answered with an immutable struct, so the CSRF middleware could not add its cookie header and the stylesheet 500'd in any composition with void/security (`d32eeaa`)
- void/dash in the shop composition — the dashboard over the forty plugins of a real application; :plugins-for reads its three environment switches at call time (`162d8d1`)
- a start without friction — void new writes a dev compose file, a smoke suite and a prod profile; void doctor names what the machine is missing, in sentences and in an exit code; void services prints compose rather than editing it (`10ec63e`)
- pressure knows about the pool — a built-in :void.pressure/check for an exhausted :db/pool (a waiter threshold with a grace period up to the checkout timeout), and a test of the obs pool gauges against a live pool (`e9d369b`)
- void/dash — the dev dashboard as a fourth projection: six reader pages over plugin/inspect, config/explain, boot and the route table, a ring sink of logs with a live tail, and history with sparklines (`82f8c06`)

### Fixed

- false "server is under pressure" 503s — both causes were in the scheduler: a connection fiber that never parks starves the timers, and the sampler recorded the whole busy period as loop lag; a yield budget and a heartbeat stamp fix both (`e60d751`)
- the password is hashed outside the transaction — the register routes in shop and blog drop :void.db/txn, because a KDF under BEGIN IMMEDIATE holds sqlite's single writer (`0b6b9b1`)
- sqlite waits cooperatively — the busy-wait moved out of the C call, where it blocked the whole ev loop, into the driver: retry plus ev/sleep within the same busy timeout (`41cb70d`)
- :plugins-for — a composition as a function of the profile becomes an explicit boot-option contract; run! and every CLI command resolve it, and guessing the plugins binding out of main by name is gone (`b72b692`)
- the site and the registries — tables and links inside emphasis finally render (with a smoke test in the generator), the site builds in CI, and gen-contracts became a projection of packages.janet (`fd277a5`)
- admin/MCP — the list tool reads :list rather than :detail (the examples' password hashes stop reaching an agent), nil from :scope means nothing, resource declarations go through the same ensure!, and a secret column warns (`51e33fe`)
- the security layer — introspection without aud/iss is refused (the confused deputy is closed on both branches), and the webhook channel neither reaches private ranges nor carries configured headers to somebody else's URL (`0499b6b`)
- the kernel cleans up after itself — a late start! failure stops the system, component data schemas are validated, a failed restart is retried by the watcher; netrepl only outside :prod, with a 0700 socket (`597ff08`)
- the response cache moves inside authz (phase 5500) and steps aside for a Cookie (opt-in :vary-cookie false), single-flight survives recursion; storage — SigV4 encodes the path exactly once (`095ff8e`)
- redis — a scanner/grammar disagreement no longer poisons the pool (parse under protect plus mark-broken), an unclean connection (MULTI/WATCH/pending) is closed on checkin (`7c20ee0`)
- the queue — token fencing for settle!/touch! on every backend, a SAVEPOINT around the unique insert, _locks cleanup and honest docstrings for the cron guarantees (`6251bb8`)
- a connection abandoned mid-protocol no longer returns to the pool — :reusable? on the driver, a cancellation-proof handoff of waiters, db/detached for ev/go, and drained collect/stream (`fd6d26d`)
- HTTP wire hygiene — CRLF in outgoing headers, the empty chunk, a strict Content-Length, query with [ ] and UTF-8, Secure on the session cookie, deadlines against slowloris, Origin on WS (`0873b48`)

### Documentation

- the roadmap for wave 7, and the idea-to-deploy walkthrough checked against the nine files the template writes (`922fc35`)
- the site — Getting Started with output taken from a real run, an API reference over 39 packages projected from manifests and docstrings, a cookbook off the examples, and an honest comparison page (`c77154d`)

## v0.5 — 2026-09-02

end of wave 6 — parity and the first application: storage, the auth scaffold, the jobs dashboard, notifications, tailwind without node, htmx 4 — and examples/hub, deployed

### Added

- hub deployed — two replicas, a worker, a bucket, and the three things running it found (`6f5c96e`)
- six things the hub sent back — generators that say what they need, jobs that say what they need open (`84e26de`)
- htmx 4 — one header decides the layout, inheritance by name (`aa53ee1`)
- hub example — GitHub webhooks signed, stored, delivered to telegram (`55c978c`)
- assets without node, and an installable bundle in its own tree (`0dd1624`)
- notify — notification as data, channels as composition (`f904c67`)
- jobs dashboard — the queue as pages over the jobs contract (`a73ba74`)
- void make auth — login scaffold with a generated test suite (`2e66770`)
- storage — files and uploads, key as data, SigV4 on crypto (`f21f39d`)
- tls — outgoing TLS over libssl with memory BIOs (`c653d8a`)
- i18n and datastar — dictionaries as contributions, SSE morph pages (`c009478`)
- integrations — oauth code+PKCE client and kafka event API (`3e4c6c1`)
- obs-otlp — protobuf as a second projection of the same payload (`61512d1`)
- db-mysql driver; query builder and postgres-info fixes (`4d1519f`)
- cli — artisan commands, a composition lock file, one file per deploy (`391b096`)
- proto and grpc — protobuf as data, Connect-RPC where a method is a route (`240637b`)
- mcp and admin — declarations projected, gates closed by construction (`3deee57`)
- deploy shape — no in-memory store outside a single process (`277fb88`)
- http client, websockets as routes, and OTLP/JSON observability (`5364e6c`)
- shop example — the full stack in one modular application (`53491ef`)
- bus — message as fact, guarantee as a backend declaration (`6046520`)
- mail — message as data, delivery as a composition decision (`894392b`)
- security — crypto, identity, ABAC authz, CSRF and rate limits (`e231f68`)
- obs — metrics, spans and the price of instrumentation (`e8f77d2`)

### Documentation

- README v0.5 — waves 0-6 closed, the application deployed (`6736d4b`)
- publish the documentation site to GitHub Pages (`9445fa0`)

## v0.2 — 2026-08-28

end of wave 2 — the product minimum, core parity with Laravel

### Added

- distribution — monorepo as one jpm bundle, package graph as data (`cb61cfc`)
- pressure — load shedding, a flag instead of unresponsiveness (`b39450f`)
- jobs — background jobs on one contract and three backends (`3eba81f`)
- cache and redis — memory store with TTL/LRU, wrap, RESP2/3 client (`63741d7`)
- db — SQL kernel, entity layer, sqlite and async postgres drivers (`eb27d52`)

### Performance

- request-id and access-log tuned against a fresh baseline (`4fe82cf`)

## v0.1 — 2026-08-27

end of wave 1 — HTMX applications can be built on it, and there is something to show; the Plugin API and Route Metadata contracts are frozen

### Added

- request lifecycle stages and inject testing without a socket (`d82a9b4`)
- core/log structured logger; contracts v1 frozen with a CI drift check (`afa9576`)
- dev loop and benchmarks — hot reload, explain-route, bench budgets in CI (`dda9842`)
- cli — void binary, commands as an extension point (`6104b0b`)
- rest — defresource, schema validation, problem+json, OpenAPI 3.1 (`e588c8f`)
- html — hiccup pipeline, schema forms, assets, htmx helpers (`8fc3bb6`)
- http — server, router, middleware, sessions, prefork (`13618d9`)
- core — systems, config, schema, plugins, hooks and dev tooling (`7f3096a`)
