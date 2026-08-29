# blog

A [void](https://github.com/bondiano/void) application — the wave-2
demo: CRUD over `void/db`, with migrations, a background job and a
cache, on **Postgres or sqlite, chosen by config**; and the wave-3
one: signing in (by password, or by a link that arrives in the mail),
a row-level policy, and the browser protections that come with
composing a few more plugins.

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
whole suite twice, once per engine, so the claim stays true. Wave 3
added ten plugins and no engine-specific line, so
`test/auth-test.janet` runs twice as well.

## What is where

| File | What it shows |
|---|---|
| `entities.janet` | `defentity` — one declaration feeding validation, the repository, `:preload` and `void db erd`; form DTOs projected off it with `schema/select`/`schema/merge` |
| `db/migrations/` | migrations as janet files, one transaction each, `up`/`down`; self-contained by design — they never import the entities |
| `app.janet` | routes and handlers: `:void.db/txn` for transactions, explicit `:preload`, `cache/remember`, `jobs/enqueue` |
| `jobs.janet` | `defjob` with retries and `:unique :args`, plus a `defschedule` — the denormalized comment counter is kept true by a job, not by an entity callback |
| `views.janet` | plain functions returning hiccup; `db/rel` as the relation accessor, which is what makes an unplanned N+1 visible |
| `config/` | the layers: `default.janet` (shared), `<profile>.janet`, then `VOID_*`, then CLI overrides — `void config explain :cache :ttl` says which one won |
| `app.janet` (wave 3) | `defpolicy :articles/own` — a pure function of a context; `:void.auth/access`, `:void.authz/policy` and `:void.authz/resource` as route metadata; the sign-in, sign-out and registration handlers |
| `views.janet` (wave 3) | `authz/can?` deciding whether to draw the Edit control, and `security/htmx-meta` putting the CSRF token where htmx will find it |
| `app.janet` (wave 3.5) | `auth/challenge!` — the whole of "mail me a sign-in link" — and the route the link lands on; the letter itself is `void/mail-auth`'s |

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

## The wave-3 half

**The author is not a form field.** In wave 2 publishing an article
carried a name and an email and invented an author when it did not
recognise them. Now `POST /articles` carries `:void.auth/access
:required` and the author is whoever is signed in — an identity is not
something a form gets to claim to be.

**"Their own" is one function, asked twice.**

```janet
(authz/defpolicy :articles/own
  [ctx]
  (or (= (authz/attr ctx :subject/id)
         (string (authz/attr ctx :resource/author-id)))
      "not the author of this article"))
```

The edit routes enforce it through `:void.authz/policy` +
`:void.authz/resource`; `views/article-view` asks the *same* policy
whether to draw the Edit control. A link that is drawn and a request
that is allowed cannot drift apart, because there is one answer. The
policy itself needs no attribute provider: `:subject/id` falls back to
the id half of the subject string and `:resource/author-id` to a key of
the row, so `test/auth-test.janet` tests it as a table of four cases
with no database and no system anywhere.

**Deny by default.** `config/default.janet` sets `[:authz :default
:deny]`, so every route in `app.janet` names a policy — `:public` where
it means it. A route that forgets one does not serve traffic and get
audited later: it fails the boot, with the route named.

**CSRF costs the application nothing.** No handler mentions it. The
form helper renders the hidden field because `void/security` binds the
slot `void/html` has carried since wave 1, and the layout carries the
two `<meta>` tags and the `hx-headers` attribute that let the Delete
button — an htmx request with no form around it — send the token too.
The check applies to requests whose credential rode on a cookie, which
is why the anonymous comment form still works and a JSON client would
not need a token at all.

**A sign-in link is one call, and no template.** `request-link` asks
`auth/challenge!` for a single-use code and stops there: the letter,
its URL and its expiry line come from `void/mail-auth` (`(set
mail-auth/link-view …)` replaces the letter without an extension
point). Because `void/mail-jobs` is in the composition, the letter is
rendered on the request and **sent by the worker** — the handler does
not know that and does not have to; `void jobs work` is what puts it
in an inbox, and in development `[:mail :transport] :file` writes it
into `tmp/mail` as a `.eml` that opens in a mail client. The page says
the same thing whether or not the address has an account, for the same
reason the password path does.

**The authors table stayed the application's.** `void/auth-db` reads
it (`[:auth-db :users]` in `config/default.janet` names the columns);
the wave-3 migration adds one nullable `password_hash` and creates the
two tables that belong to void, straight from `(auth-db/tables)` —
DDL the plugin ships as data, in a migration the application owns.

## Running the suite

    jpm test                        # sqlite only
    VOID_TEST_PG="host=127.0.0.1 port=5432 user=void dbname=void_test" jpm test

The second form runs both passes. CI runs both.
