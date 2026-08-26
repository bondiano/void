# ROADMAP: void

> Дорожная карта реализации по [SPEC.md](SPEC.md) и [ADR 0001–0015](adr/README.md). Волны — из SPEC §6, критерии готовности контрактов — из SPEC, часть II. Документ живой: статусы обновляются, порядок внутри волны может меняться, порядок волн — нет.

**Правило зависимостей:** каждый plugin зависит только от `void/core` и plugins своей волны или более ранних. Волна считается закрытой не по «код написан», а по exit-критериям.

**Сквозной принцип — dogfooding:** с волны 0 вся разработка ведётся через netrepl внутри системы; с волны 1 каждый следующий plugin строится на предыдущих (admin рендерится через html+htmx, jobs-ui — тоже, bench-приложения — обычные void-приложения).

---

## Текущее состояние (2026-08-26)

| Что | Статус |
|---|---|
| SPEC (обзор + контракты Plugin API / Route Metadata) | ✅ написан |
| ADR 0001–0015 | ✅ accepted |
| Прототип async libpq × ev (`pqwait.c`, `proto2.janet`) | ✅ риск снят (ADR-0011, SPEC прил. A) |
| Монорепо, `void/core` | ✅ `system`, `config`, `schema`, `plugin`, `meta`, `hooks` (+шина) и `void/run!` реализованы |
| `void/dev` + `void/test` | ✅ netrepl-компонент, file watcher c авто-restart, fixtures/factories (`:generator`-проекция) |
| `void/http` | ✅ HTTP kernel (1.1): сервер на net/ev (keep-alive, лимиты, chunked, SSE, drain), PEG-router с symbol-handlers и metadata-merge, фазовые middleware, sessions/static/multipart/negotiation, error rendering, `with-request`/`explain-route`, prefork `:workers :auto` |
| Всё остальное | не начато |

Открытые вопросы SPEC §7: (1) spork/http — закрыт (ADR-0015 accepted); (2) async libpq — закрыт; (3) формат route metadata — спроектирован, требует **заморозки** в конце волны 0/начале волны 1; (4) naming/монорепо — закрыт; (5) `:void-api` versioning — заложен в скелет.

---

## Обзор волн

```
Волна 0  фундамент      core: system → config → schema → plugin → hooks → dev(netrepl)
Волна 1  вертикаль      http → html → htmx → rest → openapi → cli(min) + bench B0/B1
Волна 2  данные         db → sqlite → postgres → redis → cache → jobs + bench B2/B3
Волна 3  enterprise     obs → auth → authz → security → mail → bus(memory/pg + outbox)
Волна 4  протоколы+admin proto → grpc(Connect) → obs-OTLP → ws → mcp → admin + bench B4
Волна 5  тяжёлый FFI    kafka → db-mysql → oauth → i18n → datastar → tls
```

Контрольные точки релизов:

- **v0.1 (конец волны 1)** — «можно строить HTMX-приложения, есть что показать». Контракты Plugin API и Route Metadata заморожены.
- **v0.2 (конец волны 2)** — продуктовый минимум, Laravel-паритет по ядру.
- **v0.3 (конец волны 3)** — enterprise-вертикаль: obs/auth/authz/bus.
- **v0.4 (конец волны 4)** — killer-фичи: admin + MCP. Кандидат в публичный анонс.
- Волна 5 — по потребности, вне критического пути.

---

## Волна 0 — фундамент (`void/core` + `void/dev`)

Цель: рабочее ядро, на котором вся дальнейшая разработка идёт REPL-driven. HTTP здесь нет принципиально (ADR-0006).

### 0.1 `void/core/system` — component system *(ADR-0001)*

- [x] `defcomponent`: `:deps`, `:config` (schema куска), `:start/:stop/:health`, опц. `:suspend/:resume`
- [x] Registry → topological sort → старт по зависимостям, стоп в обратном порядке
- [x] Валидация графа: cycles, missing deps, дубли ключей — с указанием конфликтующих plugins
- [x] `system/start`, `system/stop`, `system/restart :key` (рестарт транзитивных зависимых — reloaded workflow)
- [x] `:provides`-интерфейсы; >1 активной реализации без выбора в конфиге → ошибка старта
- [x] Scopes `:singleton`/`:factory`

### 0.2 `void/core/config` *(ADR-0007)*

