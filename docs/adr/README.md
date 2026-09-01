# Architecture Decision Records

ADR фиксируют архитектурные решения проекта void. Формат — [MADR](https://adr.github.io/madr/): контекст → драйверы → рассмотренные варианты → решение → последствия. Источник большинства решений — [SPEC.md](../SPEC.md); ADR ссылаются на его разделы.

Новый ADR: следующий номер, kebab-case имя файла, статус `proposed` до принятия. Отмена решения — новый ADR со ссылкой, старый получает статус `superseded by ADR-NNNN`.

## Индекс

| № | Решение | Статус |
|---|---|---|
| [0001](0001-system-map-vmesto-di-kontejnera.md) | System map компонентов вместо DI-контейнера | accepted |
| [0002](0002-late-binding-cherez-simvoly.md) | Late binding через символы для handlers, jobs и policies | accepted |
| [0003](0003-plugin-api-manifest-i-extension-points.md) | Plugin API — явный manifest + extension points вместо classpath-скана | accepted |
| [0004](0004-data-first-dsl-kak-sahar.md) | Data first — DSL-макросы только как сахар над данными | accepted |
| [0005](0005-route-metadata-otkrytyj-kontrakt.md) | Route metadata — открытая namespaced-map как интеграционный контракт | accepted |
| [0006](0006-minimalnoe-yadro-http-kak-plugin.md) | Минимальное ядро — HTTP как plugin | accepted |
| [0007](0007-config-sloi-provenance-fail-fast.md) | Config — слои с provenance, schema-валидация до старта | accepted |
| [0008](0008-schema-layer-single-source-of-truth.md) | Schema layer — один формат, много проекций; db-аннотации опциональны | accepted |
| [0009](0009-entity-layer-data-mapper-plus-ar.md) | Entity layer — Data Mapper + тонкий AR через table prototypes | accepted |
| [0010](0010-concurrency-ev-loop-prefork-tls-vne-yadra.md) | Concurrency — ev loop + prefork; TLS вне ядра | accepted |
| [0011](0011-async-libpq-cherez-c-shim.md) | Postgres — async libpq на ev loop через C-shim, без thread pool | accepted |
| [0012](0012-jobs-i-bus-razdelnye-plaginy-outbox.md) | jobs и bus — раздельные plugins; transactional outbox | accepted |
| [0013](0013-grpc-cherez-connect-protocol.md) | gRPC через Connect protocol на HTTP/1.1; protobuf — pure-Janet | accepted |
| [0014](0014-performance-byudzhety-kak-ci-kontrakt.md) | Performance-бюджеты как CI-контракт; bench-suite в репозитории | accepted |
| [0015](0015-svoj-http-server-spork-kak-referens.md) | Свой HTTP-сервер; spork/http — референс и донор парсеров | accepted |
| [0016](0016-request-lifecycle-imenovannye-stadii.md) | Request lifecycle — именованные стадии как публичный контракт | accepted |
| [0017](0017-inject-testirovanie-polnogo-steka-bez-soketa.md) | Тестирование через inject — полный стек без сокета | accepted |
| [0018](0018-structured-logger-v-core.md) | Structured logger — ядро логов в `void/core/log` | accepted |
| [0019](0019-pressure-load-shedding.md) | `void/pressure` — load shedding по образцу under-pressure | accepted |
| [0020](0020-distribuciya-monorepo-kak-odin-jpm-bundle.md) | Дистрибуция — монорепо как один jpm-bundle, граф пакетов как данные | accepted |
| [0021](0021-obs-metriki-spany-i-cena-instrumentacii.md) | `void/obs` — модель метрик, спан по требованию и цена инструментации | accepted |
| [0022](0022-kriptografiya-cherez-libcrypto.md) | `void/crypto` — вся криптография одной системной библиотекой, с отказом на старте | accepted |
| [0023](0023-auth-identity-i-strategii.md) | `void/auth` — identity как данные, стратегии как точка расширения | accepted |
| [0024](0024-authz-abac-kak-dannye.md) | `void/authz` — ABAC: политика как чистая функция, решение как значение | accepted |
| [0025](0025-security-csrf-zagolovki-limity.md) | `void/security` — CSRF по кукиным полномочиям, заголовки на краю, лимиты поверх контракта кэша | accepted |
| [0026](0026-mail-soobshenie-kak-dannye-dostavka-kak-kompoziciya.md) | `void/mail` — сообщение как данные, доставка как решение композиции | accepted |
| [0027](0027-otlp-eksport-json-i-http-klient.md) | OTLP-экспорт — JSON до `void/proto`, HTTP-клиент как часть ядра | accepted |
| [0028](0028-websocket-kak-marshrut-perehvat-soedineniya.md) | WebSocket — это маршрут; ядро отдаёт соединение, комнаты остаются в процессе | accepted |
| [0029](0029-admin-kak-proekciya-deklaracij.md) | `void/admin` — декларация как значение, действие как маршрут, ворота закрыты по умолчанию | accepted |
| [0030](0030-forma-razvertyvaniya-i-razdelyaemye-hranilisha.md) | Форма развёртывания как ключ конфигурации; ни одного in-memory хранилища за пределами одного процесса | accepted |
| [0031](0031-mcp-kak-proekciya-i-vorota-po-umolchaniyu.md) | `void/mcp` — проекция того, что композиция уже объявила; read-only как структурное умолчание | accepted |
| [0032](0032-resource-server-a-ne-oauth-klient.md) | OAuth — сначала resource server, а не клиент; аудитория токена обязательна | accepted |
| [0033](0033-mysql-potok-na-soedinenie-i-tekstovyj-protokol.md) | MySQL — поток на соединение вместо ev loop; текстовый протокол вместо `mysql_stmt_*` | accepted |
| [0034](0034-oauth-klient-code-pkce-sessiya-kak-pending.md) | `void/oauth` — клиент code+PKCE; сессия вместо нового хранилища; identity отдаёт приложение | accepted |
| [0035](0035-kafka-event-api-fd-ot-biblioteki-publish-zhdyot-podtverzhdeniya.md) | Kafka — event API вместо callbacks, fd от библиотеки вместо потоков; `publish!` ждёт подтверждения | accepted |
| [0036](0036-i18n-slovar-kak-vklad-locale-kak-dyn-oshibki-perevodyatsya-sami.md) | `void/i18n` — словарь как вклад с `:precedence`, locale как dyn; schema-ошибки переводятся через шов ADR-0008 | accepted |
| [0037](0037-datastar-stranica-kak-otvet-morph-cherez-sse.md) | `void/datastar` — страница как ответ: morph `<title>`+`<body>` через SSE; middleware мельче рендера | accepted (experimental) |
| [0038](0038-tls-ishodyashij-cherez-libssl-memory-bio.md) | `void/tls` — исходящий TLS через libssl и memory-BIO; шов вместо ребра; входящий остаётся у прокси | accepted |
