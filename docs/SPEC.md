# SPEC: void — batteries-included web framework на Janet

> Единый документ: обзорная спека (часть I), детальные контракты plugin API и route metadata (часть II), отчёт о прототипе async-PG (приложение A).

---

# Часть I. Обзорная спека
### Название: **void**

> Из канона Janet (*The Good Place*): бесконечная пустота Джанет, в которой хранится всё — «batteries included» как персонаж. Tagline: *«void — everything Janet keeps, one import away»*. Дисклеймер в README: не аффилированы с Void Linux; пакеты и модули живут под префиксом `void/`, поисковый контекст — «void janet framework».

Цель: Laravel/Spring-уровень возможностей, Lisp-идиоматичная архитектура, REPL-driven development как first-class режим. Всё расширяемо через plugins в духе Spring auto-configuration, но данные вместо аннотаций и classpath-скана.

---

## 1. Инвентарь возможностей Janet (что даёт платформа)

### Язык / VM (janet core)
| Возможность | Использование в FW |
|---|---|
| `ev/` — event loop, fibers, channels, `ev/go`, `ev/thread` | Вся конкурентность: HTTP server, jobs, timers. Fiber = единица запроса |
| `net/` — async TCP/UDP, unix sockets | HTTP server, Redis/PG/WS клиенты, netrepl |
| `dyn`/`setdyn` — dynamic bindings, **per-fiber** | Request context, trace context, current tenant/user, DB tx — без ThreadLocal-магии |
| PEG | Router, cron-выражения, RESP/wire протоколы, парсеры конфигов, валидация строк |
| Macros + full compile-time eval | Все DSL: routes, schema, policy, CLI; codegen из .proto |
| `ffi/` — native FFI (x86-64/aarch64) | librdkafka, libmysqlclient, опционально libpq/openssl |
| Env tables + `resolve` + late binding | Hot reload: route table хранит symbols, resolve в момент вызова |
| Threads с изолированными heaps + `ev/thread` | CPU-bound работа, prefork-модель для multi-core |
| `bundle/` + `jpm` | Дистрибуция plugins как обычных janet-пакетов |
| Embedding API (<1MB runtime) | Single-binary deploy через `jpm quickbin` |

### spork (official contrib) — готовые запчасти
| Модуль | Роль | Статус |
|---|---|---|
| `netrepl` | Networked REPL с remote debugger, repl into existing environments | **брать как есть** — сердце dev mode |
| `http`, `httpf` | HTTP/1.1 server+client; httpf — opinionated мини-framework | база для нашего server, изучить и форкнуть/обернуть |
| `schema` | Базовая валидация данных | точка старта для schema layer, расширять |
| `cron` | Парсинг cron-выражений | scheduler бесплатно |
| `tasker` | Task queue | база для jobs (in-process; persistence добавляем сами) |
| `htmlgen` | HTML из данных (hiccup-style) | view layer |
| `temple` | String templates (ERB-style) | альтернативный view layer |
| `rpc`, `msg` | RPC и length-prefixed messaging | внутренние протоколы, msg — фрейминг для WS/netrepl |
| `json` (native C) | JSON | сериализация |
| `argparse` | CLI parsing | artisan |
| `ev-utils`, `channel`, `stream` | Конкурентные утилиты | везде |
| `sh`, `path`, `zip`, `base64`, `crc`, `utf8`, `regex`, `getline`, `rawterm` | Утилиты | artisan UX (rawterm → интерактивные промпты) |
| `services` | Service management | изучить, возможно основа lifecycle |

### Сторонние bindings
- **SQLite** — janet-lang/sqlite3, стабильно
- **PostgreSQL** — bindings к libpq существуют (C), проверить и усыновить/форкнуть
- **Redis, MySQL, Kafka** — нет; см. plugins

### Ограничения платформы (принять как constraints)
1. Нет HTTP/2 → gRPC через Connect protocol (HTTP/1.1), streaming — v2
2. GC stop-the-world, простой → короткие request lifetimes, пулы буферов, prefork для multi-core
3. Threads не шарят heap → cross-thread только через `ev/thread` channels; system живёт в одном OS-thread, workers — отдельные
4. Нет TLS в stdlib → за TLS отвечает reverse proxy (deploy story) или ffi к openssl/bearssl (plugin `void/tls`, low priority)

---

## 2. Архитектурные принципы

1. **Data first.** Routes, schemas, policies, components, plugin manifests — данные (structs/tables), DSL-macros лишь сахар поверх. Всё инспектируется и генерируется в REPL.
2. **System map, а не глобальный контейнер.** Как Biff/Integrant: система = map компонентов; компонент — данные с функциями `start/stop/health`. Никаких скрытых синглтонов, кроме `dyn` для request-scoped значений.
3. **Late binding везде.** Handlers, jobs, policies регистрируются символами и резолвятся при вызове → изменение функции в REPL сразу живое, `system/restart` нужен только для stateful-компонентов.
4. **Plugins = пакеты + manifest.** Никакого classpath-скана: явный `(use-plugins [...])` в проекте, но внутри plugin — авто-регистрация всего (Spring-style auto-config: components, routes, CLI-команды, migrations, health checks, metrics).
5. **Ядро минимальное.** Core не знает про HTTP. HTTP — тоже plugin (первый и главный).
6. **Fail fast на старте.** Валидация: граф зависимостей, config по схемам, конфликты extension points, missing symbols в route table. Ошибка конфигурации не должна доживать до первого запроса.
7. **Копируемость (из Biff).** Компоненты пишутся так, чтобы их можно было скопировать в проект и изменить; интерфейсы (contract каждого extension point) стабильны, реализации — расходный материал.

---

## 3. Core (пакет `void/core`)

Единственная обязательная зависимость. Не тянет HTTP, DB, ничего.

### 3.1 Component system (`void/core/system`)
```janet
(defcomponent :db/pool
  :deps    [:config :metrics]
  :config  {:schema DbConfig :key :database}   # свой кусок конфига, провалидированный
  :start   (fn [deps cfg] ...)
  :stop    (fn [inst] ...)
  :health  (fn [inst] {:status :up})
  :suspend/:resume (fn [inst] ...))            # опционально, для hot reload
```
- Registry компонентов → topological sort → start в порядке зависимостей, stop в обратном.
- Валидация графа: cycles, missing deps, дубли ключей (с указанием, какие plugins конфликтуют).
- `(system/start)`, `(system/stop)`, `(system/restart :key)` — рестарт компонента и транзитивных зависимых (reloaded workflow).
- Scopes: `:singleton` (default), `:factory` (инстанс на запрос — редко, для явных случаев).
- Interfaces: компонент может декларировать `:provides :void/cache` — другие зависят от интерфейса, не от реализации (redis-cache и memory-cache оба `:provides :void/cache`; при двух активных реализациях без явного выбора в конфиге — ошибка старта).

