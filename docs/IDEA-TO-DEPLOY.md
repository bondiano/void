# Idea to deploy: the path, step by step

The measure of this project is not adoption but three things, and the
first of them is **the time from an idea to a working deploy for one
developer**. A number nobody can reproduce is not a measurement, so this
document is the path itself: every step that took `examples/hub` from
`void new` to a webhook hub receiving signed deliveries over TLS and
posting them to a chat — what each step produced, what it cost, and
which of them were the framework's fault.

It is written from that one application. Where a step was decided
rather than run, the decision is named. Where a step found a bug, the
bug is named too: a path with the potholes filled in silently would be
an advertisement.

The whole of it is **fourteen steps**, of which two are generators,
six are the application, four are the deployment, and one is the list
of what went wrong on the way. What it is not is a tutorial — the hub's
own [README](../examples/hub/README.md) reads better for that — it is
the ledger behind a claim.

---

## 0. What you need on the machine

Janet ≥ 1.41, `jpm`, and — for the deploy at the end — Docker. That is
the list. void installs as **one bundle**:

```sh
jpm install https://github.com/bondiano/void.git
```

One dependency line in a project, one `void` binary on PATH, and every
`void/…` module importable. The hub is the example that proves this,
because it is the one that has no `test-support/paths.janet` and so
imports the framework the way a stranger does — from an installed tree
and nothing else. (Inside this repository the same install is
`janet scripts/install-tree.janet`.)

## 1. `void new hub` — the scaffold

```sh
void new hub && cd hub
```

An application that runs: a composition in `main.janet`, a config
layer (a prod profile included), a guestbook page, a `test/` with a
smoke suite in it, and a dev `docker-compose` for the services a real
application asks for next. The migrations directory arrives with the
first `void make resource` in step 2. `void dev` serves it on 8080 —
the banner says where — with a file watcher and a REPL into the
running process.

**Cost: one command.** The hub's first commit is exactly this plus step
2, with nothing touched — which is checkable, because it is a commit.

## 2. `void make auth` — the sign-in

```sh
void make auth
```

Register, sign in, sign out, password reset and address verification,
plus a generated suite that drives all of them through `test/inject`.
The machinery underneath was already composed (`void/auth`, the
identity, the strategies, `challenge!`); what the generator writes is
the part that is the same in every application.

It also **prints three things it did not do**, and that is a decision
rather than a limitation — the FFI driver on one side, and the
generator's own output on the rest:

- the `janet-lang/sqlite3` line for `project.janet`, and why the bundle
  does not carry it,
- the ten plugins and the config block to paste into `main.janet` and
  `config/default.janet`,
- the CSP block that the generated page needs, because `void new`'s
  layout loads htmx from a CDN and `void/security`'s default policy
  refuses it.

`make` writes new files and edits none. A generator that rewrites code
somebody has edited is a generator nobody runs twice.

**Cost: one command and three pastes.** All three are printed, in
order, with reasons. Two of the three exist because this application
complained: the CSP block and the dependency line were folklore before
the hub was written.

## 3. The domain, in the layout the project picked

void has no module system of its own — no registry, no directory scan —
so the layout is the example's to choose, and both `examples/shop` and
`examples/hub` choose the same one: a module is a directory, a suffix
is a layer (`*.model`, `*.repository`, `*.service`, `*.controller`,
`*.view`, `*.admin`, `*.policy`, and for the hub one more, `*.channel`).

For a webhook hub that is four modules and about 900 lines:

| module | what it is |
|---|---|
| `intake/` | the route, the signature, the store, the row — and replay |
| `routing/` | rules as data, matching as a pure function, one notification per matching rule |
| `telegram/` | the notify channel this application wrote |
| `ops/` | `/` as the jobs dashboard, and `void hub replay` |

**Cost: the application.** This is the part that is the work, and the
only honest thing to say about its size is that everything around it
was composed rather than written.

## 4. Receiving, in the order that is the design

Four framework pieces, one line of composition each: `void/http` for the
route, `void/crypto` for the HMAC over the raw bytes (`crypto/equal?`,
not `=`), `void/storage` for the body, `void/db` for the row.

Two things the framework made cheap and one it made impossible to get
wrong:

- **A route says its own body ceiling.** GitHub sends up to 25 MiB;
  every other route in this application keeps 64 KiB without a word,
  because `:void.http/max-body` is route metadata and `[:http
  :max-body]` is what a route that declares nothing gets.
- **A burst is shed rather than queued in the kernel** — `void/pressure`,
  one plugin.
- **Idempotency is a unique column**, not a check in the handler. Two
  workers can be inside the handler at once and only one of them can
  hold that index.

## 5. Where a delivery goes: rules as data

A rule is a table; matching is a pure function of two values; every
matching rule is its own notification. The test for all of it boots
nothing — it is a table of examples.

## 6. The outgoing channel: two functions

