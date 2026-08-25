# ADR-0013: gRPC-совместимость через Connect protocol на HTTP/1.1; protobuf — pure-Janet

- Статус: accepted
- Дата: 2026-08-25
- Связанные разделы SPEC: §1 (ограничение №1), §5.7, §5.8

## Контекст и постановка проблемы

Enterprise-паритет требует какой-то формы gRPC-совместимости, но классический gRPC требует HTTP/2 (trailers, мультиплексирование), которого в Janet нет и реализация которого — XL-работа с сомнительной окупаемостью для интерпретатора. Также нужен protobuf-рантайм — и он же нужен OTLP-экспорту в void/obs.

## Драйверы решения

- Совместимость с gRPC-экосистемой (генераторы клиентов, buf, инструменты) без HTTP/2.
- Переиспользование существующего HTTP-стека (middleware, route metadata, authz — всё работает на RPC-методах).
- Один protobuf-фундамент на grpc и otel.
- Честность: не обещать streaming, пока нет транспорта под него.

## Рассмотренные варианты

1. **Connect protocol (unary) поверх void/http (HTTP/1.1)** + pure-Janet protobuf.
2. **Полный gRPC + собственный HTTP/2** — XL, блокирует всё остальное, выгода мала для целевой ниши.
3. **gRPC через внешний transcoding-proxy** (Envoy) — работает, но ломает «single binary» и уводит контракт из фреймворка.
4. **Не делать RPC вовсе, только REST** — теряется protobuf-экосистема и типизированные клиенты; при этом protobuf-рантайм всё равно нужен для OTLP.

## Решение

Вариант 1, двумя plugins:

- **`void/proto`** (пишется первым из этой ветки): pure-Janet кодек — varint, wire types, encode/decode по descriptor; `.proto`-parser на PEG → описания schema layer → codegen-макросы. Общий фундамент для grpc и otel. Varint-ядро — кандидат на C по бюджетам §8 (hot path).
- **`void/grpc`**: Connect protocol поверх void/http — unary RPC на HTTP/1.1, JSON и protobuf кодеки; совместимость с gRPC-экосистемой через transcoding. `defservice` из `.proto` → handlers со schema-валидацией. RPC-методы несут ту же meta-map, что HTTP routes (`:void.authz/policy` работает одинаково) — по ADR-0005.
- **Streaming — v2**, отдельное решение (XL): потребует HTTP/2 или иного транспорта; сознательно не обещаем в v1.

## Последствия

Плюсы:

- gRPC-клиенты и tooling работают против void-сервиса уже в v1, без HTTP/2.
- Один стек политик (auth/authz/obs/validation) на HTTP и RPC.
- protobuf-инвестиция окупается дважды (grpc + OTLP).

Минусы / цена:

- Нет server/client streaming — анти-кейс фиксируется в README; домены, живущие на стримах, не наша ниша в v1.
- Connect-протокол менее известен, чем «настоящий» gRPC — потребуется явная страница «что поддерживается».
- Pure-Janet protobuf на больших payload может упереться в CPU — бенчмарк-строчка в суите обязательна (правило §8.5).