### 3.2 Config (`void/core/config`)
- Слои: defaults плагинов ← файл(ы) `config/*.janet|jdn` ← env vars (`VOID_DB__HOST=...`) ← CLI overrides. Merge с отслеживанием происхождения каждого значения (`(config/explain :database :host)` → "env var VOID_DB__HOST").
- Профили: `:dev`/`:test`/`:prod` + произвольные.
- Каждый компонент декларирует schema своего куска → вся конфигурация провалидирована до старта, ошибки собираются пачкой.
- Secrets: значения-ссылки `{:secret "DB_PASSWORD"}` → резолв из env/file/vault-plugin; никогда не печатаются в логах/REPL (custom print).

### 3.3 Schema layer (`void/core/schema`)
Расширение spork/schema до Malli-уровня. Один формат → много проекций.
```janet
(defschema CreateUser
  {:email [:string {:format :email}]
   :age   [:int {:min 18}]
   :role  [:enum :admin :user]
   :tags  [:vector :keyword {:max 10}]})
```
- Композиция: `merge`, `select`, `optional`, `union`, рекурсивные схемы.
- Refinements произвольными предикатами + PEG-паттерны для строк.
- Coercion-режим (string→int для query params, forms).
- Человекочитаемые ошибки с path (`[:tags 3]`), локализуемые.
- **Проекции (each — отдельная функция, plugins добавляют свои):** validator, JSON Schema / OpenAPI components, protobuf descriptor, HTML form hints, generator для property-based тестов, docs.
- Registry схем по имени → OpenAPI `$ref`, переиспользование.
- **Опциональные db-аннотации** (`:db/table`, `:db/pk`, `:db/fk`, `:db/rel`, `:db/index`, `:db/type`) — не участвуют в валидации, но питают entity layer (§5.9), void/admin (relations, FK-виджеты) и migrations-diff. Schema без них — обычный DTO; с ними — entity. Один source of truth на всё.

### 3.4 Plugin API (`void/core/plugin`)
```janet
(defplugin void/redis
  :requires [void/core]
  :components [...]                 # defcomponent-ы
  :extends {:void/cli [...]           # extension points других plugins
            :void/health [...]
            :void/metrics [...]}
  :extension-points {:void.redis/codec {...}}  # свои точки расширения
  :config-schema RedisConfig
  :on-load (fn [ctx] ...))          # compile-time хук (codegen и т.п.)
```
- Extension point = именованный контракт: schema того, что регистрируют, + функция-«свёртка» (как plugin-host собирает вклады). Аналог Spring `@ConditionalOnClass`/auto-config, но явный и данный.
- Conditional activation: `:when (fn [config] ...)` — plugin/компонент активен по конфигу.
- `(plugin/inspect)` в REPL: кто что зарегистрировал, кто чей extension point заполнил.

### 3.5 Hooks/Events (`void/core/hooks`)
Синхронные упорядоченные хуки жизненного цикла (`:before-start`, `:after-start`, `:config-loaded`, ...) + внутрипроцессная pub/sub шина (`ev`-based) для application events. Не Kafka — именно in-process интеграционные события (audit plugin слушает `:user/created` и т.п.).

### 3.6 Lifecycle / entrypoint
`(void/run! {:plugins [...] :profile :prod})` — конфиг → граф → старт → сигналы (SIGTERM → graceful stop с таймаутом). Dev mode: то же + netrepl + file watcher.

---

## 4. Dev experience core (`void/dev` — plugin, но канонический)

- **netrepl** внутри процесса (unix socket в dev по умолчанию), repl into system environment: `system`, `(routes)`, `(plugin/inspect)`, `(config/explain ...)` под рукой.
- File watcher → `import` с reload затронутых env tables; для stateful — авто `system/restart` затронутых компонентов (карта file→component из manifests).
- REPL-хелперы: `(with-request {:method :get :uri "/x"} ...)` — прогнать запрос через полный middleware stack без сети; `(explain-route "/users/5")` — какой route, какие middleware, какая policy.
- Dev error page: stack trace fiber'а, request snapshot, ссылки file:line.
- `void/test`: fixtures как компоненты (поднять подмножество system), factories из schema-generator, snapshot testing для hiccup.

---

## 5. Plugins (каталог)

Формат: **что даёт / на чём стоит / что писать / сложность (S/M/L/XL)**.

### 5.1 `void/http` — HTTP kernel *(L)*
- Server поверх net/ev (изучить spork/http как базу; вероятно свой сервер: keep-alive, pipelining, лимиты, таймауты, graceful drain, chunked, SSE).
- Ring-model: request/response — plain tables; handler — функция; middleware — обёртки.
- **Router**: PEG-компиляция паттернов, route table как данные, symbols not closures. Route metadata — открытая map: другие plugins читают её (`:policy`, `:schema`, `:openapi`, `:rate-limit`, `:txn`).
- Content negotiation, static files (etag, range), cookies, multipart.
- Session (extension point `:void.http/session-store`; memory — тут, redis/db — в своих plugins).
- Error handling: exception→response mapping, extension point для рендереров ошибок.
- Extension points: middleware registration с приоритетами (числовые фазы как Spring `Ordered`), session stores, body codecs.

### 5.2 `void/rest` — REST/JSON API *(S — сахар над http)*
- `defresource`: request/response schemas на route → авто-валидация, coercion, сериализация; проблемы → RFC 7807 problem+json.
- Pagination/sorting/filtering conventions, versioning helpers.

### 5.3 `void/openapi` *(S)*
- Чистая проекция route table + schema registry → OpenAPI 3.1 JSON.
- Swagger UI route в dev. CLI: `void openapi export`.

### 5.4 `void/html` — SSR *(M)*
- htmlgen/hiccup pipeline: layouts, partials, компоненты как функции.
- Form helpers из schema (поля, ошибки, значения, CSRF автоматически).
- Asset pipeline: fingerprinting, manifest; в dev — passthrough.
- temple как альтернативный движок (extension point `:void.html/engine`).

### 5.5 `void/htmx` *(S)*
- Хелперы hx-атрибутов, партиальный рендеринг (запрос с `HX-Request` → фрагмент без layout), OOB swaps, `HX-Trigger` response headers.
- Изучить Datastar-режим Biff (SSE + full-page morph) как альтернативную идиому — отдельный экспериментальный plugin `void/datastar`.

### 5.6 `void/ws` — WebSocket *(M)*
- RFC 6455 поверх net/: handshake, frames, ping/pong, close; per-connection fiber + spork/msg-style роутинг.
- Channels/rooms abstraction, broadcast.
- htmx ws-extension интеграция: шлём hiccup-фрагменты, htmx свапает по id.

