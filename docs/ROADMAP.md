# ROADMAP: void

> Дорожная карта. Волны 0–5 (SPEC §6) закрыты; их историю хранят [CHANGELOG.md](../CHANGELOG.md) — проекция git-истории, — теги v0.1–v0.4 и [ADR 0001–0038](adr/README.md). Прежняя редакция этого документа с почеклисточной историей волн живёт в git (до 2026-09-01). Здесь — только то, что впереди.

**Правило зависимостей:** каждый plugin зависит только от `void/core` и plugins своей волны или более ранних. Волна закрывается по exit-критериям, а не по «код написан».

**Dogfooding:** вся разработка ведётся через netrepl внутри системы; каждый новый plugin строится на предыдущих.

---

## Сделано (волны 0–5)

| Волна | Что | Тег |
|---|---|---|
| 0 — фундамент | core: system, config, schema, plugin, meta, hooks, log; dev/test: netrepl, watcher, fixtures, inject | — |
| 1 — вертикаль | http, html, htmx, rest, openapi, cli, bench B0/B1; контракты Plugin API + Route Metadata заморожены ([CONTRACTS.md](CONTRACTS.md)) | v0.1 |
| 2 — данные | db (+sqlite, +postgres), fdwait, redis, cache, jobs, pressure; дистрибуция одним jpm-bundle; bench B2/B3 | v0.2 |
| 3 — enterprise | obs, crypto, auth, authz, security, mail, bus (+outbox) | v0.3 |
| 4 — протоколы + admin | http/client, obs-otlp, proto, grpc (Connect unary), ws, mcp, auth-oauth, admin, `[:deploy :shape]`; bench B4 | v0.4 |
| 5 — тяжёлый FFI | kafka, db-mysql, oauth, i18n, datastar (эксперимент), tls (исходящий) | ADR-0033–0038 |

Решения, действующие на входе в волну 6 (2026-09-01):

- **Анонса нет, пока нет приложения.** v0.5 и публичный анонс отложены до конца волны 6: анонсировать фреймворк раньше, чем на нём собрано настоящее приложение, значит анонсировать гипотезу.
- **Калибровка абсолютных бюджетов на референс-окружении отменена.** CI держит относительные 5%-пороги (ADR-0014); абсолютные числа §8.2 остаются справочными гипотезами. `scripts/bench-reference.sh` сохраняется — прогнать можно в любой момент, когда появится потребитель абсолютных чисел.
- **datastar** — пометка «эксперимент» до первого приложения вне `examples/` (ADR-0037).

---

## Волна 6 — паритет и первое приложение

Тема волны: закрыть то, обо что настоящее приложение спотыкается в первую неделю, но чего нет на фоне Laravel/Rails/Phoenix, — и собрать это приложение. Метрика — §9 дословно: время «идея → работающий деплой» и доля вертикали без выхода из стека. Каждый пакет — свой ADR; порядок внутри волны — по тому, что попросит приложение.

### 6.1 `void/storage` — файлы и загрузки *(L; [ADR-0039](adr/0039-hranilishe-fajlov-klyuch-kak-dannye.md))* ✅

Паритет: Laravel Storage / Rails ActiveStorage. Между multipart-парсингом и URL на странице теперь один шов, и он один и тот же для формы, admin и контроллера.

- [x] Контракт `:void/storage-store`: `put!`/`get`/`stream`/`delete!`/`url`; ключ и метаданные — данные
- [x] `:local`-store — диск (запись через tmp+rename), отдача через существующий static (etag/range) в `void/storage-http`
- [x] `:s3`-store — S3-совместимый API своим стеком: `http/client` + `void/tls` + SigV4 на `void/crypto`, проверенный на опубликованных векторах AWS
- [x] Signed/temporary URL — локально на ключах `void/security` (с ротацией), в bucket — SigV4 query auth
- [x] Шов с формами и admin: тип схемы `:file` + аннотации `:storage/*` → `input type=file` и `enctype` в `void/html`, виджет с превью и серверной проверкой в `void/storage-admin`
- [x] `:local`-store под `[:deploy :shape] :fleet` — та же проверка на старте, что у всех per-process хранилищ (ADR-0030)
- [x] `examples/shop`: картинка товара — одна строка в `defentity`, minio в `docker-compose.yml`

