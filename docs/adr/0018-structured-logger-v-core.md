# ADR-0018: Structured logger — ядро логов в `void/core/log`

- Статус: proposed
- Дата: 2026-08-26
- Связанные разделы SPEC: §3.7 (новый), §5.13
- Референс: [Fastify Logging](https://fastify.dev/docs/latest/Reference/Logging/) / pino

## Контекст и постановка проблемы

SPEC относил логи целиком к `void/obs` (волна 3). Но логгер нужен всем и сразу: http хочет access-log и warnings с волны 1, bootstrap ядра — сообщать о deprecated-конфигах, приложения v0.1 не могут жить на `print`. Fastify встраивает pino в ядро именно поэтому — логирование не observability-фича, а базовый примитив. Паритет с pino означает конкретные свойства: structured-записи, почти бесплатный выключенный уровень, child-logger с привязанным контекстом (per-request logger с request-id), serializers, redaction, pretty в dev и JSON в prod, запись вне горячего пути.

## Драйверы решения

- Приложения v0.1 должны иметь production-логи, не дожидаясь волны 3.
- Запись не должна блокировать ev loop (правило §8.5 п. 1); выключенный уровень — одна проверка, без вычисления аргументов.
- Секреты не утекают: у config уже есть secret-механика с custom print (0.2) — логгер обязан её уважать и дополнять redaction-путями.
- REPL-управляемость: смена уровней per-namespace в рантайме (SPEC §5.13 это уже обещал).
- Контекст per-fiber бесплатен через dyn — «child logger» Fastify у нас — bound context, а не объект.

## Рассмотренные варианты

1. **`void/core/log` — минимальное ядро логов в core**; `void/obs` (волна 3) сужается до metrics/tracing/экспорта и добавляет логам trace-корреляцию и OTLP-sink.
2. **Отдельный plugin `void/log`** — но core сам хочет логировать (bootstrap, dry-run warnings): цикл «ядро зависит от plugin'а» ломает ADR-0006.
3. **Ждать `void/obs`** — v0.1 выходит без логов; access-log пришлось бы городить ad-hoc в http и потом выбрасывать.

## Решение

Вариант 1 — `void/core/log`, паритет по свойствам pino, идиоматика — данные:

- **Record = plain table**: `{:ts :level :ns :msg ...kv}` плюс bound context. Никаких format-строк на горячем пути — kv-пары; форматирование — забота sink'а.
- **API — макросы**: `(log/info "cache miss" :key k :ttl ttl)` — аргументы **не вычисляются**, если уровень для namespace выключен (pino-паритет: выключенный уровень = одна проверка). `:ns` — по умолчанию из `(dyn :current-file)`/модуля.
- **Уровни** `:trace :debug :info :warn :error :fatal`; минимум per-namespace (префиксное дерево: `:my-app.orders` наследует от `:my-app`), смена в рантайме — `(log/set-level! "my-app.orders" :debug)` из REPL/CLI.
- **Контекст** — dyn: `(log/with-context {:request-id id} ...)` добавляет kv ко всем записям внутри (аналог child logger, per-fiber — изоляция бесплатно). Для задач `ev/go` контекст переносится явным хелпером; http-сервер, исполняющий handler в отдельной task (ADR-0015 п. 2), переносит его сам.
- **Sinks** — extension point `:void.core/log-sink` (many): dev — pretty/цветной stderr синхронно; prod — JSON/JDN-lines через буферизованный ev-канал + writer-fiber (запись вне request-fiber'ов; переполнение буфера → drop с счётчиком dropped — логи не имеют права валить сервис; `:fatal` — синхронный flush). Механика канал+fiber уже отработана в hooks-шине (0.5).
- **Serializers** — extension point `:void.core/log-serializer`: по ключу (`:err` → `{:msg :stacktrace}`, `:req` → `{:method :path :request-id}`); плюс `:redact`-список путей в конфиге поверх secret-печати config.
- **Интеграция с http** (dogfooding ADR-0016): middleware фазы `:observability` генерирует request-id и кладёт его в log-context; access-log пишется на стадии `:on-response` — честная длительность до последнего байта.
- **`void/obs` (волна 3)** добавляет: trace-id/span-id в log-context, sampling, OTLP log-sink и файловые экспортёры. Из скоупа obs логовое ядро уходит.

Перф-контракт: включённый access-log на B1 — предмет строки в bench-таблице (§8.5 п. 4); целевой overhead фиксируется при реализации и защищается порогами ADR-0014.

## Последствия

Плюсы:

- v0.1 — с production-логами и access-log из коробки; obs-волна разгружается (самый рискованный по объёму пункт ROADMAP).
- Один контракт записи для всего стека: jobs/db/bus в волнах 2–3 логируют через готовое ядро, инструментация obs ложится сверху.
- Секреты защищены на уровне механизма, а не дисциплины.

Минусы / цена:

- Core растёт (record + levels + context + sink-контракт + pretty-принтер); принимаем: это примитив уровня schema/config, а не «фича».
- Асинхронный писатель — ещё один долгоживущий fiber и явная политика потерь (drop + счётчик) — должна быть видна в health/метриках.
- Два формата вывода (pretty/JDN/JSON) — снапшот-тесты форматтера, чтобы не разъезжались.