### 5.7 `void/proto` — protobuf runtime *(M)*
- Pure-Janet кодек: varint, wire types, encode/decode по descriptor.
- `.proto` parser (PEG) → schema-layer описания → codegen macros.
- Общий фундамент для grpc и otel — писать первым из этой ветки.

### 5.8 `void/grpc` — Connect-RPC *(M, после proto)*
- Connect protocol поверх void/http (unary, HTTP/1.1): совместимость с gRPC-экосистемой через transcoding; JSON и protobuf кодеки.
- `defservice` из .proto → handlers c schema-валидацией.
- v2: streaming через HTTP/2 (XL, отдельное решение).

### 5.9 `void/db` — database kernel *(M)*
- Интерфейс `:void/db-driver` (connect, query, tx, prepared, pool contract).
- Пул соединений (fiber-aware: чекаут — в dyn, авто-возврат).
- Query builder honeysql-style: SQL как данные, диалекты через драйвер.
- Транзакции: `(db/with-tx ...)` — dyn-scoped; декларативно через route metadata `:txn true`.
- Migrations: janet-файлы up/down, таблица версий, `void db migrate/rollback/status`; генерация из diff entity-registry — v2.
- Инструментация: query timing → metrics/tracing автоматически (обёртка драйвера).

**Entity layer: Data Mapper + лёгкий AR** *(часть void/db)*

Ядро — Data Mapper: mappers генерируются из entity-деклараций, entities — plain data. AR — тонкий слой удобств поверх, реализованный через **table prototypes** Janet: инстанс остаётся обычной table, но его proto несёт ссылку на entity descriptor и snapshot загруженного состояния. Никаких классов, полная инспектируемость, `pp` работает.

```janet
(defentity User                       # это defschema + db-mapping в одном
  {:id       [:uuid {:db/pk true}]
   :email    [:string {:format :email :db/unique true}]
   :brand-id [:uuid {:db/fk :Brand}]
   :balance  [:money {:db/type "numeric(18,2)"}]}
  :db/table "users"
  :db/rels  {:brand [:belongs-to :Brand :brand-id]
             :bets  [:has-many :Bet :user-id]})

(def CreateUser (schema/select User [:email :brand-id]))   # DTO — проекция entity
```

Repository API (Data Mapper, всегда доступен, работает с plain data):
```janet
(db/find User id)                     # -> entity-table (proto → descriptor+snapshot)
(db/query User {:where [:= :brand-id b] :order [:created-at :desc] :limit 50
                :preload [:brand]})   # явный preload — batched IN-запрос
(db/insert! User attrs) (db/update! User id patch) (db/delete! User id)
```

Лёгкий AR поверх (сахар, резолвится через proto):
```janet
(def u (db/find User id))
(-> u (put :email "x@y.z") (db/save!))   # save! диффит против snapshot из proto
                                          # → partial UPDATE только изменённых колонок
(db/rel u :brand)                         # навигация по relation
```

Принципиальные решения:
- **N+1 запрещён по умолчанию**: `(db/rel ...)` вне `:preload` в dev кидает warning с местом вызова, в `:strict` — ошибку. Ленивой магии в циклах нет; нужны связи — декларируй `:preload`.
- **Dirty tracking без мутационной магии**: snapshot в proto + diff на `save!`. Обновления — обычные `put`/`merge`; optimistic locking через `:db/version`-колонку опционально.
- Identity map — опционально, per-request через dyn (`db/with-identity-map`), выключен по умолчанию.
- Никакого Unit of Work: границы — явные `(db/with-tx ...)`; `save!`/`insert!` внутри участвуют в текущей транзакции из dyn.
- Callbacks/lifecycle-hooks на entity — НЕТ (главный источник боли AR); сквозные вещи (audit, domain events) — через `void/bus` outbox и db-middleware.
- `:db/rels` + `:db/fk` — единый источник для: preload-планировщика, admin relations/виджетов, migrations-diff, ER-диаграммы (`void db erd`).

### 5.10 Драйверы
| Plugin | Путь | Сложность |
|---|---|---|
| `void/db-sqlite` | обернуть janet sqlite3 | S |
| `void/db-postgres` | усыновить/форкнуть libpq bindings; async-режим libpq для ev-совместимости (не блокировать loop!) — важная работа | M |
| `void/db-mysql` | ffi/ к libmysqlclient; блокирующие вызовы → `ev/thread` pool | M |
| `void/redis` | RESP2/3 на чистом Janet (PEG), pipelining, pub/sub (fiber), `:provides :void/cache :void/session-store :void/queue-backend` | M |
| `void/kafka` | ffi/ к librdkafka (callbacks → ev channels), producer/consumer компоненты, consumer = extension point `:void.kafka/handlers` | L |

### 5.11 `void/cache` *(S)* — интерфейс + memory impl (TTL, LRU); декоратор `(cache/wrap f ...)`; backends: redis.

### 5.12 `void/jobs` — background jobs, BullMQ-паритет *(M/L)*
- Поверх spork/tasker (executor) + persistence через `:void.jobs/backend` (db — polling+SKIP LOCKED; redis — BRPOPLPUSH/streams).
- `defjob` (symbol-based → hot reload), retries с backoff+jitter, приоритеты, delayed, unique jobs, dead letter queue.
- **Flows**: parent-child DAG (job стартует после завершения детей), как BullMQ Flows — данные детей доступны родителю.
- **Rate limiting** per queue (`{:max 100 :duration 60}`) и concurrency per worker; group-ключи для fair scheduling между тенантами.
- Repeatable jobs: spork/cron; `defschedule`; drift-контроль и single-instance гарантия через backend-lock.
- Lifecycle events (`:completed`, `:failed`, `:stalled`) публикуются в `void/bus` при его наличии.
- Dashboard (plugin `void/jobs-ui`, hiccup+htmx — dogfooding): очереди, retry/promote/remove, графики из void/obs.

### 5.13 `void/obs` — observability *(L, Spring-level это много)*
- **Logs**: structured (JDN/JSON), контекст из dyn (request id, trace id) автоматически; уровни per-namespace, смена в рантайме/REPL.
- **Metrics**: counters/gauges/histograms; RED на каждый route из route table; runtime-метрики (GC — `gccollect` stats, fibers, pools). Экспорт: Prometheus text (S) + OTLP (после void/proto).
- **Tracing**: span API, контекст в dyn (per-fiber — изоляция бесплатно), W3C traceparent propagation (in/out), OTLP export.
- Auto-instrumentation через component-декораторы: db, redis, http-client, jobs, kafka — каждый плагин регистрирует свою в `:void.obs/instrumentations`.
- `/health`, `/ready` из `:health` компонентов; `/metrics`.

