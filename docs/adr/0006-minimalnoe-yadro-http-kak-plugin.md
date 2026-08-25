# ADR-0006: Минимальное ядро — HTTP как plugin

- Статус: accepted
- Дата: 2026-08-25
- Связанные разделы SPEC: §2.5, §3, §5.1

## Контекст и постановка проблемы

Что входит в обязательную зависимость фреймворка? Web-фреймворки традиционно делают HTTP ядром (Rails, Laravel); но void обещает переиспользование механики (metadata, schema, components) для gRPC, Kafka, CLI и jobs — и нацелен в т.ч. на embedded-сценарии (Janet в C-хостах), где HTTP может быть не нужен вовсе.

## Драйверы решения

- Честность архитектуры: если plugin API достаточно мощный для «батареек», ядро само должно на нём стоять (dogfooding).
- Embedded / CLI / worker-only процессы без HTTP-зависимости.
- Малый вес: single binary < 5 MB — часть позиционирования.
- Контракты (route metadata, schema) должны жить ниже HTTP, чтобы работать для других протоколов.

## Рассмотренные варианты

1. **Core = system + config + schema + plugin + hooks; HTTP — первый и главный plugin.**
2. **HTTP в ядре** — проще для 90% пользователей, но контракты прирастают к HTTP, worker-only процессы тянут лишнее, plugin API не проверен на главном потребителе.

## Решение

Вариант 1. `void/core` — единственная обязательная зависимость: component system, config, schema layer, plugin API, hooks/events, lifecycle (`void/run!`). Не тянет HTTP, DB — ничего.

`void/http` — plugin (сложность L), владелец точек `:void.http/middleware`, `:void.http/session-store`, `:void.http/body-codec`, `:void.http/error-renderer`, `:void.http/route-source`. Метаданные-контракт (`void/core/meta`) — в core, http лишь один из потребителей.

`void/dev` — тоже plugin, но канонический (netrepl, file watcher, REPL-хелперы).

## Последствия

Плюсы:

- Plugin API проверяется самым требовательным потребителем с первого дня.
- Worker-процессы, CLI-утилиты, embedded-хосты собираются без HTTP.
- Границы контрактов чистые: metadata и schema переиспользуются gRPC/Kafka без слоёв адаптации.

Минусы / цена:

- Стартовый шаблон проекта обязан скрыть церемонию (`void new` подключает http+dev автоматически), иначе первый контакт с фреймворком хуже, чем у Rails.
- Версионирование core и http разъезжается — нужен `:requires` semver в manifests (уже есть в ADR-0003).