- [x] Слои: plugin defaults ← `config/*.janet|jdn` ← env (`VOID_DB__HOST`) ← CLI overrides
- [x] Provenance каждого значения: `(config/explain :database :host)`
- [x] Профили `:dev/:test/:prod` + произвольные
- [x] Валидация всех `:config-key` по схемам **пачкой** до старта (не first-fail)
- [x] Secrets: `{:secret "DB_PASSWORD"}` — резолв из env/file, custom print (не утекают в логи/REPL)

### 0.3 `void/core/schema` *(ADR-0008)*

- [x] Базовые типы + композиция: `merge`, `select`, `optional`, `union`, рекурсивные схемы
- [x] Refinements предикатами, PEG-паттерны для строк
- [x] Coercion-режим (string→int для query/forms)
- [x] Ошибки с path (`[:tags 3]`), локализуемые
- [x] Механизм проекций (extension point `:void.core/schema-projection`); первая проекция — validator
- [x] Registry схем по имени
- [x] Опциональные `:db/*`-аннотации — парсятся и хранятся (потребители — волна 2+)

### 0.4 `void/core/plugin` — Plugin API *(ADR-0003)*

- [x] `defplugin` → manifest-struct: `:void-api`, `:version`, `:requires` (semver), `:config-key/-schema`, `:when`, `:components`, `:contributes`, `:extension-points`, `:on-load`
- [x] `defextension-point`: `:schema`, `:cardinality` (`:many/:single/:single-required`), `:reduce`, `:validate`
- [x] `defcontribution` + resolution: валидация по schema точки, ошибки с plugin-источником, did-you-mean для опечаток, «повисшие» вклады → ошибка
- [x] Bootstrap-фазы: load → config → conditional → extension resolution → graph → start → ready; shutdown с таймаутом
- [x] Базовые точки ядра: `:void.core/cli`, `/health`, `/config-source`, `/schema-type`, `/schema-projection`, `/interface`, `/hooks`
- [x] REPL-инструменты: `(plugin/inspect)`, `(plugin/why :key)`, **`(plugin/dry-run ...)`** — фазы 1–5 без старта
- [x] `void/core/meta` — merge-семантика metadata (`:replace/:concat/:deep-merge/:restrict`) живёт в core (ADR-0005: контракт не HTTP-специфичен)

### 0.5 `void/core/hooks` + lifecycle

- [x] Синхронные упорядоченные хуки (`:config-loaded`, `:before-start`, `:after-start`, `:before-stop`, `:after-stop` + произвольные; `:phase`-порядок, REPL-friendly `add!`/`remove!`)
- [x] In-process pub/sub шина на `ev` для application events (буферизованный канал + fiber на подписчика, `:*`-wildcard, backpressure, ошибки хендлера не убивают подписку)
- [x] `(void/run! {:plugins [...] :profile ...})` + сигналы (SIGTERM/SIGINT → graceful stop с таймаутом; `(void/stop! boot)` из REPL/хуков; обработчики ставятся до старта)

### 0.6 `void/dev` — канонический plugin

- [x] netrepl (spork) внутри процесса, unix socket в dev по умолчанию; repl into system environment (`system/`, `config/`, `plugin/`, `schema/`, `hooks/`, `(boot)`, `(sys)`; общий env между сессиями)
- [x] File watcher → reload затронутых env tables (`dofile :env` в тот же table — late binding сохраняется); карта file→component из manifest `:source` (пишется `defplugin`) → авто `system/restart` stateful
- [x] `void/test`: fixtures как компоненты (`:only` — подъём подмножества системы, `:components` — стабы поверх реальных), factories из schema-generator (`:generator`-проекция, seed/max-depth)

### Exit-критерии волны 0

1. `plugin/dry-run` ловит: несовместимость `:void-api`/`:requires`, битые contributions, конфликт `:provides`, cycle в графе — с указанием файла/plugin (SPEC ч. II, прил., п. 1).
2. Игрушечный demo-plugin проходит полный цикл (config-schema, компонент с `:provides`, вклады в cli/health) и удаляется из проекта одним удалением из списка — без следов (п. 2).
3. Изменение функции компонента в REPL живое без рестарта (late binding, ADR-0002); `system/restart` работает для stateful.
4. Тесты на все ошибочные сценарии графа и config-валидации; CI прогоняет `jpm test` + dry-run.

---

## Волна 1 — вертикальный slice

Цель: показываемое HTMX-приложение и **заморозка обоих контрактов** (Plugin API + Route Metadata) → v0.1.