### 5.14 `void/auth` — authentication *(M)*
- Identity abstraction, стратегии как extension point: session+password (argon2 через ffi или scrypt), magic link / OTP (идея Biff), API tokens, JWT (нужен HMAC/RSA — jhydro или ffi openssl), OAuth2/OIDC client — отдельный plugin `void/oauth` (M).
- `current-user` в dyn; middleware; route metadata `:auth :required`.

### 5.15 `void/authz` — ABAC *(M)*
- Policy as data: subject/action/resource/environment; `defpolicy` — чистые функции над атрибутами.
- Attribute providers — компоненты (`:void.authz/providers`): из identity, из БД, из request.
- Enforcement: middleware по route metadata `:policy`, + явный `(authz/can? subject action resource)` для использования в коде/шаблонах.
- Decision log (в audit), `explain`-режим в REPL: почему deny.
- RBAC — вырожденный случай ABAC, sugar поверх.

### 5.16 `void/security` *(S/M)*
- CSRF: session token, hiccup form auto-inject, htmx meta+hx-headers; double-submit для API.
- Security headers (CSP builder), rate limiting (стратегии; backend memory/redis), CORS.

### 5.17 `void/cli` — artisan *(M)*
- Бинарь `void`: команды — extension point `:void/cli`, любой plugin добавляет свои (`void db migrate`, `void jobs work`, `void routes`, `void openapi export`).
- Bootstrap подмножества system по требованию команды (`:needs [:db/pool]`).
- Codegen/scaffold: `void new`, `void make resource User` (schema+routes+views+migration+tests) — шаблоны как данные, переопределяемые проектом.
- Интерактив через rawterm/getline; `void repl` → netrepl client в запущенный процесс.

### 5.18 `void/mcp` *(S/M)*
- MCP server: JSON-RPC поверх stdio + HTTP/SSE transport (оба на готовых кусках).
- Авто-экспозиция: CLI-команды как tools, schema-ресурсы как resources, health/metrics как readable. Allowlist в конфиге — по умолчанию только read-only.
- Это killer-фича: «админка из коробки — это AI-агент».

### 5.19 `void/mail` *(S)* — SMTP client (протокол простой), templates через void/html, отправка через void/jobs. Нужен для void/auth (magic link).

### 5.20 `void/i18n` *(S)* — словари как данные, locale в dyn, интеграция с schema-ошибками и шаблонами.

### 5.21 `void/admin` — бесплатная админка *(M/L, killer feature)*
Django-admin/Filament-класс, но данные-first: админка — **ещё одна проекция schema layer**, как OpenAPI.
- `defresource-admin`: schema + db-таблица (+FK metadata) → CRUD из коробки: list с фильтрами/поиском/сортировкой/пагинацией, detail, формы create/edit с валидацией и ошибками — всё рендерится через void/html+htmx (dogfooding).
- Widgets per schema-тип — extension point `:void.admin/widget` (свой рендер для :money, :json, relation-picker по FK); relations и inline-редактирование берутся из `:db/rels`/`:db/fk` entity layer (§5.9) — ниоткуда больше.
- **Авторизация насквозь через void/authz**: каждый action = policy, row-level scoping через attribute providers (админ видит только свой бренд/тенант — критично для back-office мультибрендовых платформ).
- Audit log встроен: hooks на каждую запись, страница истории по entity.
- Custom actions (row/bulk) — функции; тяжёлые уходят в void/jobs с прогрессом в UI.
- Extension points: `:void.admin/page` (произвольные страницы), `:void.admin/dashboard-widget`, `:void.admin/menu`.
- **MCP-синергия**: те же resource-декларации автоматически экспонируются как MCP tools/resources (с теми же ABAC-политиками) → одна декларация даёт админку для людей и для агентов.
- Волна 3–4: требует html/htmx/db/auth/authz.

### 5.22 `void/bus` — messaging/streams в духе Watermill *(M)*
Отдельно от jobs: jobs = task-queue семантика (сделай и подтверди), bus = messaging (pub/sub, fan-out, at-least-once, стримы).
- Message = plain table `{:id :payload :meta}`; payload (de)serialization через schema layer (`:void.bus/codec`: JSON, protobuf из void/proto).
- **Router**: `defhandler` подписывает функцию на topic; middleware-цепочка на сообщениях с теми же фазовыми константами: retry+backoff, poison queue, dedup по id, correlation-id, throttle, tracing (context propagation через dyn — trace продолжается из HTTP-запроса в consumer).
- **Backends** — extension point `:void.bus/backend`: `:memory` (ev/chan, для тестов и монолита), `:pg` (LISTEN/NOTIFY + таблица), `:redis` (streams, consumer groups), `:kafka` (через void/kafka). Гарантии декларируются backend'ом (`:at-most-once`/`:at-least-once`), router их учитывает.
- **Transactional outbox** — first-class: `(bus/publish-tx tx topic msg)` пишет событие в ту же транзакцию через void/db; forwarder-компонент публикует и помечает. Для консистентности денег/ставок — единственно верный паттерн.
- **CQRS-слой** (опционально, как в Watermill): command bus (ровно один handler, ответ), event bus (fan-out); `defcommand-handler`/`defevent-handler` с schema на входе.
- Волна 3 для core+memory+pg, kafka-backend — волна 5.

---

## 6. Сводный граф работ и волны

**Волна 0 — фундамент:** core/system → core/config → core/schema → core/plugin → void/dev (netrepl-интеграция сразу, чтобы всю остальную разработку вести в REPL — dogfooding с первого дня).

**Волна 1 — вертикальный slice:** void/http → void/html + void/htmx → void/rest → void/openapi → void/cli (минимум: new/routes/repl). *Результат: можно строить HTMX-приложения, есть что показать.*

**Волна 2 — данные:** void/db → db-sqlite → db-postgres → void/redis → void/cache → void/jobs (+cron). *Результат: продуктовый минимум, Laravel-паритет по ядру.*

**Волна 3 — enterprise:** void/obs (logs→metrics→Prometheus) → void/auth → void/authz → void/security → void/mail → void/bus (core + memory/pg backends, outbox).

**Волна 4 — протоколы и админка:** void/proto → void/grpc (Connect) → void/obs OTLP export → void/ws → void/mcp → **void/admin** (после authz+htmx+mcp — чтобы MCP-проекция вошла в первый релиз админки).

**Волна 5 — тяжёлый FFI и прочее:** void/kafka (+kafka-backend для void/bus) → void/db-mysql → void/oauth → void/i18n → void/datastar (экспериментально) → TLS-plugin (по необходимости).

Правило зависимостей волн: каждый plugin зависит только от core и plugins ≤ своей волны.

---

## 7. Открытые вопросы (решить до волны 1)

