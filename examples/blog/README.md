# blog

A [void](https://github.com/bondiano/void) application — the wave-2
demo: CRUD over `void/db`, with migrations, a background job and a
cache, on **Postgres or sqlite, chosen by config**.

    void db migrate     # create the schema
    void dev            # run the app (dev profile: watcher + netrepl)
    void routes         # print the route table
    void db erd         # the ER diagram, from the same declarations
    void jobs stats     # what the queue is holding
    void repl           # repl into the running process

Switching engines is one environment variable and the connection
slice in `config/<profile>.janet`:

    VOID_BLOG_DB=postgres void db migrate
    VOID_BLOG_DB=postgres void dev

Nothing else moves. `main.janet` is the only file that names a driver;
the entities, the migrations, the handlers, the job and the cache are
byte-for-byte the same on both — and `test/crud-test.janet` runs the
whole suite twice, once per engine, so the claim stays true.

## What is where

| File | What it shows |
|---|---|
| `entities.janet` | `defentity` — one declaration feeding validation, the repository, `:preload` and `void db erd`; form DTOs projected off it with `schema/select`/`schema/merge` |
| `db/migrations/` | migrations as janet files, one transaction each, `up`/`down`; self-contained by design — they never import the entities |
| `app.janet` | routes and handlers: `:void.db/txn` for transactions, explicit `:preload`, `cache/remember`, `jobs/enqueue` |
| `jobs.janet` | `defjob` with retries and `:unique :args`, plus a `defschedule` — the denormalized comment counter is kept true by a job, not by an entity callback |
| `views.janet` | plain functions returning hiccup; `db/rel` as the relation accessor, which is what makes an unplanned N+1 visible |
| `config/` | the layers: `default.janet` (shared), `<profile>.janet`, then `VOID_*`, then CLI overrides — `void config explain :cache :ttl` says which one won |

## The parts worth reading twice

**One form over two entities, one transaction.** `POST /articles`
carries `{:void.db/txn true}`, so the author lookup, the author insert
and the article insert either all land or none do. The route metadata
is the whole of the transaction management; the handler never says
`begin`.

**The counter is a job, not a callback.** Entities in void have no
lifecycle hooks (ADR-0009). Posting a comment enqueues
`:recount-comments`, `:unique :args` collapses a burst on one article
into a single run, and the job recomputes the count and drops the
cached index. The queue is `void/jobs-db` — the same database and the
same transaction as the data it is counting.

**`db/rel`, not `(article :author)`.** A preloaded relation is a table
lookup; an unpreloaded one warns with the call site in dev and throws
under `[:db :n1-guard] :strict`, which is what the suite runs under.
The fix it names is always the same one: declare `:preload`.

## Running the suite

    jpm test                        # sqlite only
    VOID_TEST_PG="host=127.0.0.1 port=5432 user=void dbname=void_test" jpm test

The second form runs both passes. CI runs both.
