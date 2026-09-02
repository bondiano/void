# Getting started

From `jpm install` to a deployable binary in about fifteen minutes.
Every command below is real: the outputs shown are what the CLI prints
today, and the same path runs on a clean machine as a CI job rather
than as a paragraph here (ADR-0020). If something on this page
disagrees with your terminal, the terminal is right and this page has
a bug — [please say so](https://github.com/bondiano/void/issues).

What you need first: [Janet](https://janet-lang.org/) ≥ 1.41, jpm and
a C compiler (spork builds nine native modules of its own, and void
adds one — `void/fdwait`, ~60 lines).

## 1. Install the framework

```sh
jpm install https://github.com/bondiano/void.git
```

One bundle: the whole framework — thirty-odd packages — installs as a
single jpm dependency named `void`, and the `void` binary lands on
your PATH.

## 2. Create a project

```sh
void new demo
```

    created demo/project.janet
    created demo/main.janet
    created demo/app.janet
    created demo/config/dev.janet
    created demo/config/prod.janet
    created demo/docker-compose.dev.yml
    created demo/test/smoke-test.janet
    created demo/.gitignore
    created demo/README.md

      cd demo && void dev

A handful of small files, and each one earns its place:

- `project.janet` — one dependency (`void`), and a
  `declare-executable` so that `jpm build` later produces the single
  binary of [DEPLOY.md](DEPLOY.md).
- `main.janet` — the boot options: a `def app` with the `:plugins`
  list, and a `main` that reads the profile from the environment *at
  run time*, because `jpm build` marshals values into the executable
  and a profile computed in a value would be the build machine's.
- `app.janet` — the application plugin: a schema, views as plain
  functions returning hiccup, handlers, and a `defroutes` that
  registers handlers as *symbols*, which is what makes them
  hot-swappable.
- `config/dev.janet` and `config/prod.janet` — the file layer of the
  config chain (plugin defaults ← config files ← `VOID_*` env vars ←
  CLI flags), one file per profile.
- `test/smoke-test.janet` — a first test that drives the app through
  `test/inject`, the full middleware stack in memory with no socket.
- `docker-compose.dev.yml` — the dev services (a database and
  friends) for when the app outgrows in-memory state; `void dev` works
  without it.

Pin this void in the project's own tree (the binary prefers it):

```sh
cd demo
jpm --local deps
```

## 3. Run it

```sh
void dev
```

    Starting networked repl server on unix, port .void/repl.sock...
    20:33:57 INFO  void.dev — listening on http://127.0.0.1:8080

    void :dev — 5 plugins, 5 components
    shape   :single (the :dev default)
    stores  none — nothing this composition keeps outlives a request

Open <http://127.0.0.1:8080>: a server-rendered HTMX guestbook. One
map schema (`Entry` in `app.janet`) drives the form markup, the
coercing validation and the re-render-with-errors loop — submit an
empty form and watch the field errors come back without a full page
load.

Now edit `app.janet` while `void dev` runs. Handler changes are live
(the router holds symbols, not functions); adding a route or changing
route metadata rebuilds the route table on the fly. The dev profile
also runs a netrepl into the running process:

```sh
void repl    # in a second terminal: a REPL inside the live app
```

## 4. Read the route table

```sh
void routes
```

    GET   /         :home            home          :demo/routes
    POST  /entries  :entries/create  create-entry  :demo/routes

Routes are data. `void routes --keys` adds the metadata; later,
`void authz routes` will show which policy guards each one.

## 5. Scaffold a resource

```sh
void make resource note title:string body:text
```

    created resources/notes.janet
    created db/migrations/20260902203340_create_notes.janet
    created test/notes-test.janet

      add to :plugins in main.janet:

        :demo/notes               the routes, the entity and the views
        :void/db :void/db-sqlite  the entity layer and a driver, if not there yet

      then:

        void db migrate
        void dev                 # /notes

Three files that are three projections of one declaration: the
`defentity` at the top of `resources/notes.janet` is the schema *and*
the db mapping, the form is projected off it, the migration creates
exactly its columns — and the generated suite fails if a later edit
makes them disagree.

Note what did *not* happen: `void make` never edits a file you own.
It printed the two edits instead. Make them — in `main.janet`:

```janet
(import void/db)
(import void/db-sqlite)
(import ./resources/notes)

(def app
  {:plugins [:void/http :void/html :void/htmx :void/dev :demo/app
             :void/db :void/db-sqlite :demo/notes]})
```

The sqlite driver resolves the `janet-lang/sqlite3` binding at first
use, and the void bundle leaves that binding out on purpose
(ADR-0011): the application that opts into the driver declares it. Add
it to `:dependencies` in `project.janet` and fetch:

```janet
:dependencies ["https://github.com/bondiano/void.git"
               "https://github.com/janet-lang/sqlite3.git"]
```

```sh
jpm --local deps
void db migrate
```

    applied 20260902203340_create_notes

`void dev` again, and <http://127.0.0.1:8080/notes> is a full CRUD —
index, new, show, edit, delete — every action a named route:

    GET   /notes             :notes/index     index          :demo/notes-routes
    POST  /notes             :notes/create    create         :demo/notes-routes
    GET   /notes/:id         :notes/show      show           :demo/notes-routes
    ...

## 6. Scaffold authentication

```sh
void make auth
```

    created auth.janet
    created db/migrations/20260902203347_create_users.janet
    created test/auth-test.janet

Register, sign in, sign out, a password reset and an address
verification — five pages every application used to write by hand,
projected over `void/auth`, with a suite that drives all of them
through a real database and no sockets.

After the file list the generator prints, in full, the three edits it
deliberately did not make for you: the driver dependency in
`project.janet`, six plugin lines for `main.janet`, and a config block
for `config/dev.janet` — including the CSP policy whose absence would
otherwise surface only as a silent browser-console error. Follow the
printed report, then:

```sh
void db migrate
void dev       # /register
```

## 7. Lock the composition

```sh
void plugins lock
```

    wrote void.lock
    8 plugins, 19 extension points, 7 components — 490e814c89d2524d

`void.lock` is the composition as a value — every extension point with
its contributions in resolution order. Commit it, and put
`void plugins check` in CI: "why is the middleware stack different in
production" becomes a diff, not an investigation.

## 8. Ship one file

```sh
jpm --local build
VOID_PROFILE=prod VOID_HTTP__PORT=8080 ./build/demo
```

`build/demo` is a single binary — a couple of megabytes, no janet and
no source tree on the target. It is also the CLI: with no arguments it
runs the app; with arguments it *is* the `void` binary, against
exactly the composition inside the executable —

```sh
./build/demo db migrate    # on the server, before first start
./build/demo routes        # the binary agrees about the route table
```

The measured sizes, the four rules that keep a project buildable and
the pre-deploy checklist are in [DEPLOY.md](DEPLOY.md). When one
process stops being enough, `[:deploy :shape] :fleet` plus
`void deploy check` tells you *before* the deploy which stores need to
be shared — and
[`examples/hub`](../examples/hub) is a complete
`docker compose up` deployment to crib from: two web replicas, a
worker running the same image, Postgres, a bucket and a proxy holding
the TLS.

## Where next

- The [cookbook](cookbook/README.md) — short, verified recipes:
  forms and htmx, background jobs, auth flows, deploy shapes.
- The [module reference](https://bondiano.github.io/void/modules/) —
  every package's plugins, config, extension points and public
  functions, projected from the code.
- [IDEA-TO-DEPLOY.md](IDEA-TO-DEPLOY.md) — the same path as this
  page, continued all the way to a deployed application, with the cost
  of every step written down.
- [SPEC.md](SPEC.md) — the full specification, if you want to know
  why rather than how.
