# hub

A [void](https://github.com/bondiano/void) application: a webhook hub.
GitHub deliveries come in, get kept, and go out to a chat — the niche
SPEC §9 names out loud, and the wave-6 application the roadmap is built
around ([ROADMAP 6.6](../../docs/ROADMAP.md)).

Today it receives, verifies and keeps deliveries, decides where each one
goes, sends it to a telegram chat through a queue, and gives an operator
the two screens an incident needs. What is left is the deploy.

## Receiving a delivery

One route, and the order of what it does is the design:

```
POST /in/:source
  1. is this a source this hub was told about?      404 if not
  2. HMAC-SHA256 over the bytes as they arrived     401 if it fails
  3. the bytes -> void/storage under the delivery's own id
  4. a row: source, event, delivery id, repo, sender, size, key
  5. 202 accepted
```

Nothing is stored before the signature checks out — otherwise a stranger
authors this application's disk usage — and nothing is routed before the
answer goes out: the sender is owed a 202, not a tour of what happens
next. `X-GitHub-Delivery` is unique in the database, so a redelivery is
one row, one blob and (later) one message.

The raw body goes to a store rather than a column because it is the one
thing worth keeping verbatim and the one thing nobody wants in a row: a
signature is over bytes, so bytes that came back different would have
lost the evidence. `test/intake-test.janet` asserts exactly that.

Point a real repository at it with a secret in the environment:

```sh
VOID_HUB__SOURCES__GITHUB__SIGNING_SECRET=... void dev
```

In a config file the same secret is a **reference** —
`{:signing-secret {:secret "GITHUB_WEBHOOK_SECRET"}}` — which
void/core/config resolves into a box that no log line and no printed
config can reveal.

## Where a delivery goes

A rule is a table, not a branch:

```janet
:hub {:rules [{:when {:event ["push" "release"] :repo "bondiano/void"}
               :to [:telegram]
               :chat-id "-1001234567890"}]}
```

`:when` is a conjunction over the fields of the row the intake wrote —
`:source :event :repo :sender` — and a field a rule does not mention is
one it does not care about. A value is a string or a list of them, and
deliberately nothing else: the moment this grows patterns it stops being
a table somebody can read at three in the morning.

**Every matching rule is its own notification**, because a rule can name
the chat it goes to and two chats cannot be one address — and because a
rule whose channel is down should be that rule's failure and not the
other rule's. Matching is a pure function of two values, which is why
`test/route-test.janet` is a table of examples and boots nothing.

Telegram is a channel this application wrote
(`src/modules/telegram/telegram.channel.janet`), which
is exactly what ADR-0040 says such a channel is: a contribution with two
functions. `:project` runs on the request fiber and returns a chat and a
string; `:deliver` runs on a worker and posts it. That split is why the
queue fits between them and why a retry sends the message the request
meant rather than one rebuilt later.

```sh
VOID_HUB__TELEGRAM__TOKEN=123456:AA... VOID_HUB__TELEGRAM__CHAT_ID=... void dev
void jobs work   # in another terminal: the sending half
```

Without a worker the notifications sit in the queue, which is the
correct amount of nothing to happen — `void jobs stats` shows them
waiting.

The channel declares `:needs [:tls/lib]`, and that one line is a bug
this application found. A command starts the components it declares in
`:needs` and no others — that is what lets `void jobs stats` answer
without opening a port. `void jobs work` needs `:jobs/queue`, which is
true of the worker and false of the **work**: an https delivery needs
`:tls/lib`, a component the queue does not depend on. The first live
delivery therefore failed five times against a very clear message about
libssl while `void/tls` sat composed and unstarted in the same process.
The hub carried its own `void hub work` — the same worker with one more
line — until the framework learned the general form: a `defjob` (and a
notify channel) says what its work needs open, and `void jobs work`
starts the union over the queues it serves.

## The desk

Everything a *person* does here is operations — receiving is a machine
talking to a machine — so the guestbook `void new` wrote is gone and
this application has two screens.

**`/` is the jobs dashboard.** The question a hub is asked at three in
the morning is "did it go out", and that is a question about the queue.
Nothing was written to make 6.3's dashboard the front door: the page is
a `:void.admin/page` contribution, so it has a route name, and the home
handler is `(ring/redirect (http/url-for :admin.page/jobs))`.

**`/admin/deliveries` is the row the intake wrote, projected.**
`defentity` already says what a delivery is (ADR-0029), so the
declaration in `intake/intake.admin.janet` adds only what a schema
cannot: the columns
an operator scans, the three fields they search by, the two they filter
on. It is read-only, and not because a write would be hard — a fact
about the past that can be edited from the page that displays it is not
evidence.

The one column that is genuinely this application's is `body-key`, and
it gets a widget:

```
[:storage :serve :signed] true      the whole prefix is private
storage/url key {:expires 300}      exp + sig, over the key and the expiry
```

The bytes are the evidence and they are also somebody else's payload —
a private branch name, a commit message. So the link **is** the
authorization, which is why it lasts five minutes: a URL pasted into a
chat should stop working before the chat is read. Signing is the CSRF
construction on the same keys (ADR-0039 §5), and the same path without
the query is a 403.

**Who is an operator is a list.** `[:hub :operators]` names the
addresses that get past `:hub/operator`, the policy `[:admin :access]`
points at. Empty by default — registration here is open, and "anybody
signed in is staff" over an open registration is a hub anybody can read.

```sh
VOID_HUB__OPERATORS='["you@example.com"]' void dev
```

A column on `users` would have wanted a migration and a page to edit it,
for a value that has two rows in it and changes when somebody leaves.

## Replaying a delivery

A webhook needs a public hostname to arrive at, so the usual way to
change one line of `routing/` is a tunnel, a repository and somebody
to push to it. The bytes are already here:

```sh
void hub replay dbf9a595-2e45-492e-be62-f80881474673   # the sender's id
void hub replay 2                                      # or the row id
```

```
replaying dbf9a595-2e45-492e-be62-f80881474673 — github push on bondiano/void, 978 bytes
  telegram   queued (job 41)
run `void jobs work` to deliver it
```

**Replay routes again; it does not receive again.** Receiving is a
signature over bytes that have already been verified, and re-running it
would either be refused as a duplicate — the delivery id is unique, that
is the whole point — or write a second row for one delivery. What is
replayed is the *decision*, which is the half with the bugs in it: a
rule that did not match, a message that came out wrong, a chat that was
not configured yet. One real delivery has to arrive once; after that the
interesting half runs as many times as it takes.

The command starts three components and no port — the database the row
is in, the store the bytes are in, and the queue the notification goes
on — which is the same argument the worker makes from the other end.

## What makes it different from the other examples

Every other example imports void through `test-support/paths.janet` —
the package graph projected onto `module/paths`, so its suite runs
against the sources in this checkout. That proves the sources work. It
proves nothing at all about the **install**, which is how everybody who
did not clone this repository gets void.

The hub has no such file. It imports `void/...` from an installed tree
and nothing else, which means it also pays what a stranger pays: a
change to the framework reaches it only after the bundle is installed
again.

```sh
janet ../../scripts/install-tree.janet         # the bundle -> ../../.void-tree
eval "$(janet ../../scripts/install-tree.janet --export)"

void db migrate                                # create the schema
void dev                                       # dev profile: watcher + netrepl
void routes                                    # the route table
void repl                                      # a repl inside the running process
```

Then <http://localhost:8080/register>. In the `:dev` profile letters are
written to `tmp/mail/` instead of being sent, so the verification link
is a file you can open.

`jpm test` here needs the same tree — `JANET_TREE`, which the export
above sets, because `jpm` does not read `JANET_PATH` at all. In CI this
is the "clean machine" job, the only place where what this example
proves is true.

## What this application sent back

The first commit of this directory is exactly what `void new hub` and
`void make auth` produced, with nothing touched. Everything after it is
the diff, and six lines of that diff turned out to be about the
framework rather than about a webhook hub. All six are now closed, and
they are kept here because "what a real application found" is the only
honest way to have picked them:

1. **`janet-lang/sqlite3` in `project.janet`.** The bundle leaves the
   driver's library out on purpose (ADR-0011): `void/db-sqlite` is a
   plugin an application lists, so the application installs it. But
   `void make auth` generated a suite that boots that driver and said
   nothing about the dependency, so the generated suite failed on a tree
   that has only void — with the driver's (good) message, and no hint
   that a generator had caused it. *Fixed: the generator names the
   dependency, the file it goes in, and why the bundle does not carry
   it.*

2. **The composition and the config block.** `void make auth` printed
   ten plugins and a config map and asked for them to be pasted into
   `main.janet` and `config/`. *Decided, not automated: `make` writes
   new files and edits none — phx.gen.auth rewrites a router because it
   can pattern-match one line of Elixir it wrote itself, and these three
   files are not that. The decision is now in the generator's own
   output, along with everything that decision costs the reader.*

3. **The content security policy.** The page `void new` writes loads
   htmx from unpkg; `void make auth` requires `void/security`, whose
   default policy is `default-src 'self'`. Generate both and the result
   is a page whose script the browser refuses, with nothing in the
   terminal to say so. *Fixed: `make auth` prints the policy block it
   just made necessary. `config/default.janet` here is a paste of it.*

4. **The admin's stylesheet was inline, and the default CSP refused
   it.** `void/admin`'s layout wrote its stylesheet into the page as a
   `<style>` element, which `default-src 'self'` blocks — an unstyled
   desk and a console line, the same shape as the htmx problem above and
   found the same way. This application paid for it with
   `:style-src [:self :unsafe-inline]`, the weakest half of its own
   policy, spent on somebody else's markup. *Fixed: the admin serves its
   sheet and every widget's assets as two fingerprinted files from its
   own prefix, so composing the back office costs an application no
   policy at all. That line is gone from `config/default.janet`.*

5. **The body ceiling was raised for the whole application to serve one
   route.** GitHub sends up to 25 MiB, so `config/default.janet` lifted
   `[:http :max-body]` once and every page-serving route put it back
   down to 64 KiB — the inverse of what the application means. *Fixed,
   and the fix was a misreading, which is the interesting part:
   `:void.http/max-body` is `:restrict` between **metadata** layers
   (group → route), and `[:http :max-body]` is not one of those layers —
   it is what a route that declares nothing gets. So the intake route
   names its own 25 MiB, under no ceiling but its own, and the rest of
   the application keeps 64 KiB without a word. The contract needed no
   change; its docstring did, because it read as if the config were an
   outer layer.*

6. **The worker did not know what the jobs need.** A command starts what
   it declares in `:needs`; `void jobs work` declares `:jobs/queue`,
   which is true of the worker and false of the work. A telegram
   delivery is https, and https is `:tls/lib`. *Fixed: `defjob` takes
   `:needs`, a `:void.notify/channel` takes `:needs`, and `void jobs
   work` starts the union over the queues it serves. The channel
   says `:needs [:tls/lib]` and `void hub work` no longer exists.*

One more thing came out of building this and was fixed rather than
listed: `jpm build` could not link any application composing
`void/html`, because the asset fingerprint held an abstract value in a
`def` and `jpm build` marshals everything its entry point reaches.

## Layout

The layout is [examples/shop](../shop/README.md)'s, and deliberately:
void has no module system of its own — no registry to enrol in, no
loader that scans a directory — so an example that picks a convention
and a second one that picks a different convention would be teaching
that the question has no answer.

```
main.janet          the composition, the two switches a deployment flips,
                    and the entrypoint that *is* the void CLI when given
                    arguments (cli/app-main)
config/             default.janet, then <profile>.janet, then VOID_*, then
                    CLI overrides (`void config explain :mail :transport`)
db/migrations/      migrations as data, DDL included — including the tables
                    void/jobs-db and void/db-http own, out of the DDL those
                    plugins ship
src/
  app.janet         the plugin manifest: the module imports, one hook, the
                    schema of [:hub] — and no code about a webhook hub
  shared/values     the timestamp both tables write
  web/layout.janet  the page frame, which is the one file that knows about
                    more than one module
  modules/
    intake/         what arrives: the route, the signature, the store, the
                    row — and the desk that reads them back
    routing/        where it goes: rules as data, matching as a pure
                    function, one notification per matching rule
    telegram/       what carries it out: the notify channel this
                    application wrote (ADR-0040)
    auth/           the accounts `void make auth` generated, and the policy
                    that decides which of them is an operator
    ops/            the operator's surface: `/` is the jobs dashboard, and
                    `void hub replay` is the one command
test/               the suite `void make auth` generated, and the ones this
                    application wrote — `jpm test` (on the installed tree)
```

**A module is a directory, and the suffix says which layer a file is** —
the same table the shop's README prints, minus the layers this
application has no use for and plus the one it needed:

| suffix | may | may not |
|---|---|---|
| `*.model.janet` | `defentity`: the table and its columns | be anything but a declaration |
| `*.dto.janet` | the schemas a form submits, and the value that crosses to another system | name a table |
| `*.repository.janet` | every query about this module's tables | see a request, a session or an identity |
| `*.service.janet` | the rules — what is verified, what is kept, what is sent | name a table, or see a request |
| `*.controller.janet` | unpack the request, call the service, pick the view or the status | hold a rule, or write SQL |
| `*.view.janet` | hiccup | know that HTTP exists |
| `*.admin.janet` | `defresource-admin`: which columns a desk looks at | hold a handler, a template or a rule |
| `*.policy.janet` `*.channel.janet` `*.cli.janet` | one adapter each: authorization, void/notify, the command line | — |

`*.channel.janet` is the row this application added. A notify channel is
a port with two ends — `project` where the request is, `deliver` where
the network is — and that is one adapter, not two layers, which is why
`telegram/` is a single file.

**The accounts module is the generated one, re-laid.** `void make auth`
wrote a single `auth.janet`: the entity, four form schemas, six views,
twelve handlers and the routes, in that order and in one file — which is
the right output for a generator that cannot know what a project's
layout is. Splitting it along the lines above is the whole of the
difference; the flows, the refusals and the comments are the
generator's. It is also the reason the sentence "the first commit is
exactly what the generators wrote" is still worth checking in the git
history rather than in the tree.
