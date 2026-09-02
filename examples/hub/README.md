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

Telegram is a channel this application wrote (`telegram.janet`), which
is exactly what ADR-0040 says such a channel is: a contribution with two
functions. `:project` runs on the request fiber and returns a chat and a
string; `:deliver` runs on a worker and posts it. That split is why the
queue fits between them and why a retry sends the message the request
meant rather than one rebuilt later.

```sh
VOID_HUB__TELEGRAM__TOKEN=123456:AA... VOID_HUB__TELEGRAM__CHAT_ID=... void dev
void hub work    # in another terminal: the sending half
```

Without a worker the notifications sit in the queue, which is the
correct amount of nothing to happen — `void jobs stats` shows them
waiting.

**`void hub work`, not `void jobs work`**, and the reason is worth the
paragraph. A command starts the components it declares in `:needs` and
no others — that is what lets `void jobs stats` answer without opening a
port. `void jobs work` needs `:jobs/queue`, which is true of the worker
and false of the **jobs**: this application's job is an https delivery,
and https is `:tls/lib`, a component the queue does not depend on. The
first live delivery therefore failed five times against a very clear
message about libssl while `void/tls` sat composed and unstarted in the
same process. The application knows what its jobs need, so `ops.janet`
says so in one more line of `:needs`. Whether the framework should learn
this instead is a task in the roadmap.

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
declaration in `admin.janet` adds only what a schema cannot: the columns
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
change one line of `route.janet` is a tunnel, a repository and somebody
to push to it. The bytes are already here:

```sh
void hub replay dbf9a595-2e45-492e-be62-f80881474673   # the sender's id
void hub replay 2                                      # or the row id
```

```
replaying dbf9a595-2e45-492e-be62-f80881474673 — github push on bondiano/void, 978 bytes
  telegram   queued (job 41)
run `void hub work` to deliver it
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
on — which is the same argument `void hub work` makes below, from the
other end.

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

## What had to be written by hand

The first commit of this directory is exactly what `void new hub` and
`void make auth` produced, with nothing touched. Everything below is the
diff after it — kept as a list because each line is a candidate task for
the wave, not a note about this application:

1. **`janet-lang/sqlite3` in `project.janet`.** The bundle leaves the
   driver's library out on purpose (ADR-0011): `void/db-sqlite` is a
   plugin an application lists, so the application installs it. But
   `void make auth` generates a suite that boots that driver and does
   not add the dependency — so the generated suite fails on a tree that
   has only void, with the driver's (good) error message. *Task: the
   generator that writes a suite against a driver should write the
   driver's dependency too, or name it in what it prints.*

2. **The composition and the config block.** `void make auth` prints ten
   plugins and a config map and asks for them to be pasted into
   `main.janet` and `config/`. Everything pasted is identical in every
   application that runs the generator. *Task: decide whether `make
   auth` edits those two files the way phx.gen.auth does — and if not,
   say why in the generator's own text rather than in a habit.*

3. **The content security policy.** The page `void new` writes loads
   htmx from unpkg; `void make auth` requires `void/security`, whose
   default policy is `default-src 'self'`. Generate both and the result
   is a page whose script the browser refuses, with nothing in the
   terminal to say so. `config/default.janet` widens the policy the way
   `examples/shop` does. *Task: serve htmx from the application's own
   assets in what `void new` writes (the asset pipeline has fingerprinted
   it since 6.5), or have `make auth` name the policy line.*

4. **The admin's stylesheet is inline, and the default CSP refuses
   it.** `void/admin`'s layout writes its stylesheet into the page as a
   `<style>` element, which `default-src 'self'` blocks — an unstyled
   desk and a console line, the same shape as the htmx problem above and
   found the same way. `config/default.janet` adds
   `:style-src [:self :unsafe-inline]`. *Task: serve the admin's
   stylesheet as an asset (fingerprinted since 6.5) or mint a nonce for
   it, so that composing the back office does not cost an application
   the strictest half of its policy.*

5. **The body ceiling is raised for the whole application to serve one
   route.** GitHub sends up to 25 MiB and `:void.http/max-body` is
   `:restrict` — a route may lower the application's ceiling and never
   raise it. So `config/default.janet` lifts it once and every page in
   the application puts it back down to 64 KiB — the two route sources
   of its own, and `[:admin :route-meta]` for the thirty routes
   `void/admin` projects — which is the inverse of what the application
   means. *Task: decide whether one route may be allowed to
   raise it (the metadata contract has `:allow?` for exactly this kind
   of question) — this hub is the first honest case for it.*

One more thing came out of building this and is already fixed rather
than listed: `jpm build` could not link any application composing
`void/html`, because the asset fingerprint held an abstract value in a
`def` and `jpm build` marshals everything its entry point reaches.

## Layout

```
main.janet          the composition, and the entrypoint that *is* the void
                    CLI when given arguments (cli/app-main)
auth.janet          register / sign in / reset / verify — `void make auth`
intake.janet        the receiving end: the route, the signature, the store
                    and the row — and `replay!`, which is the second half
                    of it run again
route.janet         where a delivery goes: rules as data, matching as a
                    pure function
telegram.janet      the notify channel this application wrote — project
                    here, deliver on a worker
admin.janet         the operator's half: who is an operator, deliveries as
                    a declaration, the raw body behind a signed URL, and
                    `/` as the jobs dashboard
ops.janet           the two commands an operator runs: `void hub work`,
                    `void hub replay`
config/             default.janet, then <profile>.janet, then VOID_*, then
                    CLI overrides (`void config explain :mail :transport`)
db/migrations/      migrations as data, DDL included
test/               the suite `void make auth` generated, and the ones this
                    application wrote — `jpm test` (on the installed tree)
```
