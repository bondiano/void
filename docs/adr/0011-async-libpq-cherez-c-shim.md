# ADR-0011: Postgres-драйвер — async libpq на ev loop через C-shim, без thread pool

- Статус: accepted (подтверждено прототипом)
- Дата: 2026-08-25
- Связанные разделы SPEC: §5.10, §7 п.2, Приложение A

## Контекст и постановка проблемы

Postgres — главная production-БД фреймворка. Блокирующие вызовы libpq на ev loop останавливают весь воркер (см. ADR-0010). Вопрос: можно ли гонять libpq в non-blocking режиме на fibers, не блокируя loop и без thread pool? Из чистого Janet нельзя ждать readiness произвольного fd — в `ev/` такого примитива нет.

## Драйверы решения

- Ни одного блокирующего syscall на loop — жёсткое правило ADR-0010.
- Конкурентные запросы к PG из одного OS-потока (паритет с node-postgres по модели).
- Минимум C-кода: C — только там, где Janet физически не может.
- Риск снять до того, как закладываться в архитектуру волны 2 (открытый вопрос №2 SPEC).

## Рассмотренные варианты

1. **Non-blocking libpq (`PQsendQuery`/`PQconsumeInput`) + микро-shim на C (~60 строк), дающий «усыпи fiber до readiness fd»; остальной драйвер — чистый `ffi/`.**
2. **`ev/thread` pool с блокирующим libpq** — работает без C-кода, но дороже (потоки, копирование через channels) и не масштабируется по соединениям. Остаётся документированным fallback.
3. **Postgres wire protocol на чистом Janet** (как для Redis) — исключает libpq вовсе, но протокол сильно сложнее RESP (auth-методы, TLS, COPY, типы) — неоправданный объём работы при живом libpq.

## Решение

Вариант 1 — **осуществимость подтверждена прототипом** (Janet 1.41.3-dev + libpq 16): 3 × `pg_sleep(1)` конкурентно на одном OS-потоке за 1.00s; loop свободен (ticker 10/10); ровно 1 readiness-wait на запрос, без busy-spin.

Архитектура:

- **Shim `pqwait`** (native module, ~60 строк C): `(pqwait/watch fd :read|:write)` — `dup(fd)` + `janet_stream` с одним флагом направления; `(pqwait/wait watcher)` — `janet_async_start`, callback планирует fiber обратно. Ключевые детали (из исходников ev.c): epoll-регистрация идёт по `stream->flags`, поэтому нужны направление-специфичные обёртки; `dup(fd)` избегает EEXIST при двойной регистрации; `janet_async_start` — последний вызов cfunction; `PQsocket` может меняться во время connect.
- **Драйвер — чистый Janet + `ffi/defbind`** (~18 функций libpq): connect через `PQconnectStart`/`PQconnectPoll`-loop, query через `PQsendQuery` → `PQflush` → `PQisBusy`/`PQconsumeInput`, `PQsetnonblocking`.
- Shim обобщается в **`void/fdwait`** — общий примитив «readiness на чужом fd» для любых FFI-библиотек с неблокирующим API (пригодится librdkafka).
- Дорога до production-драйвера: `PQsendQueryParams`, pipeline mode (PG14+), NOTIFY, cancel, row-mode для стриминга; TLS делает сам libpq — бесплатно.

## Последствия

Плюсы:

- Thread pool не нужен; модель конкурентности единая по всему фреймворку.
- Оценка сложности `void/db-postgres` = M подтверждена, главный платформенный риск волны 2 снят.
- `void/fdwait` — переиспользуемый примитив для будущих FFI-интеграций.

Минусы / цена:

- Появляется native-компонент → сборка требует C-компилятора и заголовков libpq (нарушает «чистый jpm install» для этого plugin; смягчить prebuilt-артефактами).
- Shim опирается на нестабильное C API janet (`janet_async_start`) — следить за изменениями между версиями Janet.
- Известная ловушка ffi: `(native ...)` возвращает binding tables, а не функции — задокументирована в Приложении A, чтобы не терять на ней время повторно.