### 6.2 `void make auth` — auth-скаффолд *(M)* ✅

Паритет: phx.gen.auth / Laravel Breeze / Rails 8 authentication generator. Машинерия есть вся (`auth/password`, identity, strategies, `challenge!` + `mail-auth`, sessions) — но каждое приложение руками писало одни и те же страницы. Теперь пишет генератор, и reset с verify — один поток: `challenge!` + один redeem-роут, потому что доставщик строит один URL.

- [x] Генератор по образцу `make resource`: register/login/logout, reset и verify через `challenge!`; шаблоны — данные с проектными overrides (`templates/auth/<key>.janet`)
- [x] Сгенерированная сюита тестов через `test/inject` — со своим `:void.auth/deliver`, так что оба challenge проверяются без почтового ящика
- [x] Примеры не переписываются: скаффолд проверяется тем, что сам генерирует (`cli/test/make-auth-test.janet` гоняет сгенерированную сюиту на sqlite)

### 6.3 Jobs-дашборд *(S/M)* ✅

Паритет: Horizon / Sidekiq-web. `void/admin-jobs` был только раннером bulk-действий; теперь тот же plugin держит оба конца шва «админка × очередь» — зависимости у них одни и те же, а смотреть на очереди стало где. Не `defresource-admin`: очередь — не entity, у неё нет ни таблицы, ни pk, ни схемы, которую можно спроецировать, поэтому секция собрана из `:void.admin/page` поверх самого контракта.

