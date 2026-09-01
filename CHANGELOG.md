# Changelog

> Проекция git-истории (`scripts/gen-changelog.janet`), не рукопись: каждый коммит репозитория уже назван по форме `type: что (волна, ADR)`, теги отмечают границы релизов, ADR-ссылки ведут к решениям. Файл регенерируется на релизе; правки руками сюда не вносятся — они вносятся туда, откуда он собран.

## Unreleased

после v0.4 — волны 5–6, к v0.5 (ROADMAP, волна 7)

### Добавлено

- подготовка v0.5 — changelog как проекция git-истории, референс-замер одной командой, локальный санитарный проход (6.2, 6.3) (`77c41c0`)
- void/tls — исходящий TLS через libssl, memory-BIO и шов вместо ребра (5, [ADR-0038](docs/adr/0038-tls-ishodyashij-cherez-libssl-memory-bio.md)) (`209fdef`)
- examples/counter — live-счётчик на идиоме Biff, пример-приложение эксперимента (5, [ADR-0037](docs/adr/0037-datastar-stranica-kak-otvet-morph-cherez-sse.md)) (`7f5570f`)
- void/datastar — страница как ответ, morph title+body через SSE, идиома Biff (5, [ADR-0037](docs/adr/0037-datastar-stranica-kak-otvet-morph-cherez-sse.md)) (`37e53f1`)
- void/i18n — словарь как вклад с :precedence, locale как dyn, schema-ошибки переводятся сами (5, [ADR-0036](docs/adr/0036-i18n-slovar-kak-vklad-locale-kak-dyn-oshibki-perevodyatsya-sami.md)) (`2c13c48`)
- docs-сайт — проекция репозитория в GitHub Pages (сквозные работы, к v0.4) (`739336e`)
- void/kafka — event API вместо callbacks, fd от библиотеки, publish! ждёт подтверждения (5, [ADR-0035](docs/adr/0035-kafka-event-api-fd-ot-biblioteki-publish-zhdyot-podtverzhdeniya.md)) (`f5e0e5c`)
- void/oauth — клиент code+PKCE, сессия вместо хранилища, identity отдаёт приложение (5, [ADR-0034](docs/adr/0034-oauth-klient-code-pkce-sessiya-kak-pending.md)) (`f533ad6`)

### Исправлено

- auth/test — гейт :restrict проверялся не тем отказом (`4be4ad2`)

### Документация

- ROADMAP — волна 6 «анонс и обкатка», решение по datastar зафиксировано (6) (`646e337`)

## v0.4 — 2026-08-31

конец волны 4 — killer-фичи: admin + MCP; кандидат в публичный анонс

### Добавлено

- void/obs-otlp — protobuf как вторая проекция того же payload (4.1, [ADR-0027](docs/adr/0027-otlp-eksport-json-i-http-klient.md)) (`eb12cff`)
- void/db-mysql — поток на соединение, и параметр, который не становится синтаксисом (5, [ADR-0033](docs/adr/0033-mysql-potok-na-soedinenie-i-tekstovyj-protokol.md)) (`a89e742`)
- examples/shop — бэк-офис как проекция, и три дыры, которые он нашёл (4.4, 4.5) (`7e7f676`)
- void/cli — artisan, lock-файл композиции и один файл на деплой (4.5) (`0b66780`)
- void/grpc — Connect-RPC, где метод это маршрут (4.1, [ADR-0013](docs/adr/0013-grpc-cherez-connect-protocol.md)) (`6c522bf`)
- void/proto — protobuf как данные, и схема, которая узнала об этом сама (4.1, [ADR-0013](docs/adr/0013-grpc-cherez-connect-protocol.md)) (`0aef6f4`)
- void/admin — админка как проекция деклараций, ворота закрыты по построению (4.4, [ADR-0029](docs/adr/0029-admin-kak-proekciya-deklaracij.md)) (`de8bc15`)
- void/mcp — приложение как MCP-сервер, и ворота, закрытые по построению (4.3, [ADR-0031](docs/adr/0031-mcp-kak-proekciya-i-vorota-po-umolchaniyu.md), [ADR-0032](docs/adr/0032-resource-server-a-ne-oauth-klient.md)) (`1896536`)
- [:deploy :shape] — ни одного in-memory хранилища за пределами одного процесса (4.6, [ADR-0030](docs/adr/0030-forma-razvertyvaniya-i-razdelyaemye-hranilisha.md)) (`c126ddd`)
- void/ws — websocket как маршрут, а не как подсистема (4.2, [ADR-0028](docs/adr/0028-websocket-kak-marshrut-perehvat-soedineniya.md)) (`a6aae4b`)
- void/http/client — запрос и ответ как данные, до поверхности gleam-lang/http (`bca096a`)
- void/obs-otlp — OTLP/JSON до void/proto, и HTTP-клиент, которого не было (4.1, [ADR-0027](docs/adr/0027-otlp-eksport-json-i-http-klient.md)) (`8862231`)
- examples/shop — вся волна 3 в одном приложении, разложенная по модулям (`c413762`)

