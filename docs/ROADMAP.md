# ROADMAP: void

> Дорожная карта реализации по [SPEC.md](SPEC.md) и [ADR 0001–0019](adr/README.md). Волны — из SPEC §6, критерии готовности контрактов — из SPEC, часть II. Документ живой: статусы обновляются, порядок внутри волны может меняться, порядок волн — нет.

**Правило зависимостей:** каждый plugin зависит только от `void/core` и plugins своей волны или более ранних. Волна считается закрытой не по «код написан», а по exit-критериям.

**Сквозной принцип — dogfooding:** с волны 0 вся разработка ведётся через netrepl внутри системы; с волны 1 каждый следующий plugin строится на предыдущих (admin рендерится через html+htmx, jobs-ui — тоже, bench-приложения — обычные void-приложения).

---

## Текущее состояние (2026-08-28)

| Что | Статус |
|---|---|
| SPEC (обзор + контракты Plugin API / Route Metadata) | ✅ написан |
| ADR 0001–0015 | ✅ accepted |
| ADR 0016–0018 (lifecycle-стадии, inject-тесты, core/log) | ✅ реализованы в v0.1 |
| ADR 0019 (pressure) | ✅ accepted и реализован в 2.6 (с уточнениями: два plugin'а, RSS вместо heap, 503 вызовом error-пути, никакой агрегации в prefork-master) |
| Прототип async libpq × ev (`pqwait.c`, `proto2.janet`) | ✅ риск снят (ADR-0011, SPEC прил. A) |
| Монорепо, `void/core` | ✅ `system`, `config`, `schema`, `plugin`, `meta`, `hooks` (+шина), `void/run!`; deprecation-алиасы extension points (`:aliases`); **`void/core/log`** — structured logger (ADR-0018: lazy-макросы, ns-дерево уровней, dyn-контекст, pretty/jdn sinks, serializers/redact) |
| `void/dev` + `void/test` | ✅ netrepl-компонент, file watcher c авто-restart + хук `:void.dev/reloaded`, fixtures/factories (`:generator`-проекция); **`test/inject`** (ADR-0017: with-http, cookie jar, `:json`/`:form`/`:raw`, sse-events) |
| `void/http` | ✅ HTTP kernel (1.1): сервер на net/ev (keep-alive, лимиты, chunked, SSE, drain), PEG-router с symbol-handlers и metadata-merge, фазовые middleware + **lifecycle-стадии** (ADR-0016: `:void.http/hook`, `:void.http/hooks`, `:on-response`/`:on-error`/`:on-timeout`, request-id + access-log), sessions/static/multipart/negotiation, error rendering, `with-request`/`explain-route`, prefork `:workers :auto`, rebuild route table по hot reload, **kernel/server split** (ADR-0017), `render-error` — error-путь вызовом, а не броском (для 2.6) |
| `void/html` + `void/htmx` (1.2–1.3) | ✅ hiccup/temple за `:void.html/engine`, form-хелперы из schema, assets, hx-хелперы, `:void.htmx/partial` |
| `void/rest` + `void/openapi` (1.4–1.5) | ✅ `defresource`, schema-валидация/coercion, problem+json, OpenAPI 3.1 проекция + Swagger UI |
| `void/cli` (1.6) | ✅ `void new` / `void dev` / `void routes` / `void repl`; команды — extension point, subset-старт через `:needs` |
| bench-suite (1.7) | ✅ B0/B1 + Go/FastAPI baselines, wrk/wrk2-методика, 5%-пороги в CI; бюджеты §8.2 промерены на референс-окружении — [BENCH-v0.1.md](BENCH-v0.1.md) |
| Demo волны 1 | ✅ `examples/guestbook` (server-rendered HTMX, schema-формы) = smoke-тест в CI; тот же код генерирует `void new` |
| **Контракты v1** | ✅ **заморожены в v0.1**: [CONTRACTS.md](CONTRACTS.md) (автогенерация из деклараций + drift-check в CI), deprecation-процедура — [CONTRIBUTING.md](../CONTRIBUTING.md#deprecation) |
| `void/db` (2.1) | ✅ ядро: контракт `:void/db-driver`, fiber-aware пул с метриками, SQL-как-данные, dyn-транзакции + `:void.db/txn` (plugin `void/db-http`), миграции и `void db migrate/rollback/status/new/erd`, Data Mapper + AR-сахар с N+1-guard (ADR-0009); композиция входит в `dry-run`/`gen-contracts`, `:void.db/txn` — declared-строка [CONTRACTS.md](CONTRACTS.md) |
| `void/db-sqlite` (2.2) | ✅ референс-реализация контракта драйвера поверх janet sqlite3: pragma-набор на соединение из `[:db-sqlite]`, детект RETURNING по версии, `BEGIN IMMEDIATE` + savepoints, файловый дефолт-путь, `:memory:` как одно keeper-соединение |
| `void/fdwait` (2.2) | ✅ единственный нативный модуль монорепы (~60 строк C, ADR-0011): «усыпи fiber до readiness чужого fd», level-triggered, `dup(fd)` на watcher, переиспользование watcher'ов через `pair` |
| `void/db-postgres` (2.2) | ✅ libpq в non-blocking режиме на ev-цикле через `void/fdwait`, без thread pool: prepared-пара, single-row streaming, pipeline mode, LISTEN/NOTIFY на своём соединении, cancel, TLS силами libpq; handle переоткрывает мёртвое соединение под пулом |
| `void/redis` (2.2) | ✅ RESP2/RESP3 в чистом Janet (сканер + PEG), fiber-aware пул, pipelining, кодеки за `:void.redis/codec`, Lua-скрипты, pub/sub на своём соединении; `void/redis-http` — session-store для `void/http` |
| `void/cache` (2.3) | ✅ `:void/cache-store` (что реализуют) + `:void/cache` (от чего зависят), memory-store с TTL и точным LRU, `remember`/`wrap` с single-flight, упавший store деградирует в промах; `void/cache-redis` — store в redis, `void/cache-http` — `:void.cache/response` |
| `void/jobs` (2.4) | ✅ `:void/jobs-backend` (восемь функций над записями, атомарен из них один — `claim!`) + `:void/jobs` (политика, enqueue, события); три backend'а на одном контракте и одна conformance-сюита на всех; `defjob` с ретраями/backoff+jitter/приоритетами/delayed/unique/DLQ, flows, rate limiting и concurrency per queue, group-ключи, `defschedule` на spork/cron с backend-локом; executor — фиберы `ev/`, а не spork/tasker (уточнение в ADR-0012) |
| `void/pressure` (2.6) | ✅ `void/pressure` — sampler loop-lag/RSS, пороги с гистерезисом восстановления за одним boolean, `:void.pressure/check` для того, что рантайм измерить не может, события `:high`/`:recovered`; `void/pressure-http` — 503 + `Retry-After` в слоте 100 через `http/render-error` (вызовом, не броском), `:void.pressure/exempt` не оборачивается вовсе; тест насыщения на реальном сокете в CI |
| Волна 2, остальное (2.5, 2.7) | не начато — bench B2/B3, дистрибуция (ADR-0020) |
| Волны 3+ | не начаты |

Открытые вопросы SPEC §7: (1) spork/http — закрыт (ADR-0015 accepted); (2) async libpq — закрыт; (3) формат route metadata — **заморожен в v0.1** ([CONTRACTS.md](CONTRACTS.md)); (4) naming/монорепо — закрыт; (5) `:void-api` versioning — заложен в скелет.

---

## Обзор волн

```
Волна 0  фундамент      core: system → config → schema → plugin → hooks → dev(netrepl)
Волна 1  вертикаль      http → html → htmx → rest → openapi → cli(min) + bench B0/B1
                        + core/log → lifecycle-стадии → inject-тесты (до заморозки контрактов)
Волна 2  данные         db → sqlite → postgres → redis → cache → jobs → pressure + bench B2/B3
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
- [x] `contribute!` + resolution: валидация по schema точки, ошибки с plugin-источником, did-you-mean для опечаток, «повисшие» вклады → ошибка
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
- [x] `void new` (шаблон проекта: HTMX-guestbook со schema-формой), `void routes` (+`--keys`), `void repl` (netrepl-клиент)
- [x] `void dev` — полный `run!`-цикл в `:dev` профиле (watcher + netrepl); hot reload пересобирает route table через хук `:void.dev/reloaded` → `http/rebuild!` (live-чтение manifest registry)

### 1.7 Bench-suite: старт *(ADR-0014)*

- [x] Каркас `void bench` + `bench/apps/`: B0 plaintext, B1 JSON echo; wrk2/wrk (loadgen-контейнер рядом), методика из SPEC §8.3 — таргеты/бюджеты как данные (`bench/void/bench/targets.janet`), команда `bench` — обычный `:void.core/cli` contribution
- [x] Первый прогон фиксирует baseline (`bench/results/baseline.jdn`) → пороги регрессии 5%; в CI (`bench.yml`) — относительное сравнение merge-base vs head на одном раннере (shared runners не доверяем абсолютным числам, ADR-0014)
- [x] Baselines для калибровки: Go net/http, FastAPI — `bench/baselines/`, таргеты `go-*`/`fastapi-*` в том же суите

### 1.8 `void/core/log` — structured logger *(S/M; ADR-0018)*

- [x] Принять ADR-0018
- [x] Ядро: record = plain table, макросы уровней (аргументы не вычисляются при выключенном уровне), уровни per-namespace (префиксное дерево) со сменой в рантайме из REPL
- [x] Контекст в dyn: `log/with-context` (child-logger-семантика), хелпер переноса в `ev/go`-таски
- [x] Sinks — point `:void.core/log-sink`: pretty stderr (dev, sync), JSON/JDN-lines через буферизованный канал + writer-fiber (prod; drop со счётчиком при переполнении, sync-flush на `:fatal`)
- [x] Serializers — point `:void.core/log-serializer` (`:err`, `:req`); `:redact`-пути поверх secret-механики config
- [x] http: request-id middleware (фаза observability) кладёт id в log-context; access-log на стадии `:on-response` (1.9)
- [x] Строка в bench-таблице: B1 с включённым access-log (overhead зафиксирован, §8.5 п. 4)

### 1.9 Request lifecycle — именованные стадии *(S; ADR-0016)*

- [x] Принять ADR-0016; слоты/имена стадий v1 — в заморозку контрактов v0.1
- [x] Стадии в цепочке: `:on-request` (1500), `:pre-parsing` (1900), `:pre-validation` (5900), `:pre-serialization` (9800), `:pre-handler` (9900), `:on-send` (500) — компиляция hooks в цепочку route на билде таблицы, пустая стадия не порождает wrapper
- [x] Внецепочечные точки: `:on-response` (после записи в сокет — из сервера), `:on-error` (из errors перед renderer), `:on-timeout` (при deadline-отмене handler-task)
- [x] Регистрация: point `:void.http/hook` (global) + metadata-ключ `:void.http/hooks` (route-level, merge `:concat`, символы)
- [x] Короткое замыкание из hook'а (response-map) с прогоном ответных стадий
- [x] App-level: `:void.http/listening`, `:void.http/draining`, `:void.http/route-added` (аналог onRoute)
- [x] `explain-route` показывает hooks каждой стадии с provenance (global/group/route)

### 1.10 `void/test` — inject-harness *(S; ADR-0017)*

- [x] Принять ADR-0017
- [x] Рефакторинг `void/http`: пара компонентов `:http/kernel` (цепочки/hooks/handler, ноль I/O) и `:http/server` (`:deps [:http/kernel]`; сокет, drain, prefork); `with-request`/REPL — через kernel
- [x] `test/client` (cookie jar, базовые заголовки) + `test/inject`: `:json`/`:form`-сахар, `:raw` (сырые байты через серверный wire-парсер — тесты лимитов/smuggling)
- [x] Fidelity: полный путь (routing → стадии 1.9 → middleware → handler → рендер lazy views → кодеки → `:on-send`) + сериализация ответа в память тем же `write-head`/`write-body` → `:on-response`; результат — response table + `:raw`-байты
- [x] Хелперы: `test/json`, `test/text`, `test/sse-events`; `test/with-http` (старт `:only [:http/kernel]` → клиент → guaranteed stop)
- [x] Тесты demo-приложения переведены на inject (сессия+CSRF+HTMX-фрагменты — сценарий login → авторизованный запрос)

### Exit-критерии волны 1

1. [x] Demo-приложение (server-rendered HTMX, формы с валидацией из schema) работает — `examples/guestbook` (= smoke-тест в CI); `void new && void dev` → рабочий цикл с hot reload (live-хендлеры + авто-rebuild route table по хуку `:void.dev/reloaded`).
2. [x] Контракты заморожены: reserved-ключи metadata v1 (включая `:void.http/hooks`), lifecycle-стадии v1 (имена+слоты, ADR-0016) и schema всех extension points зафиксированы в [CONTRACTS.md](CONTRACTS.md) (автогенерация из деклараций + drift-check в CI); дальнейшие изменения — только через deprecation ([CONTRIBUTING.md](../CONTRIBUTING.md#deprecation); alias-механика точек реализована в host).
3. [x] `explain-route` показывает происхождение каждого значения (+ middleware/stage-цепочку, source, warnings).
4. [x] B0/B1 в CI с порогами (относительный 5%-gate merge-base↔head); бюджеты §8.2 промерены на референс-окружении, корректировки и причины — [BENCH-v0.1.md](BENCH-v0.1.md); абсолютный gate — `void bench budgets`.
5. [x] Тесты demo-приложения ходят через `test/inject` без сокета (ADR-0017; kernel/server split, cookie jar, `:raw`-байты wire-кодом); access-log пишется через `void/core/log` на `:on-response` (ADR-0016/0018) — socket- и inject-пути проходят одни и те же стадии (lifecycle-test + inject-test).
6. [x] Тег v0.1.

---

## Волна 2 — данные

Цель: продуктовый минимум (Laravel-паритет по ядру) → v0.2.

### 2.1 `void/db` — kernel + entity layer *(M; ADR-0009)*

- [x] Интерфейс `:void/db-driver` (`:dialect/:connect/:close/:execute` + опц. prepared, tx, savepoints, `:ping`, `:insert-id`, `:returning`); `driver/normalize` валидирует и подставляет SQL-фолбэки — `db/void/db/driver.janet`
- [x] Fiber-aware пул: чекаут в dyn (`with-conn`, авто-возврат через defer), ленивое открытие до `:size`, FIFO-очередь ожидающих с дедлайном в дочерней задаче (не `ev/with-deadline` на root task — класс багов ADR-0015), discard брошенного соединения освобождает слот; метрики (`:waits`/`:wait-us`/`:timeouts`/`:queries`/`:query-us`) → health — `pool.janet`
- [x] Query builder (SQL как данные, диалекты в реестре: `:ansi`/`:sqlite`/`:postgres`); идентификаторы kebab→snake с квотированием, `[:val x]`/`[:raw s]`, `IS NULL` вместо `= ?`, пустой `IN` → `1 = 0` — `builder.janet`
- [x] `(db/with-tx ...)` через dyn (вложенные — SAVEPOINT, `db/rollback!`, упавший COMMIT/ROLLBACK выкидывает соединение из пула) + декларативно `:void.db/txn` в route metadata — `state.janet`, отдельный plugin `void/db-http` (`http.janet`), чтобы CLI/воркер не тянул HTTP-ядро
- [x] Migrations: janet up/down (функция, строка или массив SQL), таблица версий, транзакция на файл, drift-детект «версия применена, файла нет»; `void db migrate/rollback/status` + `void db new` — `migrate.janet`
- [x] Entity: `defentity` (= defschema + db-mapping; биндинг — сама схема, так что `schema/select` даёт DTO), Repository API (`find/find!/query/one/count/exists?/insert!/insert-all!/update!/delete!/delete-where!`), явный `:preload` — один batched-IN на связь, с вложенностью — `entity.janet`
- [x] AR-сахар через table prototypes: descriptor+snapshot в proto (`pp`/`keys` показывают только колонки), `save!` диффит → partial UPDATE, optimistic locking по `:db/version`; `db/rel`, `db/preload!`, опциональный identity map
- [x] N+1-guard: `db/rel` вне preload — warning с местом вызова в dev, ошибка в `:strict`, `[:db :n1-guard]` в конфиге (в `:prod` по умолчанию off); callbacks на entity — НЕТ (ADR-0009)
- [x] Инструментация драйвера: единая воронка исполнения (timing → метрики пула, `:debug`-строка sql/params/us в `void/core/log`) — точка подключения для `:void.obs/instrument` в волне 3
- [x] `void db erd` — mermaid-проекция реестра entity (`erd.janet`); exit-критерий 3 волны закрыт заранее
- [x] `void/db` + `void/db-sqlite` + `void/db-http` включены в `scripts/dry-run.janet` и `gen-contracts` (реальный драйвер появился в 2.2); `:void.db/txn` переехал из reserved-таблицы CONTRACTS в declared, контракт ключа продолжает пиниться тестом `db/test/plugin-test.janet`

### 2.2 Драйверы

- [x] `void/db-sqlite` *(S)* — обёртка janet sqlite3, референс-реализация контракта драйвера: pragma-набор на каждое новое соединение из `[:db-sqlite]` (WAL, `busy_timeout`, `foreign_keys` — sqlite по умолчанию FK не проверяет), RETURNING по детекту версии библиотеки (≥3.35, иначе перечитывание по `last_insert_rowid`), `BEGIN IMMEDIATE` по умолчанию (deferred-транзакция под пулом = классический SQLITE_BUSY при апгрейде блокировки) + savepoints, keeper-соединение компонента (кривой путь падает на старте, а не на первом запросе) — `db-sqlite/void/db-sqlite/driver.janet`
  - границы биндинга, зафиксированные тестами: prepared-пары нет (ядро уходит на фолбэк `:execute`), мульти-statement строка компилируется целиком до выполнения (DDL и зависимые statements — массивом строк в миграции), NULL-колонка отсутствует в строке результата, вызовы синхронные и блокируют ev-цикл (за асинхронность отвечает `void/db-postgres`)
  - URI-имена файлов выключены (`SQLITE_USE_URI` — compile-time опция, биндинг её не ставит), поэтому `file:...?mode=memory&cache=shared` не работает: путь берётся буквально и превращается в файл со странным именем. Отсюда два следствия — путь с префиксом `file:` драйвер отвергает с объяснением, а `:memory:` физически односоединенческая БД: драйвер отдаёт пулу одно и то же keeper-соединение, `[:db :pool :size]` > 1 с ней — ошибка старта с указанием, что править. Дефолтный путь поэтому файловый (`db/void.sqlite3`, родительский каталог создаётся)
- [x] `void/fdwait` *(S; ADR-0011)* — единственный нативный модуль монорепы (~60 строк C): «усыпи fiber до readiness чужого fd», ничего не читая и не записывая — того, что `ev/` выразить не может. Один watcher = одно направление (регистрация в loop идёт по флагам стрима, двунаправленный watcher на чтении вырождается в busy-spin; `:both` оставлен для send-петли, которой нужно дренировать вход), `dup(fd)` на watcher (два стрима на один fd = EEXIST в epoll; и закрытие watcher'а не трогает сокет владельца), level-triggered явно (kqueue по умолчанию EV_CLEAR — edge-triggered watcher навсегда засыпает на уже готовом fd). `pair` переиспользует watcher'ы между тысячами ожиданий на одном соединении, `refresh!` — на случай, когда fd меняется под ними (multi-host connect libpq). Тесты меряют главное: fiber просыпается от чужого fd, ev-цикл при этом свободен, 8 ожиданий идут конкурентно — `fdwait/src/fdwait.c`, `fdwait/void/fdwait/init.janet`
- [x] `void/db-postgres` *(M; ADR-0011)* — производственный вариант прототипа: libpq в non-blocking режиме на ev-цикле через `void/fdwait`, без thread pool. Три петли одной формы, все паркуются в fdwait, ни одна не спинит: `PQconnectStart`/`PQconnectPoll` (сокет может смениться на multi-host — `refresh!`), `PQflush` с ожиданием на `:both` (ждать только writable = дедлок с сервером, который перестал читать, потому что мы не дренируем его вывод), `PQisBusy`/`PQconsumeInput`/`PQgetResult` до NULL — всегда до NULL, иначе соединение остаётся посреди протокола. Что сверх контракта драйвера: `PQsendQueryParams`, prepared-пара, single-row streaming, pipeline mode (libpq 14+), LISTEN/NOTIFY, cancel (non-blocking poll-loop на libpq 17+, синхронный `PQcancel` — задокументированный фолбэк), TLS целиком на libpq (`sslmode` — обычный параметр соединения, кода TLS в плагине нет). Структурная ошибка вместо строки: SQLSTATE, constraint, column, table — `db-postgres/void/db-postgres/`
  - `:connect` отдаёт пулу **handle**, а не PGconn: void/db-пул не пингует и выбрасывает соединение только на упавшей транзакции, поэтому убитый бэкенд иначе раздавался бы вечно. Handle владеет conninfo и каталогом prepared-имён и переоткрывает соединение, найдя старое мёртвым — но только вне транзакции и только до отправки statement'а; `COMMIT` на мёртвом соединении — ошибка (он не закоммитил), `ROLLBACK` — успех (сессия уже откатилась, и это то, что пропускает исходную ошибку к вызывающему вместо ошибки отката поверх неё). Каталог сессии переживает замену, поэтому кэш sql→имя в пуле остаётся валидным, а имя, которого новая сессия не знает, готовится заново (26000)
  - конфиг: URL и keyword-строка сходятся в keywords (URI нельзя *дополнить* — libpq парсит одно или другое, поэтому `postgres://` разбирается здесь), явный ключ бьёт URL, серверные настройки (`:statement-timeout`, `:search-path`, `:settings`) едут в libpq'шном `options` как `-c name=value` — без лишнего round trip и уже для первого statement'а. Дефолты почти пусты: всё, что не названо, libpq берёт из окружения ровно как psql (PGHOST, ~/.pgpass, ~/.postgresql/root.crt)
  - LISTEN/NOTIFY — отдельное соединение вне пула (уведомление приходит в *сессию*, которая сделала LISTEN, а пул выдаёт разные), один fiber в fdwait, ноль стоимости в простое; подписки не выпускают SQL из чужого fiber'а, а будят слушающий через `conn/interrupt!` (watcher'ы снимаются, соединение не трогается), и он сверяет LISTEN'ы с желаемыми перед следующей парковкой. Без подписок соединение вообще не открывается. Доставка at-most-once — это Postgres, не драйвер
  - `[:db-postgres :prepared] false` снимает prepared-пару целиком — ровно то, что нужно transaction-pooling pgbouncer'у, где prepared-statement живёт в сессии, которую вам не вернут
  - границы, зафиксированные тестами: COPY не поддержан (другой путь протокола), результаты читаются в текстовом формате (binary — пересборка выходных функций Postgres по типу; numeric отдаётся строкой, потому что double теряет ровно то свойство, ради которого numeric существует), `PQconnectStart` резолвит имя хоста синхронно (единственный блокирующий шаг, который никто не уберёт — отсюда ленивое открытие в пуле), NOTICE/WARNING сервера libpq печатает в stderr сам (перехват требует C-колбэка, которого `ffi/` не даёт)
  - CI: сервис-контейнер postgres:16 + `VOID_TEST_PG`; `void/fdwait` и `void/db-postgres` в тестах, оба плагина — в `scripts/dry-run.janet` и `gen-contracts` (два драйвера на `:void/db-driver` = ровно та неоднозначность, которую ядро отказывается разрешать само, и гейт называет реализацию так же, как это сделал бы конфиг приложения)
- [x] `void/redis` *(M)* — RESP2/RESP3 в чистом Janet на ev-цикле: соединение — это `net/`-стрим и буфер, поэтому нативного кода и клиентской библиотеки нет вовсе, а N фиберов на N соединениях — это N параллельных команд в одном потоке (ADR-0010). Пакет `redis/`
  - **протокол** — та же развилка, что в `void/http/wire`: дешёвый сканер `resp/scan` находит границу кадра, PEG собирает значение. Сканер нужен потому, что RESP length-prefixed: блоб перешагивается арифметикой, а обрезанный кадр отвечает **сколько байт не хватает** (читатель просит их одним чтением, вместо квадратичного перечитывания буфера на каждый чанк), и потому что `nil` от `peg/match` слепляет два разных исхода — «кадр ещё не пришёл» и «это не RESP» (первое ждём, второе — ошибка, иначе не-redis на порту вешает фибер навсегда). PEG отвечает за значения, и оба агрегата — это ровно `lenprefix`, комбинатор под такой протокол: RESP2 и RESP3 в одной грамматике (map/set/push/attribute/verbatim/big number/double), ошибки и push-кадры — **значения**, потому что pipeline из трёх ответов, где упал один, должен вернуть остальные два
  - **кадрирование как инвариант**: ответы приходят в порядке команд, то есть соединение — очередь, а не пара запрос/ответ. Поэтому read-timeout помечает соединение сломанным (ответ всё ещё придёт — доверять такому соединению больше нельзя), а RESP3 push-кадры снимаются из потока в `receive-reply`: внеочередной кадр, доехавший до вызывающего, который считает ответы, сдвинул бы все последующие ответы на один
  - **пул** той же формы, что в `void/db` (FIFO-очередь ожидающих, дедлайн в дочерней задаче, а не `ev/with-deadline` на root task — класс багов ADR-0015), но **своим кодом**: кэш не должен требовать БД, пакеты независимы. Пул нужен не потому, что redis медленный, а потому, что ответы упорядочены: одно соединение выстраивает фиберы в очередь за самым медленным
  - **retry ровно одного класса отказа**: самая частая ошибка в проде — не «redis лежит», а «сокет закрыли, пока он лежал в idle» (серверный `timeout`, рестарт, прокси), и отличить такой сокет от живого до записи нельзя. Ретрай ограничен как только можно: только отказ *соединения* (не ответ-ошибка), только на соединении, побывавшем в idle, только один раз и никогда внутри `with-conn` — сессию нельзя молча подменить под MULTI. Честная оговорка задокументирована: команда, чей ответ потерян, могла выполниться, `[:redis :retry] false` выключает
  - **сахар и граница**: `get/set/del/expire/ttl/incr/hset/hgetall/lpush/blpop/sadd/zadd/zrange-by-score/scan/script/remember` — с префиксом ключей и кодеком значений; `command`/`call` — сырой слой без того и другого (обёртка, угадывающая, какие аргументы произвольной команды суть ключи, ошибается на первой же интересной — EVAL, ZADD, XREAD). `ttl` отвечает `:none`/`nil` вместо -1/-2, `hgetall` — таблицей, `scan` ходит SCAN'ом, а не KEYS (KEYS на проде — это инцидент)
  - **кодеки** — точка `:void.redis/codec`, `[:redis :codec]` выбирает: `:raw` по умолчанию (совместимость с тем, что пишут другие сервисы, и с redis-cli), `:jdn` (таблицы, keywords, вложенность — Janet-only), `:json`
  - **pub/sub** — отдельное соединение вне пула (подписанное соединение в RESP2 не принимает обычных команд, а пул отдаёт его следующему желающему), один фибер в чтении, соединение открывается первой подпиской. Два фибера трогают его безопасно, потому что с разных сторон: читатель только читает, `subscribe!` только пишет под локом; соединение открывает **только** читатель (иначе гонка: двое открывают по соединению и подписываются каждый на своё), а желаемый набор подписок сверяется при каждом переподключении. Доставка at-most-once — это redis, не драйвер, и так и написано
  - `void/redis-http` — companion-плагин (как `void/db-http` при `void/db`): вклад в `:void.http/session-store`, значение в jdn (сессия — таблица с keyword-ключами; JSON вернул бы строковые), TTL — это expiry redis'а, поэтому `:sweep` — честный no-op. Это же закрывает конфликт «сессии + `:workers :auto`» из ADR-0010
  - TLS нет: `rediss://` отвергается с объяснением (ADR-0010 — терминировать прокси или unix-сокетом), Cluster/Sentinel — другой клиент (MOVED/ASK-редирект и слежение за топологией) и отдельный ADR. Интерфейсы `:void/cache` и `:void/queue-backend` приедут с плагинами, которые их определяют (2.3/2.4) — примитивы для них тут все: TTL, атомарные счётчики, `SET NX`-локи, sorted sets под отложенные задачи, блокирующие pop'ы и Lua
  - CI: сервис-контейнер `redis:7` + `VOID_TEST_REDIS`; протокол, конфиг и кодеки тестируются без сервера, остальное — против настоящего (и не трогает чужие ключи: у каждого сюита свой префикс, `FLUSHDB` в тестах нет). Оба плагина — в `scripts/dry-run.janet` и `gen-contracts`, `:void.redis/codec` — в [CONTRACTS.md](CONTRACTS.md)

### 2.3 `void/cache` *(S)*

- [x] Интерфейс + memory impl (TTL, LRU); `(cache/wrap f ...)`; redis-backend — пакет `cache/`
  - **два интерфейса, а не один**: `:void/cache-store` — то, что *реализуют* (четыре функции над строками и значениями, остальное — задокументированные фолбэки, как у `:void/db-driver`), `:void/cache` — то, от чего *зависят* (префикс ключей, дефолтный TTL, single-flight, политика ошибок). Backend'ов два, оба `:provides :void/cache-store`, поэтому композиция с `void/cache-redis` требует `{:void/cache-store {:impl :cache/redis}}` — ровно та неоднозначность, которую ядро отказывается разрешать само, и та же строка, что нужна двум драйверам БД
  - **memory-store**: TTL + **точный** LRU (вытесняется реально давно не *использованный*, чтение считается использованием). Список давности — по **ключам**, а не по записям: интрузивный список из таблиц — это цикл, а `pp` на компоненте должен печататься (ADR-0001), две лишние hash-выборки на touch стоят дешевле этого. Протухание в двух местах, и оба нужны: лениво на чтении (там корректность) и фибером-подметальщиком (иначе значение, которое больше никто не прочитает, лежит в куче до вытеснения — а на незаполненном кэше это «никогда»); `[:cache :memory :sweep-interval] 0` выключает. Лимита в байтах нет: «сколько байт занимает это Janet-значение» не имеет ни дешёвого, ни точного ответа, поэтому лимит — в записях, и это честно написано вместо ключа, который врал бы
  - **упавший кэш деградирует в промах, а не в 500**: у кэша нет своих данных, терять нечего, поэтому `[:cache :on-error] :degrade` (по умолчанию) отвечает промахом, считает отказы и логирует не чаще раза в 10 секунд (авария, логирующая каждый запрос, — вторая авария поверх первой). `:raise` — для того, кто предпочитает знать
  - **single-flight**: холодный ключ на нагруженном роуте — это стадо: чем больше трафика, тем больше копий одного и того же расчёта. Первый фибер считает, остальные паркуются на канале и забирают результат — **включая ошибку** (стадо, которое после сбоя пересчитывает всё заново, — это то самое стадо). Внутрипроцессно; межпроцессный лок — другая фича с другим режимом отказа (умерший держатель), `[:cache :single-flight] false` выключает
  - **отсутствие — тоже значение, но только по просьбе**: промах у store'а — это nil, места для «закэширован nil» в протоколе нет, поэтому `:cache-nil` кладёт сентинел, а `fetch` возвращает `[found? value]` и различает их. На store'е, который не переживает keyword (redis с кодеком `:raw`, он объявляет `:values :bytes`), это ошибка с указанием, что настроить, — а не строка `":void.cache/nil"`, выданная кому-то как данные
  - **ключи**: написанные руками (строка, keyword, число) идут в store дословно — ключ, который вы написали, вы найдёте в keyspace; производные (аргументы `wrap`, составные) — через инъективный тегированный рендер с сортировкой пар словаря. Это и есть причина существования `void/cache/key`, а не вызова `%j`: Janet печатает ключи словаря в порядке хэша, стабильном ровно в пределах процесса, и разделённый кэш, где процессы ключуют по-разному, — это 0% попаданий без единого сообщения об ошибке. Анонимной функции `wrap` требует `:name` по той же причине
  - `void/cache-redis` — SET с PX, MGET, атомарный INCRBY (у store'а есть `atomic-incr?`, потому что фолбэк read-add-write точен только внутри процесса), кодек **свой** (`:jdn` по умолчанию, а не `[:redis :codec]`: `:raw` — правильный дефолт для клиента redis и невозможный для кэша, который держит таблицы; сессии выбрали так же и по той же причине). `clear` **обходит** свой префикс SCAN'ом и удаляет пачками — не атомарно и O(keyspace), но база общая, а `clear`, который был бы FLUSHDB, — это `clear`, который никто не рискнёт вызвать; префикс с glob-символом экранируется
  - `void/cache-http` — `:void.cache/response` `{:ttl :vary}` переезжает из reserved-таблицы CONTRACTS в declared. Слот 2500 — после парсинга, до сессии: попадание отдаётся, ни разу не открыв сессию (поэтому в нём физически не может быть Set-Cookie), но уже по разобранному пути и query. Это **разделяемый** кэш, и он ведёт себя как разделяемый: запрос с `Authorization` идёт мимо кэша целиком (RFC 9111 §3.5), ответ с `Set-Cookie`, с `cache-control: private|no-store` или со стриминговым телом не сохраняется — и каждый отказ логируется один раз на роут, а не молча. Кэшируются только 200; `:ttl 0` — способ отписаться от того, что поставила группа. Роут без ключа не получает обёртку вообще (`:when` вычисляется на построении таблицы), поэтому bench-строки по §8.5 п.4 здесь нет — вместо неё тест, который это пинит
  - CI: `cache/` в тестовых шагах, все три плагина — в `scripts/dry-run.janet` и `gen-contracts` (гейт называет реализацию `:void/cache-store` так же, как это сделал бы конфиг приложения); redis-suite — против сервиса-контейнера по `VOID_TEST_REDIS`, остальное тестируется без сервера

### 2.4 `void/jobs` *(M/L; ADR-0012)*

- [x] Persistence — интерфейс `:void/jobs-backend`: db (SKIP LOCKED polling), redis — пакет `jobs/`
  - **executor — фиберы `ev/`, а не spork/tasker**, и это единственное место, где реализация расходится с буквой ADR-0012. ADR называл tasker до чтения его исходников; tasker исполняет **подпроцессы** (задача — массив argv для `os/spawn`, записи — файлы `task.jdn` на диске). `defjob` устроен противоположно по необходимости: handler — внутрипроцессная функция через символ (ADR-0002), замкнутая на компоненты поднятой системы, и argv, выражающего «вызови эту функцию в этом процессе», не существует; дисковые записи tasker'а — ровно то, что заменяет backend-контракт. Требование ADR «исполнитель, не блокирующий цикл» на `ev/` — это фибер (ADR-0010). Уточнение записано в ADR-0012 и в шапке `void/jobs/worker`
  - **два интерфейса, как у db и cache**: `:void/jobs-backend` — то, что *реализуют* (восемь функций над записями; атомарен из них ровно один — `claim!`, и он и есть причина, по которой backend нужен вместо таблицы), `:void/jobs` — то, от чего *зависят*. Всё, что *решает* (сколько попыток, сколько ждать, что делает таймаут), живёт в runtime и одинаково под любым backend'ом — иначе контракт был бы не контрактом, а тремя разными очередями. Опциональные ключи (`reap!`, `touch!`, `lock!`/`unlock!`, `rate-take!`, `release-parent!`) имеют задокументированные фолбэки, а `capabilities` **выводит**, а не декларирует, какие из них настоящие: «rate limit — per process» оператор читает, а не обнаруживает
  - **три backend'а — одна conformance-сюита** (`test-support/conformance.janet`): таблица в куче, строки в БД и хеши в redis отвечают на одни и те же восемь вопросов, и сюита, которая гоняла бы только in-process backend, была бы сюитой, которая контракт ни разу не проверила
  - **у db-backend'а два пути claim'а, и оба под тестом**: на Postgres — один `UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED) RETURNING`, на остальных — select + перепроверенный update в транзакции (проигранная гонка остаётся проигранной, а не вторым запуском). Портируемый путь идёт против sqlite, SKIP-LOCKED — против настоящего Postgres по `VOID_TEST_PG` (`test/db-postgres-test.janet`), и там же проверяется свойство, ради которого SKIP LOCKED и берут: N одновременных claim'ов получают N **разных** записей. Убери `FOR UPDATE SKIP LOCKED` — сюита падает на дубликате, это проверено мутацией
- [x] `defjob` (символы → hot reload), retries backoff+jitter, приоритеты, delayed, unique, DLQ
- [x] Flows (parent-child DAG), rate limiting per queue, concurrency per worker, group-ключи
  - четыре лимита — четыре разных механизма, потому что вопросы разные: concurrency воркера — это число фиберов; per-queue — счёт до claim'а; group — счёт до claim'а **и** `:skip-groups` в claim, чтобы запись не пришлось возвращать (это и есть fair scheduling: тенант с десятью тысячами задач не может занять все фиберы); rate limit — **после** claim'а, иначе лимитер тратил бы токен на каждый пустой опрос
  - таймаут — `ev/deadline` на своей задаче, никогда `ev/with-deadline` вокруг: последнее отменяет корневую задачу (тот же класс багов, что задокументирован в ADR-0015)
- [x] Repeatable: spork/cron, `defschedule`, single-instance через backend-lock
  - лок берётся на **слот** (`jobs:schedule:<name>:<slot>`), а не на имя: слот — это то, что должно случиться один раз
- [x] Lifecycle events в bus (появится в волне 3 — пока hooks)
  - `:void.jobs/event` на реестре хуков ядра; события (`:enqueued` `:started` `:completed` `:failed` `:dead` `:stalled`) — это шов, который в волне 3 забирает `void/bus`
- [x] CI: `jobs/` в тестовых шагах, все три плагина — в `scripts/dry-run.janet` и `gen-contracts` (гейт называет реализацию `:void/jobs-backend` так же, как это сделал бы конфиг приложения); `:void.jobs/backend` уезжает из reserved-таблицы CONTRACTS — backend оказался интерфейсом через `:provides`, как `:void/db-driver` и `:void/cache-store`, а не extension point

### 2.5 Bench

- [ ] B2 (PG query), B3 (PG + SSR) в CI; проверка бюджетов ev-loop-lag/GC из §8.2

### 2.6 `void/pressure` — load shedding *(S; ADR-0019)*

- [x] Принять ADR-0019 — accepted, с уточнениями по итогам реализации (см. ниже и хвост ADR)
- [x] Sampler-компонент: loop-lag (дрейф `ev/sleep`), rss; custom-проверки — point `:void.pressure/check`
  - **два plugin'а, а не один** (ADR говорил «core + http»): `void/pressure` — sampler, пороги, флаг, health, события, только core; `void/pressure-http` — middleware и metadata-ключ. Тот же шов, что между `void/cache` и `void/cache-http`, и по той же причине: воркер, который крутит jobs и не слушает порт, имеет право знать, что его loop опаздывает, не поднимая ради этого HTTP-ядро
  - **heap-метра нет, и это janet, а не пропуск**: `gccollect`/`gcinterval`/`gcsetinterval` — вся GC-поверхность 1.41, и ни одна не говорит, сколько байт на куче сейчас. Память меряется как RSS (`/proc/self/status`; на macOS mach `task_info(MACH_TASK_BASIC_INFO)` через `ffi/` — `getrusage` не подходит, `ru_maxrss` это high-water mark, с которого не восстановиться), `:max-heap-bytes` как ключ не существует. Сигнал без прибора репортится отсутствующим, и порог над ним не срабатывает никогда: «прибор сломан» не должно читаться как «всё хорошо»
- [x] Пороги `:max-loop-lag`/`:max-rss-bytes` → флаг `:under-pressure` с гистерезисом восстановления
  - гистерезис — не полировка, а сама фича: один и тот же порог в обе стороны превращает процесс на границе в процесс, который режет каждый второй запрос и восстанавливается между ними. Два барьера: срабатывание на `:max-loop-lag`, возврат — ниже `:recovery-ratio` × порог и `:recovery-samples` чистых замеров подряд. `:high`/`:recovered` — по одному на эпизод, а не на замер
  - у custom-проверок гистерезиса нет и быть не может: «пул исчерпан» — не число, у которого бывает 80% себя. Проверка, которая бросила, считается давлением — проба, чей отказ значит «продолжайте», не проба
- [x] Middleware в слоте 100: 503 + `Retry-After` через error-путь (problem+json при rest); metadata `:void.pressure/exempt` для `/health`/`/metrics`
  - **вызовом, а не броском**: в `void/http` добавлена публичная `render-error` — те же `:void.http/error-renderer` в том же порядке. Буквальное «бросить 503» стоило бы стектрейса на каждый отвергнутый запрос и попадало бы в panic-логирование (`status >= 500`) — тысячи строк лога поверх перегрузки, ровно когда платить нечем
  - exempt-маршрут не оборачивается вовсе: `:when` считается один раз на сборке таблицы, так что `/health` не может быть срезан и не стоит ничего. Паттерн для деплоя — `/health` exempt + routing LB по нему, иначе балансировщик выведет воркер ровно в тот момент, когда тот пытался остаться полезным
- [x] Contribution в `:void.core/health` (degraded + причины), `(pressure/status)`, события `:pressure/high|recovered` в hooks-шину
  - отвергнутые запросы логируются **раз за эпизод** (`[:pressure-http :log]`), а счётчик уезжает в событие `:recovered`: лог, который сам становится частью перегрузки, — не наблюдаемость
- [x] Prefork: sampler per-worker, ~~агрегация в master health~~ — агрегировать нечем и незачем
  - воркеры не делят ничего, кроме слушающего сокета (ADR-0010), канала до master'а нет. Вместо выдуманной агрегации master помечается `:mode :supervisor` и не сэмплирует вовсе: его loop простаивает по построению, и ноль с него был бы измерением ничьих запросов. Агрегация — это SO_REUSEPORT
- [x] Тест насыщения в CI (exit-критерий 4): реальный сервер, реально заблокированный loop, реальный сокет — 503 + `Retry-After`, exempt `/health` жив, после снятия нагрузки `:recovered`. Длительность удержания loop'а рандомизирована: фиксированная фазируется с интервалом sampler'а и даёт один и тот же замер вечно
- [ ] Калибровка порогов по умолчанию на B2/B3 (насыщение: быстрый 503 вместо роста latency у всех) — вместе с 2.5

### 2.7 Дистрибуция и установка *(S; ADR-0020)*

- [ ] Принять ADR-0020
- [ ] `scripts/packages.janet` — граф пакетов как данные; проекции: шимы `*/test-support/paths.janet` (16 копий → две строки), топологический порядок установки, матрица шагов CI, список деревьев в `scripts/dry-run.janet`
- [ ] Корневой `project.janet` — bundle `void`: `declare-source` по деревьям пакетов, `declare-native` для `fdwait`, `declare-binscript cli/bin/void`; `janet-lang/sqlite3` остаётся runtime-требованием с ошибкой на `:start` (как libpq, ADR-0011)
- [ ] `bin/void` подхватывает `./jpm_tree/lib` **до** `(import void/cli)` — иначе CLI из глобального дерева и `void/http` из проектного дают два экземпляра `void/core`; заодно снять лишний shebang
- [ ] `void new` пишет настоящий `:dependencies` вместо комментария; Quick start в README становится исполняемым
- [ ] `scripts/bootstrap.janet` (deps + `jpm build` для `fdwait`) и repo-relative дев-шим `scripts/void` — контрибьютор получает `void` без установки
- [ ] CI: шаг «чистая машина» — установка bundle в изолированное дерево, `void new` + smoke сгенерированного проекта; путь пользователя становится гейтом, а не абзацем документации

### Exit-критерии волны 2

1. Demo: CRUD-приложение на Postgres с миграциями, background-джобами и кэшом; то же на SQLite сменой конфига.
2. Драйвер PG не блокирует loop: тест «конкурентные pg_sleep + ticker» из прототипа — в CI.
3. N+1-guard и dirty-tracking покрыты тестами; `void db erd` строит диаграмму из `:db/rels`.
4. Тест насыщения (ADR-0019): под перегрузкой процесс отвечает быстрым 503 + `Retry-After`, `/health` (exempt) остаётся живым, после снятия нагрузки — `:pressure/recovered`.
5. Установка проверяется в CI на чистом дереве: bundle → `void new` → сгенерированный проект стартует и отвечает (ADR-0020).
6. B2/B3 в CI. Тег v0.2.

---

## Волна 3 — enterprise

Цель: наблюдаемость и безопасность уровня Spring → v0.3.

### 3.1 `void/obs` *(L)*

- [ ] Logs: ядро уже в `void/core/log` с волны 1 (ADR-0018); здесь — trace-id/span-id в log-context, sampling, OTLP/файловые log-sinks
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
| Docs-сайт: генерация из деклараций (metadata-ключи, extension points, схемы) | каркас есть: `scripts/gen-contracts.janet` → [CONTRACTS.md](CONTRACTS.md) (+drift-check в CI); сайт — к v0.4 |
| Sampling-профайлер в void/dev (`debug/stack` по таймеру) + `bench/trace-request` | волна 2 (понадобится для B2/B3) |
| CONTRIBUTING: performance-правила §8.5, deprecation-процедура контрактов | ✅ сделано к v0.1 ([CONTRIBUTING.md](../CONTRIBUTING.md)) |
| Примеры-приложения (`examples/`) — по одному на волну, они же smoke-тесты | идёт: `demo` (волна 0), `guestbook` (волна 1, в CI) |
| Дистрибуция: монорепо как один jpm-bundle, граф пакетов как данные (ADR-0020) | 2.7, к v0.2; `jpm quickbin` single-binary — 4.5 |

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