telegram is not in void, on purpose, and adding it is a contribution
with two functions: `project` builds a chat and a string where the
request is, `deliver` posts it where the network is. The queue fits
between them, which is why a retry delivers the value the request meant.
`void/tls` is what makes the https call possible, and it is one line of
composition.

**Cost: 160 lines**, of which about 40 are the retry policy — which
statuses mean "no" and which mean "later".

## 7. The desk, which is not written

Two screens, and neither is a page this application wrote:

- `/` is the **jobs dashboard** `void/admin-jobs` contributes — the
  question a hub is asked at three in the morning is "did it go out",
  and that is a question about the queue.
- `/admin/deliveries` is `defentity` projected — one
  declaration naming the columns an operator scans, the fields they
  search by, and one widget for the column that is genuinely this
  application's — the storage key, drawn as a five-minute signed link
  to the bytes.

**Cost: 40 lines of declaration**, and the operator list in config.

## 8. `void hub replay` — the step that removes the tunnel

A webhook needs a public hostname, so changing one line of a routing
rule normally costs a tunnel, a repository and somebody to push to it.
Replay routes a kept delivery again from the bytes as they arrived —
and does **not** receive it again. One real delivery has to arrive
once; after that the half with the bugs in it runs as many times as it
takes.

**Cost: 60 lines**, and it is the single best hour this application
spent.

## 9. What the deployment has to answer

```janet
{:deploy {:shape :fleet}}
```

`void deploy check` asks every store in the composition whether a
second replica would see its contents
and refuses to start a `:fleet` that keeps anything in one process's
heap. For the hub that is four answers and each is one line: sessions
in the database, the queue in the database, one-time codes in the
database, bodies in the bucket.

This is the step that is usually a production incident instead of a
line of config, and it is worth being explicit about what it replaces:
a session store that works until the second replica, a rate limit that
silently becomes three times the configured one, an upload that is a
404 on the next request.

## 10. The image

Two stages, `debian:bookworm-slim`, and the second one carries a janet
runtime, the installed tree, three shared libraries and the
application. The build is the same `jpm install` a laptop runs — which
is what makes the image and the "clean machine" CI job the same claim.

**Cost: one Dockerfile**, mostly comments.

## 11. `docker compose up`

Seven services, four of which are the deployment: two web replicas, a
worker, Postgres, a bucket. The other three are the proxy that holds the
TLS (void serves plain HTTP and something in front terminates), a
one-shot that creates the bucket, and a one-shot that runs the
migrations.

The worker is **the same image running one command** — `janet main.janet
jobs work` — and it opens no port. What it starts is the union of what
the jobs on its queues declared they need, which for this application
is the TLS stack, because a telegram delivery is https and a queue does
not depend on libssl.

Two environment variables are the whole difference between the laptop
and this: `VOID_HUB_DB=postgres` and `VOID_HUB_STORAGE=s3`.

## 12. Pointing a repository at it

A domain, a webhook with a secret, and TLS the sender can verify. Caddy
gets a real certificate for a real name; on a laptop it issues one from
its own CA, which is enough for `curl -k` and not enough for GitHub —
a fact worth knowing before the first delivery does not arrive.

## 13. The three things that went wrong

All three were the framework's, all three were found by deploying
rather than by testing, and all three are fixed:

- **`[:pressure :max-rss-bytes]` could not trip on Linux.** The
  `/proc/self/status` parser sliced fixed offsets and read `5324 k` out
  of every real kernel's line, so the reader reported "this platform
  has no RSS meter" — in containers, which is the only place the limit
  matters. The suite was asserting the wrong half: "where there is no
  meter the signal is nil" is true and says nothing.
- **A structured error printed as an address.** `{:status 404 :message
  "…"}` is the shape void's own throws use so that retry logic can read
  a status; at every boundary where a *person* reads — a failed job's
  record, a log line, `void: …` on the terminal — it went through
  `describe` and came out `<struct 0xAAAA…>`. `log/message-of` is the
  fix, and the boundaries now read through it.
- **The bucket store did not declare the library it signs with.** A CLI
  command starts what it declared in `:needs` and that closure;
  `:storage/s3` named no dependency on `:crypto/lib`, so `void hub
  replay` against a bucket started a store that could not sign and died
  on the first fetch. One `:deps` line, and the same lesson as the
  worker's `:needs`: the thing that knows what has to be open is the
  thing that needs it.

---

## The number

For one developer who already knows the framework: **an afternoon** —
steps 1–8 — and **an hour** for steps 9–12, of which most is waiting
for a base image. The honest qualifier is that the developer in
question wrote the framework; the reproducible part is not the hours
but the ledger above, and the three bugs in step 13 are what those
hours actually bought.

What the path did **not** require, and this is the claim: no second
language, no node, no message broker, no third-party job runner, no
admin framework, no reverse-proxy config beyond a certificate, and no
library outside the bundle except a database driver's own.