### Исправлено

- void/db-postgres — postgres-info печатал индексы вместо ключей (`b3672ff`)
- void/db/builder — DEFAULT FALSE молча пропадал на всех диалектах (`960b556`)
- void/crypto — OSSL_PARAM несёт указатель и длину, а не C-строку (`b436313`)
- void/http — пустое тело фреймируется Content-Length: 0 (`0823800`)

### Документация

- README v0.4 по позиционированию §9, exit-критерии волны 4 закрыты (`30272ca`)
- [ADR-0029](docs/adr/0029-admin-kak-proekciya-deklaracij.md) — админка как проекция деклараций, ворота закрыты по умолчанию (proposed) (`82da613`)

## v0.3 — 2026-08-29

конец волны 3 — enterprise-вертикаль: obs/auth/authz/bus

### Добавлено

- examples/blog — audit через шину и outbox (exit-критерий волны 3) (`4b39605`)
- void/bus — сообщение как факт, гарантия как декларация backend'а (3.6, [ADR-0012](docs/adr/0012-jobs-i-bus-razdelnye-plaginy-outbox.md)) (`a917e27`)
- examples/blog — вход по ссылке из письма (exit-критерий волны 3) (`e4fe5f7`)
- void/mail — сообщение как данные, доставка как решение композиции (3.5, [ADR-0026](docs/adr/0026-mail-soobshenie-kak-dannye-dostavka-kak-kompoziciya.md)) (`ab4a259`)
- examples/blog — вход, row-level ABAC и CSRF (exit-критерий волны 3) (`9cc8009`)
- void/security — CSRF, заголовки на краю, лимиты поверх контракта кэша (3.4, [ADR-0025](docs/adr/0025-security-csrf-zagolovki-limity.md)) (`c165b67`)
- void/authz — ABAC: политика как чистая функция, решение как значение (3.3, [ADR-0024](docs/adr/0024-authz-abac-kak-dannye.md)) (`f37f0b4`)
- void/auth — identity как данные, стратегии как точка расширения (3.2, [ADR-0023](docs/adr/0023-auth-identity-i-strategii.md)) (`33beb6f`)
- void/crypto — вся криптография одной системной библиотекой (3.2, [ADR-0022](docs/adr/0022-kriptografiya-cherez-libcrypto.md)) (`ae8f855`)
- bench — :ready у B2/B3, чтобы прогон не мерил полупустую таблицу (`3b5384d`)
- void/obs — метрики, спаны и цена инструментации (3.1) (`b2e4d9b`)

### Исправлено

- void/crypto — argon2id определяется fetch'ем KDF, а не таблицей символов (`60d1d6d`)

## v0.2 — 2026-08-28

конец волны 2 — продуктовый минимум, Laravel-паритет по ядру

### Добавлено

- demo волны 2 и DDL как данные — exit-критерии закрыты (2.8) (`f4df1f1`)
- дистрибуция — монорепо как один jpm-bundle, граф пакетов как данные (2.7) (`b047037`)
- bench B2/B3 и runtime-бюджеты §8.2 изнутри процесса (2.5) (`5cd2db1`)
- void/pressure — load shedding, флаг вместо неотзывчивости (2.6) (`f5982ef`)
- void/jobs — background jobs на одном контракте и трёх backend'ах (2.4) (`55a5844`)
- void/http — defroutes, сахар над route-source контрибуцией (`626e337`)
- void/cache — интерфейс, memory-store (TTL+LRU), wrap, redis (2.3) (`e431dae`)
- void/redis — RESP2/3 в чистом Janet на ev-цикле (2.2) (`8f9fe0c`)
- void/db-postgres — async libpq на ev-цикле (2.2, [ADR-0011](docs/adr/0011-async-libpq-cherez-c-shim.md)) (`0ec2f42`)
- void/fdwait — readiness на чужом fd (2.2, [ADR-0011](docs/adr/0011-async-libpq-cherez-c-shim.md)) (`a61bea2`)
- void/db-sqlite — референс-драйвер (2.2) + void/db в CI-гейтах (`90b44d2`)
- void/db — kernel + entity layer (2.1, [ADR-0009](docs/adr/0009-entity-layer-data-mapper-plus-ar.md)) (`5570606`)

### Производительность

- request-id/access-log по образцу fastify/pino — genReqId-счётчик без header lookup (opt-in [:http :request-id-header]), int-µs в access-log; замеры single-session A/B/A: request-id ≈ −3%, access-log с батчащим sink — в шуме; baseline перезаписан (access-log on, продовый дефолт), BENCH-v0.1.md исправлен (−31%/−23% были межсессионным артефактом) (`6822deb`)

