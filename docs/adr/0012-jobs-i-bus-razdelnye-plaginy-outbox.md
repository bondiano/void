# ADR-0012: jobs и bus — раздельные plugins; transactional outbox как first-class паттерн

- Статус: accepted
- Дата: 2026-08-25
- Связанные разделы SPEC: §3.5, §5.12, §5.22

## Контекст и постановка проблемы

«Фоновая обработка» скрывает две разные семантики: task queue («сделай задачу и подтверди» — retries, приоритеты, DLQ, flows) и messaging («событие произошло» — pub/sub, fan-out, стримы, гарантии доставки). Фреймворки часто сваливают их в одно (Sidekiq для всего) — и получают либо кривой event bus на очередях, либо кривые очереди на Kafka. Отдельный вопрос — консистентность «запись в БД + публикация события» для доменов с деньгами.

## Драйверы решения

- Разные контракты не должны склеиваться: у task queue — семантика подтверждения и ретраев конкретной задачи; у messaging — семантика доставки подписчикам с гарантиями backend'а.
- Атомарность «изменение состояния + событие» — обязательна для money-доменов (ставки, балансы).
- In-process интеграционные события (audit слушает `:user/created`) — третья, самая лёгкая семантика, ей не нужна инфраструктура вообще.

## Рассмотренные варианты

1. **Три слоя: `void/core/hooks` (in-process pub/sub), `void/jobs` (task queue, BullMQ-паритет), `void/bus` (messaging в духе Watermill) + transactional outbox в bus.**
2. **Один «универсальный» слой сообщений** — каждая семантика получает чужие компромиссы; Flows и rate-limiting per queue не выражаются в pub/sub терминах, и наоборот.
3. **Только jobs, события поверх них** (Rails/ActiveJob-путь) — fan-out и at-least-once со стримами не ложатся на модель «одна задача — один исполнитель».

## Решение

Вариант 1.

- **`void/core/hooks`** — синхронные lifecycle-хуки + внутрипроцессная ev-шина для application events. Не персистентна, не покидает процесс.
- **`void/jobs`** — task queue: spork/tasker как executor, persistence через `:void.jobs/backend` (db — polling + SKIP LOCKED; redis — streams). `defjob` (символы → hot reload, ADR-0002), retries с backoff+jitter, приоритеты, delayed, unique, DLQ, Flows (parent-child DAG), rate limiting per queue, repeatable через spork/cron с backend-lock.
- **`void/bus`** — messaging: message = plain table, router с middleware-цепочкой (те же фазовые константы, что в HTTP), backends как extension point (`:memory`, `:pg` LISTEN/NOTIFY, `:redis` streams, `:kafka`). Backend декларирует свои гарантии (`:at-most-once`/`:at-least-once`), router их учитывает. Опциональный CQRS-слой (command bus / event bus).
- **Transactional outbox — first-class в bus**: `(bus/publish-tx tx topic msg)` пишет событие в ту же транзакцию через void/db; forwarder-компонент публикует и помечает. Это единственный санкционированный способ «событие о изменении денег» — прямая публикация из транзакции запрещена конвенцией.
- Связи слоёв: jobs публикует свои lifecycle events (`:completed`, `:failed`) в bus при его наличии; entity-события (вместо AR-callbacks, см. ADR-0009) идут через outbox.

## Последствия

Плюсы:

- Каждый слой имеет честный, узкий контракт; выбор между ними — по семантике, документируется таблицей «когда что».
- Outbox закрывает консистентность денег/ставок архитектурно, а не дисциплиной.
- Монолит начинает с `:memory`/`:pg` backend'ов и мигрирует на Kafka сменой конфига, не кода.

Минусы / цена:

- Три механизма событий — нужна ясная навигационная документация, иначе пользователи будут делать jobs там, где нужен bus.
- Forwarder-компонент outbox — ещё одна движущаяся часть (лаг доставки, мониторинг отставания через void/obs).
- Полный BullMQ-паритет (Flows, rate limiting, groups) — M/L объём; режется по волнам, но контракт `defjob` фиксируется сразу.
