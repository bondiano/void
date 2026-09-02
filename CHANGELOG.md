# Changelog

> Проекция git-истории (`scripts/gen-changelog.janet`), не рукопись: каждый коммит репозитория уже назван по форме `type: что (волна, ADR)`, теги отмечают границы релизов, ADR-ссылки ведут к решениям. Файл регенерируется на релизе; правки руками сюда не вносятся — они вносятся туда, откуда он собран.

> v0.3 и v0.4 здесь нет: репозиторий однажды пересобрал историю, и эти теги остались указывать на коммиты, которых в ней больше нет. Тег, которого история не содержит, не может быть границей — поэтому релиз ниже охватывает всё, что накопилось с предыдущего *живого* тега, а границы волн живут в [ROADMAP](docs/ROADMAP.md).

## v0.5 — 2026-09-02

конец волны 6 — паритет и первое приложение: хранилище, auth-скаффолд, jobs-дашборд, нотификации, tailwind без node, htmx 4 — и examples/hub, задеплоенный

### Добавлено

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

### Документация

- README v0.5 — волны 0–6 закрыты, приложение задеплоено; санитарный проход пройден локально (`6736d4b`)
- publish the documentation site to GitHub Pages (`9445fa0`)

## v0.2 — 2026-08-28

конец волны 2 — продуктовый минимум, Laravel-паритет по ядру

### Добавлено

- distribution — monorepo as one jpm bundle, package graph as data (`cb61cfc`)
- pressure — load shedding, a flag instead of unresponsiveness (`b39450f`)
- jobs — background jobs on one contract and three backends (`3eba81f`)
- cache and redis — memory store with TTL/LRU, wrap, RESP2/3 client (`63741d7`)
- db — SQL kernel, entity layer, sqlite and async postgres drivers (`eb27d52`)

### Производительность

- request-id and access-log tuned against a fresh baseline (`4fe82cf`)

## v0.1 — 2026-08-27

конец волны 1 — «можно строить HTMX-приложения, есть что показать»; контракты Plugin API и Route Metadata заморожены

### Добавлено

- request lifecycle stages and inject testing without a socket (`d82a9b4`)
- core/log structured logger; contracts v1 frozen with a CI drift check (`afa9576`)
- dev loop and benchmarks — hot reload, explain-route, bench budgets in CI (`dda9842`)
- cli — void binary, commands as an extension point (`6104b0b`)
- rest — defresource, schema validation, problem+json, OpenAPI 3.1 (`e588c8f`)
- html — hiccup pipeline, schema forms, assets, htmx helpers (`8fc3bb6`)
- http — server, router, middleware, sessions, prefork (`13618d9`)
- core — systems, config, schema, plugins, hooks and dev tooling (`7f3096a`)
