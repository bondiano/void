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
| [0019](0019-pressure-load-shedding.md) | `void/pressure` — load shedding по образцу under-pressure | proposed |