1. **spork/http: обернуть или переписать?** Прочитать исходники; критерии — keep-alive, backpressure, лимиты, graceful drain. Скорее всего свой сервер, spork/http как референс.
2. **Async libpq**: PQsendQuery/PQconsumeInput + `ev`-интеграция сокета libpq — проверить осуществимость раньше, чем закладываться (fallback: `ev/thread` pool, дороже).
3. **Формат route metadata** — публичный контракт между половиной плагинов; спроектировать и заморозить рано.
4. **Naming/бренд** + организация на GitHub, монорепо со scoped-пакетами.
5. **Версионирование protocol'а plugin API**: manifest несёт `:void-api 1` — совместимость проверяется на старте.


## 8. Перформанс: модель, бюджеты, методика измерения

### 8.1 Честная модель производительности

Janet — bytecode-интерпретатор **без JIT**. По CPU-скорости это класс CPython/Ruby (обычно быстрее CPython в 1.5–3× на интерпретаторных бенчах, но на порядок медленнее Go/JVM). Выводы для дизайна:

- Наш профиль — **I/O-bound**: ev loop + неблокирующие драйверы. Конкурентность и tail latency решаются архитектурой, throughput на CPU-тяжёлых путях — нет.
- **Hot paths уходят в C**: HTTP-парсер, JSON (spork/json — native C), protobuf varint-ядро, PEG (C-движок) — интерпретатор должен исполнять только «склейку». Правило: на happy path запроса < ~50 janet-функций между accept и write.
- **GC stop-the-world**, простой mark-and-sweep. Аллокации на запрос — главный враг p99: переиспользуем буферы, `buffer/clear` вместо новых, `keep-syntax` для compile-time構造. `gcsetinterval` — ручка trade-off throughput/pause.
- **Multi-core = prefork**: N процессов × SO_REUSEPORT (Linux раздаёт accept сам), никакого shared state между воркерами кроме БД/Redis. Это же — изоляция GC-пауз: пауза одного воркера не трогает остальных. `void/http` должен уметь `:workers :auto` из коробки.
- **Не наш кейс**: 30k+ RPS в одном процессе. Реалистичная цель — тысячи RPS на воркер на I/O-путях, десятки тысяч на машину префорком; выше — ставь Go/Rust или CDN/proxy перед нами (static и так должен уходить в nginx/Cloudflare).

### 8.2 Бюджеты (SLO фреймворка, проверяются в CI)

Все цифры — **гипотезы до первого прогона bench-suite**, дальше фиксируются как regression-пороги (допустимая деградация между коммитами: 5%).

| Бенчмарк (1 воркер, 1 vCPU) | Бюджет p50 | Бюджет p99 | Throughput floor |
|---|---|---|---|
| B0 plaintext hello (router+middleware stack) | < 0.5 ms | < 3 ms | ≥ 20k RPS |
| B1 JSON echo 1KB (parse+validate+serialize) | < 1 ms | < 5 ms | ≥ 8k RPS |
| B2 PG single query (pool, prepared) | < 3 ms | < 12 ms | ≥ 3k RPS |
| B3 PG + hiccup SSR ~15KB | < 5 ms | < 20 ms | ≥ 1.5k RPS |
| B4 WebSocket broadcast 1k conns | — | доставка < 50 ms | 10k msg/s |

Не-latency бюджеты:
- **Startup до ready** (полный граф компонентов): < 150 ms — это фича для serverless/CLI и dev-цикла.
- **RSS**: hello-app < 30 MB, «полный фарш» (db+redis+jobs+obs) < 80 MB на воркер.
- **GC**: max pause < 10 ms на B3-профиле; суммарно < 2% времени.
- **ev loop lag** (см. 8.4): p99 < 1 ms под целевой нагрузкой — главный health-индикатор ev-системы.
- **Overhead инструментации**: void/obs включён vs выключен ≤ 7% throughput.

### 8.3 Bench-suite (`void bench`) — часть репозитория, не afterthought

- Каждый B0–B4 — мини-приложение в `bench/apps/`, поднимается одной командой; генератор нагрузки в контейнере рядом.
- **Инструменты**: `wrk2` (обязательно wrk2, не wrk — coordinated omission при фиксированном rate) для latency под заданным RPS; `wrk` для max throughput; `k6` для сценарных (login → CRUD → logout); собственный janet-клиент для WS.
- Методика прогона: warmup 30s (прогрев кэшей route table/prepared statements) → 3×60s → медиана прогонов; фиксировать: версию janet, CPU, губернатор частоты; в CI — dedicated runner или хотя бы относительные пороги против baseline-коммита на том же раннере.
- **Контекстные baselines** в том же суите: FastAPI+uvicorn (Python-класс), Go net/http (потолок), Joy (предшественник). Не для маркетинга — для калибровки «мы в ожидаемом классе или что-то сломали».
- Профилирование двухэтажное: C-этаж — `perf record` по janet-процессу (видно GC, PEG, json.c); janet-этаж — своего профайлера нет, поэтому void/dev даёт sampling-профайлер на `debug/stack` по таймеру (грубый, но флеймграф «какие janet-функции горячие» даёт) + `(bench/trace-request ...)` — микротайминги по фазам middleware из коробки.

### 8.4 Что мерить в production (void/obs, из коробки)

- **ev/loop-lag** — периодический fiber: `(ev/sleep 0.1)`, дельта факт-vs-ожидание = гистограмма. Это главный сигнал «кто-то заблокировал loop» (синхронный FFI-вызов, CPU-loop). Алерт p99 > 10 ms.
- GC: паузы (обёртка вокруг gccollect-статистики), rate аллокаций.
- RED per route (из route metadata, автоматически) + pool-метрики db/redis (wait time на чекаут — ранний сигнал недосайза пула).
- p99 «времени в очереди»: accept→начало handler.
- Startup time и время каждой фазы bootstrap в логе — деградация конфиг-фазы тоже регрессия.

### 8.5 Performance-правила для авторов plugins (в CONTRIBUTING)

1. Никаких синхронных syscalls/FFI на loop — всё блокирующее в `ev/thread` явно.
2. Аллокации на hot path — бюджетируются; переиспользуемые буферы в компоненте, не на запрос.
3. Всё, что можно посчитать на build-этапе (compile route chain, merge metadata, compile schema validators) — считается там; hot path только исполняет готовое.
4. Каждый plugin с middleware обязан иметь строчку в bench-таблице: «B1 с моим middleware = -X%».


## 9. Позиционирование (для README и трезвости)

**Ниша, где сочетание уникально:** single binary < 5 MB, RSS < 50 MB, live REPL в production-процесс, batteries included (db/jobs/auth/obs/MCP). Spring — гигабайт JVM; Rails/Laravel — интерпретатор + зависимости; Go — быстрый, но без batteries и REPL; redbean — близок по духу, но без экосистемы.