### 1.0 Преддверие: принять ADR-0015

- [x] Spike: прочитать spork/http, забрать парсеры/примитивы, зафиксировать решение accepted — примитивы в `http/void/http/wire.janet`

### 1.1 `void/http` — HTTP kernel *(L; ADR-0006, 0015, 0010)*

- [x] Сервер на net/ev: keep-alive + pipelining, лимиты (max-header/max-body/read/idle timeouts, smuggling-проверки TE/CL), chunked (запрос и ответ), SSE (chunk на событие), graceful drain (idle рвутся сразу, in-flight дорабатывают под deadline) — `http/void/http/server.janet`
- [x] Ring-модель: request/response — plain tables; middleware — обёртки — `ring.janet`
- [x] Router: PEG-компиляция, route table — immutable значение, атомарный swap (`router/cell` + `swap!`); handlers — символы с live-резолвом через env таблицы модулей (ADR-0002; `router/env-ref` для env в замороженных manifests) — `router.janet`
- [x] Route metadata: namespaced-ключи, декларация через `:void.http/route-meta-key`, merge route←group←global на `void/core/meta`, `:restrict` для `:void.http/timeout`/`max-body`, прекомпиляция цепочки на билде таблицы (`:when`-middleware вне цепочки, если предикат false)
- [x] Фазовые константы middleware (0–9000), тай-брейк по имени plugin — `middleware.janet`
- [x] Content negotiation (`negotiate.janet`), static etag/range (`static.janet`), cookies (`ring.janet`), multipart (`multipart.janet`), session — point `:void.http/session-store`, memory store тут (`session.janet`; с `:workers > 1` memory-store — ошибка старта, ADR-0010)
- [x] Error handling: exception→response (`errors/abort` со статусом), point `:void.http/error-renderer` — `errors.janet`
- [x] `(http/explain-route "/x")` — итог и происхождение каждого meta-значения по слоям
- [x] `(http/with-request {...})` — прогон через полный стек без сети; dev error page со стектрейсом
- [x] Prefork `:workers :auto` (SO_REUSEPORT — janet ставит его в `net/listen` сам) — полностью: master re-exec'ает свой же процесс, супервизия с respawn+backoff, SIGTERM→drain каскадом; e2e-тест master+2 воркера — `prefork.janet`

### 1.2 `void/html` *(M)* → 1.3 `void/htmx` *(S)*

- [x] hiccup-pipeline (htmlgen): компоненты-функции (tuple с функцией в голове), layouts/partials — обычные функции; lazy view responses (`html/page`/`html/fragment`) рендерятся middleware на выходе — `html/void/html/hiccup.janet`, `init.janet`; snapshot testing — `test/snapshot` в `void/test` (dev)
- [x] Form helpers из schema: `form/field-specs` (проекция map-схемы в контролы), `form/fields`/`form/form` (значения, ошибки schema/check, CSRF-слот через `(dyn :void.html/csrf)`), `form/check` (string-ключи формы → keyword + coerce) — `html/void/html/form.janet`
- [x] Asset pipeline: `assets/build!` (crc32-fingerprint + manifest.jdn), href через manifest в prod / passthrough в dev; temple как альтернативный движок за point `:void.html/engine` (выбор в `[:html :engine]`, override на response) — `assets.janet`, `temple.janet`
- [x] htmx: hx-хелперы (`hx/attrs`, verb-сахар, JSON для hx-vals), `HX-Request` → фрагмент без layout на маршрутах с `:void.htmx/partial` (middleware фазы 9500 снимает layout до рендера; history-restore сохраняет), `hx/oob`, `HX-Trigger`/`HX-Redirect`/`HX-Location`/`HX-Reswap` и остальные response-хелперы — `htmx/void/htmx/`

### 1.4 `void/rest` *(S)* → 1.5 `void/openapi` *(S)*

- [x] `defresource`: schemas на route → авто-валидация/coercion/сериализация; RFC 7807 problem+json
- [x] Pagination/sorting/filtering conventions
- [x] OpenAPI 3.1 как чистая проекция route table + schema registry; Swagger UI в dev; `void openapi export` (функция + `:void.core/cli` contribution; бинарь — 1.6)

### 1.6 `void/cli` — минимум *(M→S в этой волне)*

- [x] Бинарь `void`; команды — extension point; bootstrap подмножества системы (`:needs [...]`)
- [x] `void new` (шаблон проекта), `void routes` (+`--keys`), `void repl` (netrepl-клиент)