### Документация

- [ADR-0019](docs/adr/0019-pressure-load-shedding.md) accepted в индексе (`9d578be`)
- [ADR-0020](docs/adr/0020-distribuciya-monorepo-kak-odin-jpm-bundle.md) — дистрибуция, монорепо как один jpm-bundle (proposed) (`b531dcb`)

## v0.1 — 2026-08-27

конец волны 1 — «можно строить HTMX-приложения, есть что показать»; контракты Plugin API и Route Metadata заморожены

### Добавлено

- test/inject — полный стек без сокета ([ADR-0017](docs/adr/0017-inject-testirovanie-polnogo-steka-bez-soketa.md)): with-http (:only kernel), cookie jar, :json/:form/:raw сахар, wire-байты в :raw, sse-events; guestbook smoke переведён на inject + проверку access-log (`4329268`)
- request lifecycle — именованные стадии ([ADR-0016](docs/adr/0016-request-lifecycle-imenovannye-stadii.md)): stage-слоты в цепочке, :void.http/hook точка + :void.http/hooks metadata (dict-concat в meta), :on-response/:on-error/:on-timeout вне цепочки, request-id + access-log через core/log, kernel/server split ([ADR-0017](docs/adr/0017-inject-testirovanie-polnogo-steka-bez-soketa.md)) (`a19e921`)
- void/core/log — structured logger в core ([ADR-0018](docs/adr/0018-structured-logger-v-core.md)): lazy level-макросы, ns-дерево уровней, dyn-контекст, pretty/jdn sinks c drop-политикой, serializers/redact, точки :void.core/log-sink и /log-serializer, wiring в plugin/start! (`d8fadea`)
- bench budgets gate (void bench budgets/--budgets), full wrk+wrk2 baseline, §8.2 verified — corrections recorded in docs/BENCH-v0.1.md (wave-1 exit 4) (`1e89e43`)
- HTMX guestbook — void new template + examples/guestbook smoke app; form string bounds use schema :min/:max (wave-1 exit 1) (`93d1555`)
- extension-point deprecation aliases (:aliases) + schema in plugin/inspect (SPEC II 1.5) (`d12fb09`)
- explain-route shows middleware chain, route source and merge warnings (wave-1 exit 3) (`758f738`)
- void dev + hot reload route rebuild — :void.dev/reloaded hook, live manifest re-read in http/rebuild! (wave-1 exit 1) (`4c70fbd`)
- impl bench-suite — void bench, B0/B1 apps, wrk/wrk2 методика, baseline + 5% пороги в CI, Go/FastAPI baselines (wave 1.7) (`7709962`)
- impl cli — void binary, commands as extension point, void new/routes/repl, subset start via :needs (wave 1.6) (`cc5d529`)
- impl rest + openapi — defresource, schema validation, problem+json, OpenAPI 3.1 projection (waves 1.4-1.5) (`df7287e`)
- impl html + htmx — hiccup pipeline, schema forms, assets, hx-helpers (waves 1.2-1.3) (`baa0498`)
- impl http — server, router, middleware, sessions, prefork (wave 1.1) (`5a87286`)
- close wave-0 exit criteria — demo plugin, CI, dry-run fixes (`8246529`)
- impl hooks + lifecycle and void/dev — ordered hooks, ev bus, run! with signals; netrepl, watcher, void/test (`185d95c`)
- impl plugin — manifests, extension points, bootstrap phases, dry-run; core/meta merge semantics (`7baf48d`)
- impl schema — types, composition, coercion, path errors, projections, registry (`95586b3`)
- impl config — layers, provenance, profiles, batch validation, secrets (`b403069`)
- impl systems (`d01fecf`)

### Производительность

- bench B* цели меряют ядро (access-log off), baseline на финальном стеке v0.1; цена access-log зафиксирована строкой в BENCH-v0.1.md (§8.5 п.4) (`0fac47e`)

### Документация

- контракты v1 финал — lifecycle-стадии и log-точки в CONTRACTS.md, ADR 0016-0018 accepted, exit-критерии волны 1 закрыты (`98ce3e7`)
- SPEC/ROADMAP — контракты lifecycle/log в части II, заморозка v1 (CONTRACTS/CONTRIBUTING), §8.2 после замеров, статусы волны 1 (`8e450a2`)
- ADR 0016-0019 (proposed) — lifecycle-стадии, inject-тесты, structured logger в core, pressure (`b5cc8e3`)
- freeze contracts v1 — generated CONTRACTS.md + drift-check in CI, CONTRIBUTING deprecation procedure + §8.5 rules (wave-1 exit 2) (`537e54a`)
- move SPEC into docs/, add ADRs 0001-0015 and ROADMAP (`199ea9a`)