**Сладкая зона:** server-rendered HTMX-приложения малой/средней сложности, где стоимость деплоя и владения важнее пиковой производительности — internal tools и админки, solo/indie SaaS на VPS, webhook/бот-хабы, embedded web UI (Janet встраивается в C-хосты), edge/дешёвое железо.

**Анти-кейсы (говорим честно в README):** команды 5+ разработчиков (hiring), >10k RPS на процесс (см. §8: prefork или другой язык), CPU-heavy обработка, домены с обязательными толстыми vendor SDK.

**Метрика успеха проекта** — не adoption, a: (1) время «идея → работающий деплой» для одного разработчика, (2) полнота вертикали без выхода за пределы стека, (3) стабильность контрактов части II.

---

# Часть II. Детальные контракты: Plugin API + Route Metadata
Два контракта, которые сложнее всего менять после релиза. Всё — данные; macros только сахар.

---

## Часть 1. Plugin API

### 1.1 Модель

Plugin = обычный janet-пакет, экспортирующий **manifest** (struct). Никакого classpath-скана: проект явно перечисляет plugins, но внутри plugin всё авто-регистрируется — Spring auto-configuration, только явная и инспектируемая.

```janet
# void-redis/init.janet
(use void/core)

(defplugin void/redis
  :void-api 1                          # версия protocol'а plugin API
  :version "0.3.0"
  :requires {void/core ">=0.1" void/http ">=0.1 <0.5"}   # опц. — только если нужен http
  :config-key :redis
  :config-schema RedisConfig
  :when (fn [cfg] (get-in cfg [:redis :enabled] true))   # условная активация
  :components [redis-pool-component redis-pubsub-component]
  :contributes                        # вклады в чужие extension points
    {:void.core/cli        [redis-cli-cmd]
     :void.core/health     [redis-health]
     :void.obs/instrument  [redis-instrumentation]
     :void.http/session-store [redis-session-store]}
  :extension-points                   # СВОИ точки расширения
    {:void.redis/codec redis-codec-point}
  :on-load (fn [ctx] ...))            # хук времени загрузки (codegen); опц.
```

`defplugin` разворачивается в `(def plugin-manifest {...})` + регистрацию в module-level registry при `use-plugins`. Manifest — замороженный struct: его можно `pp`, diff-ить, сериализовать.

### 1.2 Bootstrap проекта

```janet
(void/run!
  {:plugins [void/http void/rest void/db void/db-postgres void/redis my-app/module]
   :profile (keyword (or (os/getenv "VOID_PROFILE") "dev"))})
```

Порядок фаз (все — до открытия портов, любая ошибка = не стартуем):

1. **load** — require пакетов, сбор manifests, проверка `:void-api` совместимости и `:requires` (semver).
2. **config** — merge слоёв (plugin defaults ← files ← env ← cli), валидация каждого `:config-key` по `:config-schema`. Ошибки собираются ПАЧКОЙ по всем plugins, не first-fail.
3. **conditional** — вычисление `:when` → множество активных plugins. Неактивный plugin не вносит ни components, ни contributions.
4. **extension resolution** — см. 1.4: проверка контрактов, сортировка, редукция.
5. **graph** — сборка component graph: deps, `:provides`-интерфейсы, cycles, дубли. Topological sort.
6. **start** — старт компонентов по порядку; `:health` компонентов агрегируется.
7. **ready** — hooks `:after-start`, открытие listeners.

Shutdown — обратный порядок, с таймаутом на компонент.

### 1.3 Components (напоминание контракта)

```janet
(defcomponent :redis/pool
  :deps [:void/config]
  :provides [:void/cache :void/kv]        # интерфейсы
  :start (fn [deps] ...)              # deps — map уже стартованных зависимостей
  :stop  (fn [inst] ...)
  :health (fn [inst] {:status :up :latency-ms 1})
  :suspend (fn [inst] ...) :resume (fn [inst] ...))  # опц., для system/restart соседей
```

Правила `:provides`:
- зависеть можно от ключа (`:redis/pool`) ИЛИ от интерфейса (`:void/cache`);
- если интерфейс предоставляют >1 активных компонентов и никто не выбран в config (`{:void/cache {:impl :redis/pool}}`) → **ошибка старта** с перечислением кандидатов и каких plugins они;
- интерфейс — тоже контракт: объявляется через extension point `:void.core/interface` со schema методов (см. ниже), реализация валидируется по ней.

### 1.4 Extension points — сердце системы

Extension point = именованный контракт + стратегия свёртки вкладов.

```janet
(defextension-point :void.http/middleware
  :doc "HTTP middleware registered by plugins"
  :schema {:name    :keyword
           :phase   [:int {:min 0 :max 10000}]   # см. фазы ниже
           :wrap    :function                     # (wrap handler) -> handler
           :when    [:optional :function]}        # per-route предикат по metadata
  :cardinality :many                              # :many | :single | :single-required
  :reduce (fn [contribs]                          # как host собирает вклады
            (sort-by |(in $ :phase) contribs))
  :validate (fn [contribs] ...))                  # опц. кросс-проверки (конфликты имён)
```

Вклад (contribution):

```janet
(defcontribution :void.http/middleware
  {:name :redis-session :phase 3000 :wrap wrap-redis-session})
```

Семантика, которую host гарантирует на фазе 4:
- каждый вклад валидируется по `:schema` точки; ошибка указывает plugin-источник;
- `:cardinality :single` + 2 вклада → ошибка с перечислением; `:single-required` + 0 → ошибка;
- `:reduce` вызывается один раз со всеми вкладами активных plugins; результат кладётся в registry, владелец точки читает его в `:start` своего компонента;
- вклад в **несуществующую** точку → ошибка («plugin void/redis contributes to unknown :void.htp/middleware — did you mean :void.http/middleware?»);
- точка без владельца-plugin в активном множестве, но с вкладами → ошибка (вклады повисли).

Это даёт Spring-плагинистость без Spring-магии: любой отчёт `(plugin/inspect)` показывает полную картину «кто-куда-что».

### Стандартные фазы middleware (константы, как Spring Ordered)

```
 0    :phase/panic-guard      (ловим всё)
 1000 :phase/observability    (trace root span, request-id, access log)
 2000 :phase/parsing          (body, content negotiation)
 3000 :phase/session
 4000 :phase/auth
 5000 :phase/authz
 6000 :phase/validation       (schema из route metadata)
 7000 :phase/business         (user middleware default)
 9000 :phase/response         (compression, security headers)
```
Между константами можно вставаться (3500). Тай-брейк при равной фазе — по имени plugin (детерминизм).

### Базовые точки ядра (владелец void/core)