### 1.7 Bench-suite: старт *(ADR-0014)*

- [ ] Каркас `void bench` + `bench/apps/`: B0 plaintext, B1 JSON echo; wrk2/wrk, методика из SPEC §8.3
- [ ] Первый прогон фиксирует baseline → пороги регрессии 5% в CI
- [ ] Baselines для калибровки: Go net/http, FastAPI

### Exit-критерии волны 1

1. Demo-приложение (server-rendered HTMX, формы с валидацией из schema) работает; `void new && void dev` → рабочий цикл с hot reload.
2. Контракты заморожены: reserved-ключи metadata v1 и schema всех extension points зафиксированы в docs; дальнейшие изменения — только через deprecation (SPEC ч. II, 1.5).
3. `explain-route` показывает происхождение каждого значения (п. 3 критериев готовности).
4. B0/B1 в CI с порогами; бюджеты SPEC §8.2 проверены или скорректированы с фиксацией причин.
5. Тег v0.1.

---

## Волна 2 — данные

Цель: продуктовый минимум (Laravel-паритет по ядру) → v0.2.

### 2.1 `void/db` — kernel + entity layer *(M; ADR-0009)*

- [ ] Интерфейс `:void/db-driver` (connect, query, tx, prepared, pool contract)
- [ ] Fiber-aware пул: чекаут в dyn, авто-возврат; метрики пула (wait time)
- [ ] Query builder (SQL как данные, диалекты через драйвер)
- [ ] `(db/with-tx ...)` через dyn + декларативно `:void.db/txn` в route metadata
- [ ] Migrations: janet up/down, таблица версий, `void db migrate/rollback/status`
- [ ] Entity: `defentity` (= defschema + db-mapping), Repository API (`find/query/insert!/update!/delete!`, явный `:preload` batched-IN)
- [ ] AR-сахар через table prototypes: snapshot в proto, `save!` диффит → partial UPDATE; `db/rel`
- [ ] N+1-guard: `db/rel` вне preload — warning в dev, ошибка в `:strict`; callbacks на entity — НЕТ (ADR-0009)
- [ ] Инструментация драйвера (timing → obs, когда появится)

### 2.2 Драйверы

- [ ] `void/db-sqlite` *(S)* — обёртка janet sqlite3; референс-реализация контракта драйвера
- [ ] `void/db-postgres` *(M; ADR-0011)* — производственный вариант прототипа: shim `void/fdwait` (обобщение pqwait), `PQsendQueryParams`/prepared, pipeline mode, NOTIFY, cancel, row-mode, TLS через libpq
- [ ] `void/redis` *(M)* — RESP2/3 на PEG, pipelining, pub/sub; `:provides :void/cache :void/session-store :void/queue-backend`

### 2.3 `void/cache` *(S)*

- [ ] Интерфейс + memory impl (TTL, LRU); `(cache/wrap f ...)`; redis-backend

### 2.4 `void/jobs` *(M/L; ADR-0012)*

- [ ] Поверх spork/tasker; persistence — point `:void.jobs/backend`: db (SKIP LOCKED polling), redis
- [ ] `defjob` (символы → hot reload), retries backoff+jitter, приоритеты, delayed, unique, DLQ
- [ ] Flows (parent-child DAG), rate limiting per queue, concurrency per worker, group-ключи
- [ ] Repeatable: spork/cron, `defschedule`, single-instance через backend-lock
- [ ] Lifecycle events в bus (появится в волне 3 — пока hooks)

### 2.5 Bench

- [ ] B2 (PG query), B3 (PG + SSR) в CI; проверка бюджетов ev-loop-lag/GC из §8.2

### Exit-критерии волны 2

1. Demo: CRUD-приложение на Postgres с миграциями, background-джобами и кэшом; то же на SQLite сменой конфига.
2. Драйвер PG не блокирует loop: тест «конкурентные pg_sleep + ticker» из прототипа — в CI.
3. N+1-guard и dirty-tracking покрыты тестами; `void db erd` строит диаграмму из `:db/rels`.
4. B2/B3 в CI. Тег v0.2.

---

## Волна 3 — enterprise

Цель: наблюдаемость и безопасность уровня Spring → v0.3.

### 3.1 `void/obs` *(L)*