- [x] Секция поверх `:void/jobs-backend` (восьми существующих функций хватило): карточки бэкенда и бэклога, таблица «очередь × состояние» со ссылками прямо в фильтр, листинг одного фильтра, одна запись целиком с её failures
- [x] Retry/discard для dead — обычные admin-действия под обычными политиками (`:admin.jobs/retry`, `:admin.jobs/discard`): сузить их — это `defpolicy` с этим именем и больше ничего, как у action'а ресурса
- [x] Ничего нового в контракте backend'а: `counts`, `list`, `fetch`, `retry!`, `remove!`, `clear!` — и границы оттуда же. Листинг по `:limit`, а не по страницам, потому что offset'а в контракте нет; bulk только по queue+state, потому что этой парой говорят `counts` и `clear!`; retry только для dead, потому что `revive!` не снимает claim и оживление записи, которую держит воркер, выполнит её дважды
- [x] `:void.admin/menu` научился `:path` (аддитивно — старые contribution'ы валидны): contribution — значение, замороженное на загрузке, а `[:admin :prefix]` — конфиг, так что plugin со своей страницей иначе не может назвать ссылку на себя

### 6.4 `void/notify` — единые нотификации *(M; [ADR-0040](adr/0040-notifikacii-odno-sobytie-neskolko-kanalov.md))* ✅

Паритет: Laravel Notifications; позиционирование §9 прямо называет «webhook/бот-хабы». Одно событие — один вызов; куда оно уйдёт, решает список плагинов. У канала не одна функция, а две — `project` там, где был запрос, `deliver` там, где сеть, — и ровно поэтому между ними помещается очередь, а повтор доставляет то же самое значение.

- [x] Точка `:void.notify/channel` по образцу `:void.mail/transport`; `:memory` и `:log` в ядре, mail-канал (`void/notify-mail`) из коробки — письмо строит `void/mail` и оно же его маршрутизирует через `mail/send-delivery`, так что `[:mail :queue]` продолжает значить то, что значило
- [x] `:webhook`-канал на `http/client`: тело — проекция уведомления, подпись `t=<unix>,v1=<hmac>` считается на доставке (schema Stripe), 4xx записывается, 5xx повторяется; telegram и прочие — приложением или пакетом по спросу
- [x] In-app канал: строка в таблице, которой владеет void (DDL данными — `(notify-store/tables)` в миграции), и htmx-колокольчик с четырьмя обычными маршрутами; получатель — личность из dyn, никогда не параметр
- [x] Отправка через `void/jobs` тем же приёмом, что `mail-jobs`, — ни одно место вызова не меняется; задача **на канал**, потому что упавший webhook не должен отправить письмо второй раз
- [x] В `:prod` композиция, у которой не осталось доставляющего канала, — ошибка старта: тот же отказ, что у `[:mail :transport]`

### 6.5 Assets: tailwind без node *(S)*

Паритет: Phoenix (standalone esbuild/tailwind). `assets/build!` умеет только fingerprint+manifest.

- [ ] Standalone tailwind CLI: обнаружение/скачивание бинаря, watcher в `void dev`, шаг в `assets/build!`
- [ ] Node в пути пользователя не появляется; отсутствие бинаря — понятная ошибка, а не тишина

### 6.6 Первое приложение вне `examples/`

- [ ] Настоящее работающее приложение, бьющее минимум по 6.1–6.3: загрузки, регистрация, фоновые задачи
- [ ] Всё, что потребовало выхода из стека или объяснения словами, возвращается в волну задачей
- [ ] По его итогам — решение по пометке «эксперимент» у datastar (ADR-0037)

### Exit-критерии волны 6

1. Приложение 6.6 собрано и задеплоено без выхода из стека; путь «идея → деплой» записан по шагам.
2. Каждый новый пакет проходит Definition of Done; контракты v1 не тронуты — максимум новые точки/ключи по additive-правилам ([CONTRIBUTING](../CONTRIBUTING.md#deprecation)).
3. Решение по datastar принято на реальной выборке, а не нулевой.

---

## Волна 7 — релиз v0.5 и анонс *(заморожена до конца волны 6)*

- [ ] Санитарный проход «чистая машина»: `jpm install` без checkout'а → `void new` → `void dev`; `docker compose up` каждого примера с Dockerfile (локальная половина пройдена 2026-09-01)
- [ ] Тег v0.5 → регенерация [CHANGELOG.md](../CHANGELOG.md) (`scripts/gen-changelog.janet`)
- [ ] Публичный анонс. Метрика успеха — §9: время «идея → деплой», полнота вертикали, стабильность двух замороженных контрактов — не adoption

---

## Отложенное с именем (по потребности, каждое — свой ADR)

Не обещания, а закладки с уже названными границами:

- gRPC streaming через HTTP/2 *(XL)* — SPEC §1 держит его в v2; ADR-0013 выбрал Connect именно потому, что unary покрывает нишу
- redis Cluster/Sentinel — «другой клиент»: MOVED/ASK-редиректы и слежение за топологией
- mTLS, ALPN, session resumption в `void/tls` — названные не-цели ADR-0038 §5; ALPN придёт вместе с HTTP/2, если придёт HTTP/2
- Full-text search — Postgres FTS + sqlite FTS5 за одним контрактом; аналог Scout по спросу
- Presence («кто онлайн» поверх ws rooms + bus) — по первому реальному потребителю
- Inbound email (аналог ActionMailbox) — если попросят бот-хабы §9
- Калибровка на референс-окружении — `scripts/bench-reference.sh` готов; вернётся, когда появится потребитель абсолютных чисел §8.2

---

## Сквозные работы

| Работа | Статус |
|---|---|
| CI: `jpm test` всех пакетов + `plugin/dry-run` + относительные bench-пороги | идёт с волны 0 |
| Docs-сайт (`scripts/gen-site.janet` → GitHub Pages) — проекция репозитория, руками не написана ни одна страница | ✅ поддерживается |
| CHANGELOG — проекция git-истории (`scripts/gen-changelog.janet`), регенерация на релизе | ✅ поддерживается |
| Примеры-приложения — по одному на волну, они же smoke-тесты | идёт |

---

## Definition of Done (для любого plugin)

1. Manifest проходит `plugin/dry-run`; удаление из `:plugins` не оставляет следов.
2. Config-schema + тесты на ошибочные конфиги; секреты не печатаются.
3. REPL-инспектируемость: `plugin/inspect` показывает все contributions.
4. Тесты: unit + интеграционный через `void/test`-fixtures; для middleware — строка в bench-таблице («B1 с моим middleware = −X%», §8.5).
5. Docs: README plugin'а + декларации metadata-ключей/extension points (авто-докгенерация).
6. Никаких блокирующих вызовов на ev loop (правило §8.5 п. 1).