| Точка | Cardinality | Что регистрируют |
|---|---|---|
| `:void.core/cli` | many | команды CLI `{:name :run :needs [:db/pool] :fn ...}` |
| `:void.core/health` | many | доп. health-checks сверх компонентных |
| `:void.core/config-source` | many | источники конфига (vault, consul) с приоритетом |
| `:void.core/schema-type` | many | кастомные типы schema layer (`:money`, `:uuid`) |
| `:void.core/schema-projection` | many | проекции schema (openapi, proto, forms) |
| `:void.core/interface` | many | декларации интерфейсов для `:provides` |
| `:void.core/hooks` | many | lifecycle hooks с фазой |

void/http добавляет `:void.http/middleware`, `:void.http/session-store`, `:void.http/body-codec`, `:void.http/error-renderer`, `:void.http/route-source` (модули приложения отдают routes тоже через точку!). void/obs — `:void.obs/instrument`, `:void.obs/exporter`. И т.д.

### 1.5 Версионирование и эволюция

- `:void-api` в manifest: host отклоняет plugin с несовместимой мажорной версией protocol'а. Инкремент — только при breaking-изменении семантики manifest/extension механики.
- Контракт КАЖДОЙ extension point версионируется её `:schema`: расширение — добавление `:optional` полей; переименование/ужесточение = новая точка (`:void.http/middleware2`) + deprecation период, host умеет алиасить.
- Manifests сериализуемы → `void plugins lock` пишет lock-файл (plugin, version, contributions hash) — диффы окружений и «почему в проде другой middleware-стек» ловятся в CI.

### 1.6 REPL-инструменты (обязательная часть контракта)

```janet
(plugin/inspect)                 # таблица: plugin → active? → components → contributions
(plugin/inspect :void.http/middleware)  # свёрнутый результат точки + источники
(plugin/why :redis/pool)         # почему компонент в графе, кто от него зависит
(plugin/dry-run {:plugins [...] :profile :prod})  # фазы 1-5 без старта — для CI
```

`plugin/dry-run` — то, что делает всю затею честной: полная валидация конфигурации системы за миллисекунды в тесте.

---

## Часть 2. Route Metadata

### 2.1 Зачем и что это

Route metadata — открытая map на каждом route; **главный интеграционный контракт** между plugins: authz, validation, OpenAPI, rate limit, txn, cache цепляются к route, не зная друг о друге. Аналог: аннотации Spring MVC, но данные и инспектируемые.

```janet
(GET "/orders/:id" order-handler
  {:name       :orders/show
   :void.schema/params   {:id :uuid}
   :void.schema/response {200 OrderView 404 Problem}
   :void.authz/policy    :orders/read
   :void.obs/name        "orders.show"
   :void.http/timeout    5.0
   :void.openapi/tags    [:orders]})
```

### 2.2 Структура route entry (внутреннее представление)

```janet
{:name     :orders/show          # уникальный keyword; ОБЯЗАТЕЛЕН
 :method   :get                  # :get :post ... :any
 :pattern  "/orders/:id"         # исходник
 :peg      <compiled>            # PEG matcher (derived)
 :params   [:id]                 # порядок capture (derived)
 :handler  'my-app.orders/show   # SYMBOL, не функция (late binding / hot reload)
 :meta     {...}                 # всё namespaced-остальное
 :source   {:plugin my-app/module :file "..." :line 42}}  # derived, для ошибок
```

Правила:
- `:handler` — символ; resolve в момент dispatch через кэш с инвалидацией по env-generation. Function-literal допустим (тесты), но помечается `:no-reload`.
- `:name` обязателен и уникален глобально → reverse routing `(url-for :orders/show {:id x})`, метрики, `explain-route`.
- Route table — immutable значение; пересборка атомарна (var swap) → нет полусобранного роутинга при reload.

### 2.3 Namespace-дисциплина ключей metadata

- Все ключи, кроме `:name`, — **namespaced**: `:void.<plugin>/<key>` для фреймворка, `:app/<key>`, `:acme.billing/<key>` для приложений. Голые ключи (кроме `:name`) → warning в dev, error в CI-режиме.
- Каждый plugin **декларирует свои ключи** через extension point `:void.http/route-meta-key`:

```janet
(defcontribution :void.http/route-meta-key
  {:key :void.authz/policy
   :schema [:or :keyword [:vector :keyword]]
   :doc "Policy (or all-of vector) enforced before handler"
   :merge :replace})     # :replace | :deep-merge | :concat | :restrict
```

Следствия:
- ключ с опечаткой (`:void.autz/policy`) → **ошибка старта** с did-you-mean;
- значение валидируется по schema ключа — на старте, не на запросе;
- вся документация metadata генерируется из деклараций (`void routes --keys`).

### 2.4 Merge-семантика (route ← group ← global)

```janet
(routes
  {:void.obs/sample-rate 0.1}                 # глобальный слой
  (group "/admin" {:void.authz/policy :admin :void.http/middleware [:audit]}
    (GET "/users" list-users {:void.authz/policy [:admin :users/read]})))
```

Порядок: global → group (вложенные группы по порядку) → route; на каждом шаге применяется `:merge`-стратегия ключа:
- `:replace` (default) — побеждает более специфичный слой;
- `:concat` — списки конкатенируются (middleware групп + route);
- `:deep-merge` — maps сливаются поглубже (schema заголовков);
- `:restrict` — специфичный слой может только УЖЕСТОЧАТЬ (rate limit, timeout: route не может поднять лимит выше группового). Нарушение → ошибка старта.

`:restrict` — важный для security ключей: `(explain-route "/admin/users")` печатает итог и происхождение каждого значения по слоям (как `config/explain`).

### 2.5 Reserved-ключи ядра (v1, замораживаем)