- [ ] Logs: structured (JDN/JSON), контекст из dyn (request-id/trace-id), уровни per-namespace, смена в рантайме
- [ ] Metrics: counters/gauges/histograms; RED per route из route table; runtime (GC, fibers, pools); Prometheus text export
- [ ] Tracing: span API в dyn (per-fiber), W3C traceparent in/out (OTLP-export — волна 4, после proto)
- [ ] ev/loop-lag гистограмма (главный health-индикатор, §8.4); p99 «accept→handler»
- [ ] Auto-instrumentation: point `:void.obs/instrument` — db, redis, http-client, jobs
- [ ] `/health`, `/ready`, `/metrics`; overhead ≤ 7% throughput (проверка на B1)

### 3.2 `void/auth` *(M)* → 3.3 `void/authz` *(M)* → 3.4 `void/security` *(S/M)*

- [ ] auth: identity abstraction; стратегии как extension point — session+password (argon2/scrypt), magic link/OTP, API tokens, JWT; `current-user` в dyn; `:void.auth/access` в metadata
- [ ] authz: ABAC policy-as-data, `defpolicy` — чистые функции; attribute providers — компоненты; enforcement по `:void.authz/policy` + явный `(authz/can? ...)`; `explain`-режим (почему deny); decision log; RBAC как сахар
- [ ] security: CSRF (session token, auto-inject в формы, htmx meta, double-submit для API), security headers + CSP builder, rate limiting (memory/redis), CORS

### 3.5 `void/mail` *(S)*

- [ ] SMTP-клиент, шаблоны через void/html, отправка через void/jobs (нужен для magic link)

### 3.6 `void/bus` *(M; ADR-0012)*

- [ ] Message = plain table; codecs через schema layer (point `:void.bus/codec`)
- [ ] Router: `defhandler` на topic, middleware-цепочка (retry, poison queue, dedup, correlation-id, tracing continuation из HTTP)
- [ ] Backends (point `:void.bus/backend`): `:memory` (ev/chan), `:pg` (LISTEN/NOTIFY + таблица); гарантии декларируются backend'ом
- [ ] **Transactional outbox**: `(bus/publish-tx tx topic msg)` + forwarder-компонент
- [ ] CQRS-слой (command/event bus) — опционально, можно сдвинуть

### Exit-критерии волны 3

1. Demo: приложение с логином (password + magic link), row-level ABAC, audit через bus, полные метрики/трейсы.
2. Outbox-тест: сообщение не теряется и не публикуется при откате транзакции.
3. Overhead obs ≤ 7% на B1; loop-lag p99 < 1 ms под целевой нагрузкой. Тег v0.3.

---

## Волна 4 — протоколы и админка

Цель: killer-фичи (admin + MCP) и протокольная ветка → v0.4, кандидат в публичный анонс.

### 4.1 Протокольная ветка

- [ ] `void/proto` *(M)* — pure-Janet varint/wire-кодек (hot core можно в C позже), PEG-парсер `.proto` → schema-проекции → codegen; фундамент для grpc и OTLP
- [ ] `void/grpc` *(M; ADR-0013)* — Connect protocol поверх void/http (unary, HTTP/1.1), JSON+protobuf кодеки, `defservice` из `.proto`; route metadata работает на RPC-методах так же, как на HTTP
- [ ] `void/obs` OTLP export (metrics + traces)

### 4.2 `void/ws` *(M)*

- [ ] RFC 6455: handshake, frames, ping/pong, close; per-connection fiber; channels/rooms, broadcast
- [ ] htmx ws-extension: hiccup-фрагменты по id
- [ ] Bench B4 (broadcast 1k conns) в CI

### 4.3 `void/mcp` *(S/M)*

- [ ] MCP server: JSON-RPC поверх stdio + HTTP/SSE
- [ ] Авто-экспозиция: CLI-команды → tools, схемы → resources, health/metrics → readable; allowlist, по умолчанию read-only

### 4.4 `void/admin` *(M/L — killer feature)*

- [ ] `defresource-admin`: schema + entity → CRUD (list с фильтрами/поиском/сортировкой/пагинацией, detail, формы) через html+htmx
- [ ] Widgets per schema-тип (point `:void.admin/widget`); relations/FK-виджеты из `:db/rels`
- [ ] Авторизация насквозь через authz: каждый action = policy, row-level scoping
- [ ] Audit log, custom actions (тяжёлые → jobs с прогрессом), points: `/page`, `/dashboard-widget`, `/menu`
- [ ] **MCP-проекция**: те же декларации → MCP tools/resources с теми же ABAC-политиками — в первый релиз админки

