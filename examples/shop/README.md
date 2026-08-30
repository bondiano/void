# shop

A [void](https://github.com/bondiano/void) application, and the one
that puts the whole framework in one process: a storefront, a checkout
that takes money, a back office nobody wrote pages for, a JSON API with
its own OpenAPI document, an MCP server for an agent, and the
enterprise layer under all of it — metrics and traces, load shedding,
sign-in, row-level authorization, CSRF, rate limits, mail, background
jobs and an audit trail.

Everything here runs on **sqlite or Postgres**, chosen by one
environment variable, and the suite runs twice to keep that honest.

```sh
void db migrate       # create the schema
void shop seed        # a catalog, a customer and a staff account
void dev              # dev profile: watcher + netrepl + the app
void routes           # the route table, `void routes --keys` with metadata
void db erd           # the ER diagram, from the same declarations
void admin resources  # the back office, as the declarations describe it
void admin widgets    # which widget draws which field, and why
void shop stock       # this application's own command — and an MCP tool
void jobs stats       # what the queue is holding
void jobs work        # run the queue in another terminal
void deploy check     # is every store fit for [:deploy :shape]?
void repl             # a repl inside the running process
```

`main.janet` is also the binary: it calls `cli/app-main`, so `janet
main.janet routes` — or `./build/shop routes` after `jpm build` — is
the same CLI against the composition inside that one file, which is
what lets a single-artifact deploy run its own migrations
([docs/DEPLOY.md](../../docs/DEPLOY.md)).

Then <http://localhost:8080>. Sign in as `ada@shop.example` /
`ada-ada-ada-ada`, or as the desk with `desk@shop.example` /
`desk-desk-desk` (`void shop seed` prints both) — the second one also
opens <http://localhost:8080/admin>.

Or the whole thing, including a database, a redis, a mail server and
Prometheus, with one command — see [Docker](#docker) below.

## How it is laid out

void has no module system of its own: no registry to enrol in, no
loader that scans a directory, no naming convention it enforces. So
this example picks one and writes it down, because "where does this
code go" is the question a framework's examples usually leave to
taste.

```
main.janet              the composition — thirty-five void plugins plus this
                        one, and the two things a deployment changes; also
                        the entrypoint, which *is* the void CLI when it is
                        given arguments (cli/app-main)
config/                 the layers: default.janet, then <profile>.janet, then
                        VOID_*, then CLI overrides (`void config explain
                        :cache :ttl` says which one won)
db/migrations/          migrations as data (DDL included), one transaction
                        each; the last one creates the tables void/jobs-db and
                        void/bus-db own, out of the DDL those plugins ship
src/
  app.janet             the plugin manifest: the module imports, two hooks,
                        two CLI commands — and no code about a shop
  shared/               values and DTOs that belong to no module
  web/layout.janet      the page frame; the one file that knows about more
                        than one module, because a nav bar is a list of them
  seed.janet            what `void shop seed` writes
  modules/
    catalog/  cart/  customers/  orders/  payments/  audit/
```

There is no `admin/` module, and there used to be: a controller, a view
and three hand-written routes. What replaced it is a `*.admin.janet` in
each module that has rows somebody at a desk looks at — declarations
over the entities those modules already had, which `void/admin`
projects into pages and `void/admin-mcp` into tools for an agent
(ADR-0029). A back office is a *layer* of a module, exactly as
`*.api.janet` is.

**A module is a directory, and the suffix says which layer a file is.**

| suffix | may | may not |
|---|---|---|
| `*.model.janet` | `defentity`: the table, its columns, its relations | be anything but a declaration |
| `*.dto.janet` | `defschema`, and the projection that satisfies it | name a table |
| `*.repository.janet` | every query about this module's tables | see a request, a session or an identity |
| `*.service.janet` | the rules — transactions, invariants, telemetry, what to publish | name a table, or see a request |
| `*.controller.janet` | unpack the request, call the service, pick the view, choose the status | hold a rule, or write SQL |
| `*.api.janet` | the same, answering with a DTO instead of a view | be a second application |
| `*.view.janet` | hiccup | know that HTTP exists |
| `*.admin.janet` | `defresource-admin`: which columns a desk looks at, what may be done to a row, and the policies that narrow it | hold a handler, a template or a rule |
| `*.policy.janet` `*.jobs.janet` `*.events.janet` `*.mailer.janet` `*.session.janet` `*.telemetry.janet` | one adapter each: authorization, the queue, the bus, the letters, the session, the metrics | — |

Dependencies point one way — controller → service → repository → model
— and the two ends of that chain are what the split is *for*: a
repository is the only thing that names a table, and a service is the
only thing that decides. Which is why the checkout can be read without
a request existing, the policies are tested with no database, and the
JSON API is forty lines rather than a second application.

**And the modules:**

| module | what it shows |
|---|---|
| `catalog/` | the storefront: a cached listing, a product page, and the conditional UPDATE that takes stock off a shelf without a lock |
| `cart/` | the cart that exists before an account does: a token in the session, a row with a null `customer_id`, `adopt!` at sign-in — and the session adapter that is the only file which knows where a browser keeps it |
| `customers/` | the three ways in (a password, a link in a letter, a new account), the `:staff` policy and the attribute provider behind it |
| `orders/` | the transaction this application is about, plus everything it causes: the payment job with its compensation, the three letters, the bus consumers that send them, and one policy enforced on three surfaces — and a desk whose only write calls the same service the checkout does |
| `payments/` | the gateway that is not there — no model, no repository, one port: a decline is a returned value, a timeout is a raised error, and the difference is the whole contract with the job |
| `audit/` | the trail — one consumer subscribed to `:*`, a directory you can delete, and the two lines that make the back office's changes land in it |

## The parts worth reading twice

**The checkout is where a shop is judged, so read it first.**
`orders/orders.service.janet` is one `db/with-tx`, and every piece of
the framework in it is there to answer a specific fear:

```janet
# catalog/catalog.repository.janet
(db/execute!
  {:update "products"
   :set {:stock [:raw (string "stock - " quantity)]}
   :where [:and [:= :id product-id]
                [:= :status "active"]
                [:>= :stock [:val quantity]]]})
```

Stock comes off with a **conditional UPDATE**, so two customers racing
for the last unit cannot both win — the database decides, and the
affected-row count is the answer. Reading the stock first and deciding
in janet is the version of this code that oversells on a Friday. It is
in the *catalog's* repository, because it is a write against the
products table, and the checkout calls it — which is the layering
earning its keep rather than obeying itself.
The price is **re-read here**, never carried on the form, so a cart
that sat open for a week cannot buy last week's price. And the
announcement rides the transaction: `bus/publish-tx!` writes
`:order/placed` into the outbox and `jobs/enqueue` writes the payment
capture into the queue, both in the same transaction as the order — so
there is no receipt for an order that rolled back, and no order that
nobody charges.

**A rollback is an answer, not an error.** The route deliberately does
*not* carry `:void.db/txn true`: the interesting outcome of a checkout
is "the last one sold half a millisecond ago", which is a page with a
message on it. `db/rollback!` unwinds to the `with-tx` that opened the
transaction, which returns nil, and the reason — set before the unwind
— is what the handler renders.

**Nothing sends the receipt.** `orders/orders.events.janet` subscribes
to `:order/placed` and mails it; the checkout does not know that, and
deleting the file stops the letters and changes nothing else. The
letter itself goes out **through the queue** because `void/mail-jobs`
is in the composition — `mail/send` renders it here and a worker
delivers it, and no call site says so.

**A declined card and a timeout are different things.**
`payments/capture!` *returns* `{:ok false}` for a decline and *raises*
for a gateway that did not answer. The job retries the second with backoff and, on its
last attempt, cancels the order and puts the stock back — a
compensation, because the checkout had already taken it. Both paths are
in the suite, deterministically: any total ending in 13 cents is
declined, which is why the seeded notebook costs €12.13.

**One policy, two surfaces — and a third that reads the same row
through a name of its own.** `:orders/own` is a pure function of a
context:

```janet
# orders/orders.policy.janet
(authz/defpolicy :orders/own
  [ctx]
  (or (= (authz/attr ctx :subject/id)
         (string (authz/attr ctx :resource/customer-id)))
      (authz/has-role? ctx :staff)
      "not your order"))
```

The HTML page and the JSON endpoint enforce it through route metadata —
the same two values, imported from the policy file rather than restated
in each surface — and `test/policy-test.janet` runs it as a table of
cases with no database, no HTTP and no system anywhere. The desk is the
third reader and does not restate it either: its routes carry
`:admin.orders/show`, a name void/admin puts there and this application
would answer if it wanted to narrow it, which is how "the staff sees
all of them" stays one sentence in one file rather than a policy copied
into a second surface.

**Attributes are pulled, and here is what that buys.** A session
identity carries `role` as a claim (void/auth-db copied it off the row
at sign-in), so the nav bar and the desk decide without a query. An
**API token** does not — so `customers/customers.policy.janet`
registers an attribute provider that reads the row *when a policy asks
about a role*, and a token minted a month ago cannot keep a role that
changed yesterday. A design that
pushed the role into every context would pay for that query on every
catalog request.

**The cart belongs to a browser, not to an account.** A token in the
session, a row with a null `customer_id`, and `cart/adopt!` at sign-in.
That is what makes "fill a cart, then sign in at the checkout" work,
which is the flow a shop lives or dies by. `cart.session.janet` is the
one file that knows where the token is kept — everything else in the
module is a function of a cart row, which is why the sweep, the
checkout and the header can all talk about one without a request.

**CSRF costs the application nothing, and applies to the right
requests.** No handler mentions it. The form helper renders the hidden
field because `void/security` binds the slot `void/html` has carried
since wave 1, and the layout carries the `<meta>` tags that let htmx
send the token too. The check applies to requests whose credential rode
on a **cookie** — which is why the JSON API, where a session cookie is
not a credential at all (`:void.auth/strategies [:bearer]`), needs no
token.

**The API is a second view, not a second application.** Same process,
same rows, same policies, same audit trail. What differs is metadata:
`:void.schema/query` coerces and validates before the handler,
`:void.schema/response` says what comes back, `:void.cache/response`
caches the catalog listing (sound only because that answer is the same
for everybody — the storefront's HTML is not, so it caches the *query*
instead), and `/openapi.json` is a projection of all of it.

**The back office is a projection, and there is no code in it.** Four
files — `catalog/catalog.admin.janet`, `orders/orders.admin.janet`,
`customers/customers.admin.janet`, `audit/audit.admin.janet` — declare
what a desk sees, and `void routes` then lists twenty-three routes
nobody wrote:

```janet
# orders/orders.admin.janet
(admin/defresource-admin orders model/Order
  :only    [:index :show]
  :filters [:status]
  :actions {:ship {:label "Mark shipped"
                   :apply (fn ship [row _req] (service/ship! row))}})
```

Four things in that are worth the read. **`:only` is not a hidden
button** — the create, edit, update and destroy routes do not exist, and
the route table is where you check. **An action is a domain call**:
`:ship` calls the `ship!` the shop has had since wave 2, so "only a
paid order can ship" stays next to the write instead of being decided
again by the desk. **The columns, the types, the enum's members and the
foreign keys are read off `defentity`** — add a column to the model and
it is in the list, in the form and in the tool an agent calls, in one
edit. And **`:archive` on the products declares `:job`**, so a
selection larger than a request goes through `void/admin-jobs` and the
confirmation becomes a progress page, with the identity that pressed
the button riding along so the per-row policies decide about the same
subject.

**The gate is shut until one line opens it, and that line names a
policy the shop already had.** `{:admin {:access :staff}}` in
`config/default.janet` — the same `:staff` the storefront's own
authorization uses, over the same `role` column, with no second
authentication, no admin session and no user table of its own.
Narrowing goes the same way: every admin route already carries
`:admin.<resource>/<action>` next to the gate, and void/admin only
registers an allowing policy under that name where the application has
not — so `customers/customers.admin.janet` refuses the desk its *own*
account by writing one function and registering it under the two names
the edit and update routes carry, with no change to the declaration, to
the routes or to a handler. `test/policy-test.janet` runs that rule as
a table of cases with no system anywhere, next to `:orders/own`.

**The desk owns no table.** `void/admin` announces every change through
`:void.admin/changed` and keeps nothing; `audit/audit.admin.janet`
turns that announcement into a bus message, so an archived product
lands in the same `audit_events` the checkout writes to, under the same
correlation id, and no migration shipped with any of it. The history
tab is the same wire in the other direction. Where the change was made
decides how it is published: a page's write rides `publish-tx!` inside
the transaction the route declares, and a bulk that ran in a worker
publishes plainly, because there is no transaction there to ride and
pretending otherwise would be the lie.

**And the desk is not in the public API document.** `/openapi.json` is
a projection of the route table, route metadata can only be set by
whoever declares a route, and this application declares none of the
admin's — so `[:admin :route-meta] {:void.openapi/hidden true}` is how
it says so, in one place, for all twenty-three of them.

**The audit trail is one directory.** `audit/audit.consumer.janet`
subscribes to `:*` and writes rows. Three kinds of thing arrive by
three routes and none of them knows about the trail: domain facts
through the transactional
outbox, the queue's whole lifecycle from `void/bus-jobs`, and
authorization refusals from the hook `void/authz` fires for every
decision. `:message-id` is unique in the table, so the redelivery an
at-least-once bus is entitled to costs a rejected insert rather than a
duplicated line.

**A nav link is not an authorization decision.** `layout/staff?` asks
`authz/has-role?` over a bare context rather than `(authz/can? :staff)`
— because every `can?` is a decision, every decision goes through the
hook the audit trail subscribes to, and a header that asked would put a
refusal on the trail for every page view by every visitor. The route is
where that decision is made, and every route under `/admin` carries the
gate that makes it.

**The shop is an MCP server, and nobody wrote one.** `:void/mcp` is in
the composition and `void mcp tools` prints forty-five tools and
twenty-three resources, out of two projections and no MCP code at all.
Every tool is either a command the operators already run (`void jobs
stats`, `void bus tail`, `void db status`, and this application's own
`void shop stock`) or a *declaration of the back office* read through
`void/admin-mcp` — `admin-products-list`, `admin-orders-list`,
`admin-payments-list`. The second half is the one worth pausing on: the
agent's tools and the desk's pages are two readers of one value, so an
agent's idea of what may be filtered, sorted or written cannot drift
from the pages', and its authorization is not a second implementation
either — the same gate, and the same per-action policy, per row.

Nothing that writes is offered: `db migrate`, `jobs work`, `mail send`,
`shop seed`, and every admin `create`, `update`, `delete` and declared
action are absent because none of them said `:read-only? true`, and the
default exposes nothing else (ADR-0031). Handing an agent one of them
is a line of config — `{:mcp {:tools [:shop/seed]}}` — and it is the
operator's line, not the framework's. `test/mcp-test.janet` asserts
both halves of that list, and `test/admin-test.janet` calls the tools
with and without an identity.

The HTTP transport (`:void/mcp-http`, `POST /mcp`) is deliberately
*not* composed here: it is one more plugin and one token, and an
example should not leave a tool endpoint open on the port it tells you
to run.

## Running the suite

    jpm test                        # sqlite only
    VOID_TEST_PG="host=127.0.0.1 port=5432 user=void dbname=void_test" jpm test

Five files:

* `test/shop-test.janet` — the whole application through `test/inject`
  (ADR-0017): catalog, cart, sign-up, checkout, the payment job, the
  sold-out path, a declined card, row-level authorization, the desk,
  the metrics endpoint and the rate limit. Once per engine.
* `test/admin-test.janet` — the back office, once per engine: the gate,
  a list with its search, filter and count, an in-place cell edit, a
  declared action that leaves an unpaid order alone, a bulk that runs
  as a job, an action narrowed by one `defpolicy`, the trail the
  changes land in, and the same declarations called as MCP tools with
  and without an identity.
* `test/api-test.janet` — the JSON side: paging, sorting, problem+json,
  response caching, bearer tokens, a session cookie *not* working as an
  API credential, and the OpenAPI document — which the desk is not in.
* `test/mcp-test.janet` — what an agent is offered and what it is not,
  asserted on the exposure rather than on a running server.
* `test/policy-test.janet` — the policies as a table of cases, with no
  system running at all. It imports three declaration files and nothing
  else, which is the layering's cheapest dividend.

The N+1 guard runs at `:strict` in the suite, so an unplanned relation
is a failure rather than a warning.

## Docker

```sh
docker compose up --build              # the shop on http://localhost:8080
docker compose --profile obs up --build  # plus Prometheus and Grafana
```

| | |
|---|---|
| <http://localhost:8080> | the shop |
| <http://localhost:8080/admin> | the desk (sign in as `desk@shop.example`) |
| <http://localhost:8080/docs> | Swagger UI over `/openapi.json` |
| <http://localhost:8025> | Mailpit — every receipt, cancellation and sign-in link |
| <http://localhost:3000> | Grafana, with the "void shop" dashboard provisioned (`--profile obs`) |
| <http://localhost:9090> | Prometheus (`--profile obs`) |
| `localhost:55432` | Postgres, published so `psql` can look at the outbox and the trail |

Six services, and the interesting one is that **web and worker are the
same image running the same code**: what differs is two environment
variables (`VOID_JOBS__WORKER__ENABLED`, `VOID_JOBS__SCHEDULER__ENABLED`).
That is the deployment shape void/jobs is built for — the process that
enqueues is usually not the process that runs.

A few things the compose file is making a point about:

* **The schema is migrated by a one-shot service**, not by whichever
  process boots first. `[:jobs-db :auto-create]` and
  `[:bus-db :auto-create]` are off in `:prod`, and
  `db/migrations/20261001090500` creates those tables out of the DDL
  the two plugins ship as data. Two processes starting together
  otherwise race on `CREATE INDEX IF NOT EXISTS`.
* **Sessions and the cache are in redis** (`config/prod.janet`), which
  is what lets the web tier be more than one process — an in-memory
  session store plus workers is a login that works every other request,
  and void/http refuses that combination at `:start` rather than
  discovering it in production.
* **The queue and the message log stay in Postgres**, because both of
  them have to commit with the data they are about.
* **`/metrics` is not public**: `VOID_OBS_HTTP__TOKEN` is the bearer
  token Prometheus sends, and a request without it gets a 401.
* **The signing key is a secret reference.** `config/prod.janet` says
  `{:secret "SHOP_SECRET_KEY"}`, so the value lives in the environment
  and the config tree holds a box that does not print. Without it the
  process refuses to start in `:prod`.
* **The REPL is still there.** `docker compose exec web void repl` is a
  REPL *inside the running web process* — the netrepl listens on a unix
  socket in the container, so reaching it means being able to exec into
  the container already.

Watch the whole causal chain of one order:

```sh
docker compose exec postgres psql -U shop -d shop \
  -c "select topic, actor, at from audit_events order by id desc limit 10"
```

`order/placed` (the outbox), `jobs/enqueued`, `jobs/started`,
`jobs/completed` (the queue's own life, forwarded by void/bus-jobs),
`order/paid` — and one letter in Mailpit for it, sent by a consumer no
handler calls.

The image is a two-stage build: everything that needs a compiler
happens in the first (janet, jpm, spork's native modules,
janet-lang/sqlite3 and void/fdwait's ~60 lines of C), and the second
carries a janet runtime, the installed tree, `libpq5`, `libssl3` and
the application — about 160 MB, most of which is Debian.

## Before a deploy

Two commands, and both of them answer before anything opens a port:

```sh
void deploy check     # every store fit for [:deploy :shape]?
void plugins lock     # write void.lock; `void plugins check` in CI
```

`deploy check` is the one this example exists to demonstrate. The
compose file runs a web tier that scales and a worker beside it, so
`config/prod.janet` says `{:deploy {:shape :fleet}}` out loud and names
a shared implementation for every store the composition holds —
sessions and the cache in redis, the queue and the bus in Postgres, the
rate limiter's counters in the cache. Take one of those away and the
process **refuses to start**, with every violation named at once and a
replacement named for each; run the same composition with in-memory
stores under `:single` and it starts, because on one replica it is
true (ADR-0030). The bulk actions of the desk are part of that check:
`void/admin-jobs` refuses a fleet whose queue backend is per-process,
because a progress page served by another replica would not find the
job.

`plugins lock` writes the composition down as data — the plugin list,
every extension point with its contributions in resolution order, the
component graph and the deployment shape — so "why is the middleware
stack different in production" is a diff. This repository carries no
`void.lock` for the shop and the `.gitignore` says why: the composition
here is a function of two environment variables, so the lock belongs to
a deployment and is taken with that deployment's environment.

## Switching engines

    VOID_SHOP_DB=postgres void db migrate
    VOID_SHOP_DB=postgres void dev

`main.janet` is the only file that names a driver. The entities, the
migrations, the handlers, the jobs, the cache and every test assertion
are the same on both — and `test/shop-test.janet` runs the whole suite
twice, once per engine, so the claim stays true.

Redis is the same kind of switch: `VOID_SHOP_REDIS=1` composes
`:void/redis`, `:void/redis-http` and `:void/cache-redis`, and the
sessions and the cache move out of the process. Nothing else changes.