| Ключ | Тип | Merge | Читает |
|---|---|---|---|
| `:name` | keyword | — | все |
| `:void.http/middleware` | vector of keyword | concat | http kernel (выбор именованных middleware поверх фазовых) |
| `:void.http/timeout` | number (s) | restrict(min) | http kernel |
| `:void.http/max-body` | int (bytes) | restrict(min) | http kernel |
| `:void.schema/params` `/query` `/body` `/headers` | schema | deep-merge | void/rest validation mw |
| `:void.schema/response` | {status schema} | deep-merge | void/rest, void/openapi |
| `:void.authz/policy` | kw / [kw] | replace* | void/authz mw (*group policy И route policy обе enforce'ятся — это concat по смыслу: `[:admin :users/read]`) |
| `:void.auth/access` | :public/:required | restrict | void/auth |
| `:void.security/csrf` | bool | restrict(true wins) | void/security |
| `:void.security/rate` | {:limit :window} | restrict(min) | void/security |
| `:void.db/txn` | bool / {:isolation ...} | replace | void/db mw |
| `:void.obs/name` | string | replace | void/obs (метрики/спаны; default из `:name`) |
| `:void.obs/sample-rate` | 0..1 | replace | void/obs |
| `:void.cache/response` | {:ttl :vary} | replace | void/cache mw |
| `:void.openapi/*` (tags, summary, hidden) | — | replace | void/openapi |
| `:void.htmx/partial` | bool | replace | void/htmx (фрагмент без layout при HX-Request) |

Non-HTTP протоколы переиспользуют тот же механизм: gRPC-сервисы и Kafka-handlers несут ту же meta-map (`:void.authz/policy` работает на Connect-RPC методе так же, как на HTTP route) — поэтому контракт живёт в void/core (`void/core/meta`), а void/http лишь один из потребителей.

### 2.6 Runtime-доступ

Middleware получает metadata в request: `(request :void/route)` → route entry. Значение после merge прекомпилировано на построении таблицы (никаких merge на hot path). Для `:when`-предикатов middleware (см. 1.4) вход — тоже готовая meta: middleware со `:when` вообще не входит в цепочку route, если предикат false, — цепочка на route собирается один раз при билде таблицы.

### 2.7 Что НЕ является metadata

- Конфигурация plugin'ов (глобальные настройки session, размер пула) — это config.
- Данные запроса — это request map.
- Поведение handler'а — это handler.
Metadata отвечает ровно на вопрос «какие сквозные политики применимы к этому endpoint».

---

## Приложение: критерии готовности обоих контрактов

1. `plugin/dry-run` в CI ловит: несовместимость версий, битые contributions, опечатки meta-ключей, конфликт `:provides`, cycle в графе — всё с указанием файла/plugin.
2. Один демонстрационный plugin (`void/redis`) проходит полный цикл: config-schema, компонент с `:provides`, вклады в cli/health/session-store/instrument — и удаляется из проекта одним удалением из списка без следов.
3. `explain-route` показывает происхождение каждого meta-значения по слоям.
4. Контракты `defextension-point` schema и reserved-ключи v1 зафиксированы в docs; изменения — только через deprecation-процедуру из 1.5.

---

# Приложение A. Отчёт: async libpq × janet ev — проверено прототипом ✅
**Вопрос:** можно ли гонять libpq в non-blocking режиме на fiber'ах Janet, не блокируя event loop и без thread pool?

**Ответ: да.** Реальный прототип (Janet 1.41.3-dev + libpq 16 + Postgres 16, Ubuntu 24):

```
3 × pg_sleep(1) конкурентно на одном OS thread:  1.00s  (последовательно было бы 3s)
ticker-fiber во время запросов:                  10/10 тиков (loop свободен)
readiness-waits на запрос:                       ровно 1 (нет busy-spin)
20 × pg_sleep(0.5) конкурентно:                  0.50s
```

## Архитектура решения

Janet не даёт из чистого Janet «подожди readability произвольного fd» (в `ev/` такого нет, `ffi/` не помогает). Но C API даёт всё: `janet_stream(fd, flags, methods)` оборачивает произвольный fd, а `janet_async_start(stream, mode, cb, state)` усыпляет fiber до события, **не читая данные** — ровно то, что нужно libpq, который сам владеет своим сокетом.

Итог: **микро-shim на C (~60 строк) + весь драйвер на чистом `ffi/`**.

### Shim (native module `pqwait`)

Две функции:
- `(pqwait/watch fd :read|:write)` → делает `dup(fd)` и оборачивает в JanetStream **только с одним флагом направления**
- `(pqwait/wait watcher)` → `janet_async_start` с соответствующим `JANET_ASYNC_LISTEN_*`; callback по `EVENT_READ/WRITE` делает `janet_schedule(fiber, :ready)` + `janet_async_end`; по `HUP/ERR/CLOSE` → `:err`/`:closed`

Ключевые детали, добытые из исходников `ev.c`:
1. **Регистрация в epoll идёт по `stream->flags`, а не по listen-mode** (`ev.c`: `if (flags & READABLE) ev.events |= EPOLLIN; if (flags & WRITABLE) ev.events |= EPOLLOUT`, level-triggered). Поэтому стрим с обоими флагами всегда «writable» → шумные события. Направление-специфичные обёртки — правильный дизайн.
2. **`dup(fd)` на каждую обёртку** — отдельная epoll-регистрация на read и write без конфликта `EPOLL_CTL_ADD` (EEXIST → panic в janet).
3. `janet_async_start` — `JANET_NO_RETURN`: это последний вызов в cfunction.
4. `PQsocket` может меняться во время connect (multi-host) → в connect-loop пересоздавать watcher каждую итерацию.

### Драйвер (чистый Janet + ffi)

`ffi/context` + `ffi/defbind` на ~18 функций libpq. Классические паттерны:
- **connect**: `PQconnectStart` → loop `PQconnectPoll` (1=wait read, 2=wait write, 3=OK, 0=fail)
- **query**: `PQsendQuery` → `PQflush`-loop (1 → wait write) → loop: `PQisBusy`? → wait read → `PQconsumeInput`; иначе `PQgetResult` до NULL
- `PQsetnonblocking(conn, 1)` после connect

⚠️ Грабли, на которые я наступил в прототипе (чтобы ты не наступал): `(native "path.so")` возвращает env table, где значения — **binding tables** `@{:value <cfunction> :doc ...}`, а не сами функции. `((mod 'watch) ...)` молча делает table lookup → nil. Извлекать через `(in (in mod 'watch) :value)` или использовать нормальный `import`-loader. Мой первый «отрицательный» результат (3.04s, busy-spin 250k итераций) был именно этим багом, а не ограничением платформы.

## Следствия для void/db-postgres

1. Thread pool не нужен — драйвер полностью на ev loop, паритет с node-postgres по модели.
2. Shim обобщается: `void/fdwait` — общий примитив «readiness на чужом fd» для ЛЮБЫХ FFI-библиотек с неблокирующим API (librdkafka имеет свой poll-механизм, но паттерн тот же).
3. Осталось для production-драйвера: `PQsendQueryParams` (prepared/binary), pipeline mode (`PQenterPipelineMode`, PG14+), NOTIFY (`PQnotifies` после consume), cancel (`PQcancelStart` — тоже poll-loop), TLS через `PQconnectStart` (libpq сам делает handshake — TLS к Postgres бесплатен!), row-mode (`PQsetSingleRowMode`) для стриминга больших результатов.
4. Файлы прототипа: `pqwait.c`, `proto2.janet` (приложены).

**Оценка void/db-postgres после прототипа: M подтверждается, риск снят.**

---

# Приложение B. Файлы прототипа

- `pqwait.c` — C-shim: направление-специфичные readiness-watchers на dup(fd) через `janet_stream` + `janet_async_start`
- `proto2.janet` — async libpq драйвер на чистом `ffi/` + бенчмарк конкурентности