### 4.5 `void/cli` — добить artisan

- [ ] `void make resource User` (schema+routes+views+migration+tests), шаблоны переопределяемы проектом; интерактив через rawterm
- [ ] `void plugins lock` (lock-файл contributions — диффы окружений в CI)
- [ ] `jpm quickbin` single-binary deploy story + docs

### Exit-критерии волны 4

1. Demo: back-office с admin (row-level scoping по тенанту) + те же ресурсы доступны AI-агенту через MCP с теми же политиками.
2. Connect-RPC сервис вызывается grpcurl/buf-клиентом (transcoding совместимость).
3. B4 в CI. Тег v0.4, публичный README по позиционированию §9.

---

## Волна 5 — тяжёлый FFI и прочее

Вне критического пути; порядок по потребности.

- [ ] `void/kafka` *(L)* — ffi librdkafka (callbacks → ev channels), producer/consumer, point `:void.kafka/handlers`; kafka-backend для bus
- [ ] `void/db-mysql` *(M)* — ffi libmysqlclient, блокирующие вызовы → `ev/thread` pool
- [ ] `void/oauth` *(M)* — OAuth2/OIDC client
- [ ] `void/i18n` *(S)* — словари-данные, locale в dyn, интеграция со schema-ошибками и шаблонами
- [ ] `void/datastar` *(эксперимент)* — SSE + full-page morph (идиома Biff)
- [ ] `void/tls` *(low priority)* — ffi openssl/bearssl; до тех пор TLS = reverse proxy (ADR-0010)
- [ ] gRPC streaming через HTTP/2 *(XL — отдельное решение, новый ADR)*

---

## Сквозные работы (не привязаны к волне)

| Работа | Когда |
|---|---|
| CI: `jpm test` всех пакетов + `plugin/dry-run` + bench-пороги | с волны 0, наращивается |
| Docs-сайт: генерация из деклараций (metadata-ключи, extension points, схемы) | каркас в волне 1, публикация к v0.4 |
| Sampling-профайлер в void/dev (`debug/stack` по таймеру) + `bench/trace-request` | волна 2 (понадобится для B2/B3) |
| CONTRIBUTING: performance-правила §8.5, deprecation-процедура контрактов | к заморозке контрактов (v0.1) |
| Примеры-приложения (`examples/`) — по одному на волну, они же smoke-тесты | с волны 1 |

---

## Риски и как их гасим

| Риск | Вероятность/удар | Митигация |
|---|---|---|
| Свой HTTP-сервер дороже оценки L (backpressure, edge cases протокола) | средняя/высокий | ADR-0015: spork/http как донор парсеров; лимиты и drain — с первого дня; B0 в CI сразу |
| Заморозили route metadata / Plugin API рано и неудачно | средняя/высокий | Волна 1 обкатывает контракты на 5 plugins до заморозки; deprecation-механика (1.5) закладывается сразу |
| GC-паузы валят p99 на SSR-путях | средняя/средний | Бюджеты §8.2 в CI с волны 1; пулы буферов; prefork изолирует паузы |
| `void/fdwait` shim не обобщится (macOS kqueue vs epoll) | низкая/средний | Прототип проверен на Linux; kqueue-путь проверить в начале волны 2 на macOS (dev-платформа — darwin!) |
| Объём волны 3 (obs — «Spring-level это много») | высокая/средний | Резать по подфазам: logs→metrics→Prometheus обязательны, tracing/OTLP сдвигаемы в волну 4 |
| Один разработчик, длинный хвост plugins | высокая/— | Правило волн + копируемость компонентов: релизить рано, admin/mcp — магнит контрибьюторов |

---

## Definition of Done (для любого plugin)

1. Manifest проходит `plugin/dry-run`; удаление из `:plugins` не оставляет следов.
2. Config-schema + тесты на ошибочные конфиги; секреты не печатаются.
3. REPL-инспектируемость: `plugin/inspect` показывает все contributions.
4. Тесты: unit + интеграционный через `void/test`-fixtures; для middleware — строка в bench-таблице («B1 с моим middleware = −X%», §8.5).
5. Docs: README plugin'а + декларации metadata-ключей/extension points (авто-докгенерация).
6. Никаких блокирующих вызовов на ev loop (правило §8.5 п. 1).
