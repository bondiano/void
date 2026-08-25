# ADR-0009: Entity layer — Data Mapper + тонкий AR через table prototypes

- Статус: accepted
- Дата: 2026-08-25
- Связанные разделы SPEC: §5.9

## Контекст и постановка проблемы

Нужен слой работы с БД удобнее сырого SQL, но без классических болезней ORM: скрытые запросы (N+1), мутационная магия, lifecycle-callbacks как источник неотлаживаемого поведения, Unit of Work со скрытым flush. При этом Laravel-паритет требует и удобства Active Record (навигация по связям, `save!`).

## Драйверы решения

- Entities должны оставаться plain data: `pp` работает, данные проходят через schema-проекции, копируются, сериализуются.
- Явность вместо магии: границы транзакций, загрузка связей, изменения — видимы в коде.
- Один источник правды для admin, миграций, ER-диаграмм (см. ADR-0008).
- Hot path без сюрпризов: никакие обращения к полям не порождают запросов.

## Рассмотренные варианты

1. **Data Mapper — ядро; тонкий AR — сахар через table prototypes Janet.**
2. **Полный Active Record** (Rails/Laravel) — удобен, но тянет callbacks, lazy loading, мутационную магию — главные источники боли, перечисленные в SPEC как анти-цели.
3. **Только Data Mapper / сырой query builder** (Ecto без changeset-магии, honeysql) — чисто, но теряется дешёвая навигация по связям и `save!`-удобство, ради которых люди выбирают Laravel.
4. **Unit of Work** (Hibernate-style session) — отвергнут явно: скрытый flush и неявные границы противоречат принципу явности.

## Решение

Вариант 1. Ядро — **Data Mapper**: mappers генерируются из `defentity`-деклараций (= defschema + db-mapping, см. ADR-0008), entities — plain data. Repository API: `db/find`, `db/query` (с явным `:preload` — batched IN-запрос), `db/insert!`, `db/update!`, `db/delete!`.

**AR — тонкий слой поверх, через table prototypes**: инстанс — обычная table, её proto несёт ссылку на entity descriptor и snapshot загруженного состояния. Никаких классов.

Принципиальные запреты и механики:

- **N+1 запрещён по умолчанию**: `(db/rel u :brand)` вне `:preload` в dev — warning с местом вызова, в `:strict` — ошибка. Ленивой загрузки в циклах нет.
- **Dirty tracking без мутаций**: `save!` диффит table против snapshot в proto → partial UPDATE изменённых колонок. Обновления — обычные `put`/`merge`. Optimistic locking через `:db/version` — опционально.
- **Callbacks/lifecycle-hooks на entity — НЕТ.** Сквозные вещи (audit, domain events) — через outbox `void/bus` и db-middleware.
- **Никакого Unit of Work**: границы — явные `(db/with-tx ...)` (dyn-scoped); `save!`/`insert!` участвуют в текущей транзакции из dyn.
- Identity map — опционально, per-request через dyn, выключен по умолчанию.
- `:db/rels` + `:db/fk` — единый источник для preload-планировщика, admin-виджетов, migrations-diff, `void db erd`.

## Последствия

Плюсы:

- Entities инспектируемы и остаются данными на всём пути (совместимо с ADR-0004).
- Класс N+1-регрессий ловится в dev, а не в проде под нагрузкой.
- Отсутствие callbacks делает поведение записи локально читаемым; аудит и события уходят в явный outbox (ADR-0012).

Минусы / цена:

- Порог для людей из Rails/Laravel: «почему `db/rel` кинул ошибку» — нужна хорошая диагностика с подсказкой `:preload`.
- Snapshot в proto удваивает память загруженной entity — приемлемо для профиля «короткие запросы», но надо помнить в bulk-обработке.
- Домены, реально нуждающиеся в UoW-семантике, должны строить её сами поверх `with-tx` — сознательный отказ.
