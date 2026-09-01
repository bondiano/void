# Deploying void: one file

SPEC §9 promises a single binary under 5 MB. This is how it is produced,
what it can and cannot contain, and the four things an application has
to do to be one. Everything here is measured on the project `void new`
generates, not estimated.

    jpm --local deps          # once
    jpm --local build         # -> build/myapp
    scp build/myapp target:   # and that is the deploy

The target needs no janet, no jpm, no `jpm_tree` and no source tree. On
macOS arm64 the guestbook scaffold links against `libSystem` and nothing
else:

| what is in it | size |
|---|---|
| the scaffold: http + html + htmx + the app, without a CLI | 1.05 MB |
| the scaffold as `void new` writes it — the same, carrying its own CLI | 1.14 MB |
| the same, plus `void/db` and sqlite compiled in | 2.35 MB |

(macOS arm64, janet 1.41.2. The numbers move with the platform; the
shape of them does not.)

## What `jpm build` actually does

`declare-executable` in `project.janet` runs jpm's `quickbin`: it loads
the entry file, **marshals its `main` function** into a byte array,
emits that array as C, and links it with `libjanet.a` plus the static
half of every native module that was loaded while the entry file was
being read.

Two consequences follow, and between them they are the whole of what
makes an application "buildable":

1. **The top level runs on the machine that builds.** Everything a value
   computes — an `os/getenv`, an `os/time`, a file read — is computed
   once, at build time, and frozen into the executable. A profile
   selected in a `def` is the profile of the CI runner.

2. **Only what is reachable from `main` is in the file, and only
   native modules that were *loaded* are linked in.** There is no
   module tree on the target, so anything resolved at run time with
   `require` is not there — including modules the running code would
   otherwise have found.

## The four rules

### 1. Read the environment in `main`, not in a value

`void new` writes it this way:

```janet
(def app
  {:plugins [:void/http :void/html :void/htmx :void/dev :myapp/app]})

(defn main [& args]
  (def profile (keyword (or (os/getenv "VOID_PROFILE") "dev")))
  (cli/app-main {:plugins (plugins profile) :profile profile} ;(drop 1 args)))
```

`app` stays a plain value, because the `void` CLI reads it; the *choice*
happens inside `main`, where the process actually starts.

### 2. A production composition does not carry `void/dev`

`void/dev` builds its netrepl environment with `require`, which rule 2
above has just taken away. Dropping a plugin from a list is the whole of
the fix, and the generated `main` does it by profile:

```janet
(defn plugins [profile]
  (if (= :prod profile)
    (filter |(not= :void/dev $) (app :plugins))
    (app :plugins)))
```

A binary built without this starts, serves, and then fails when the
netrepl component tries to build an environment — at `:start`, not at
build, which is the worst place to find out.

### 3. Configuration comes from the environment, or from a directory you ship

The config chain (plugin defaults ← config files ← `VOID_*` env vars ←
CLI overrides) is unchanged in a binary, but the *file* layer reads
`config/<profile>.janet` relative to the working directory. A binary
deployed on its own has no such directory, so either ship one beside it
or configure through the environment:

    VOID_PROFILE=prod \
    VOID_HTTP__PORT=8080 \
    VOID_DEPLOY__SHAPE=:single \
    ./myapp

`__` separates nesting levels and `_` inside a segment becomes `-`, so
`VOID_DB__POOL_SIZE` is `[:db :pool-size]`. Values are parsed as Janet
data when they start with one of `{[(:@"` — which is why the shape above
is `:single` and not `single`. A bare `single` is refused at boot, by
name.

### 4. FFI libraries are the target's, native modules are yours

The two ways void reaches C are deployed differently, and the difference
is not a detail:

- **Native modules** (`void/fdwait`, spork's `json`/`crc`/`rawterm`,
  `janet-lang/sqlite3`) are linked *into* the binary — but only the ones
  that were loaded when the entry file was read. `jpm build` prints
  `found native ...` for each; if a module you expect is not on that
  list, it is not in the file.
- **`ffi/`-opened libraries** (`libcrypto` for `void/crypto`,
  `libpq` for `void/db-postgres`, `libmysqlclient` for `void/db-mysql`)
  are opened at `:start` from a
  configured path (ADR-0011, ADR-0022). They are *not* in the binary and
  never will be: the target must have them, exactly as it must for a
  source deploy.

## sqlite in a single binary

`void/db-sqlite` resolves `janet-lang/sqlite3` with `require` on first
use, deliberately: the bundle does not depend on it, so an application
that never lists the plugin never pays for it (ADR-0020). Rule 2 makes
that lazy `require` unreachable in a binary, so the application hands
the module over instead — two lines, in this order:

```janet
(import void/db-sqlite :as db-sqlite)

# at load time: this is what links sqlite3 into the image
(def sqlite3-module (require "sqlite3"))

(defn main [& args]
  # at run time: before anything opens a connection
  (db-sqlite/use-module! sqlite3-module)
  ...)
```

and installs the module into the build tree, since it is not part of the
bundle:

    jpm --local install sqlite3

`jpm build` then prints `found native .../sqlite3.so` and the binary
carries its own database engine.

Postgres and MySQL need none of this: `void/db-postgres` opens `libpq`
— and `void/db-mysql` opens `libmysqlclient`, inside each of its worker
threads (ADR-0033) — through
`ffi/`, so the binary is unchanged and the target provides the library.

## OTLP protobuf in a single binary

The same seam, for the same reason: `void/obs-otlp` requires
`void/obs/otlp-proto` — the module that bakes the vendored OTLP
`.proto` files into descriptors — on first use, so a composition on the
JSON default never parses them. A binary composing
`[:obs-otlp :encoding] :protobuf` hands the module over instead:

```janet
(import void/obs/otlp :as otlp)

# at load time: parses the .proto files on the build machine and
# marshals the descriptors into the image
(def otlp-proto-module (require "void/obs/otlp-proto"))

(defn main [& args]
  (otlp/use-module! otlp-proto-module)
  ...)
```

No extra install: the module and its `.proto` files are part of the
`void` bundle already.

## The binary is also the CLI

`cli/app-main` — what the generated `main` calls — runs the application
when it is given no arguments and *is* the `void` binary when it is
given some, against the composition inside that executable and no other:

    ./myapp                        # serve
    ./myapp db migrate             # apply migrations on the target
    ./myapp routes                 # the route table it will actually serve
    ./myapp deploy check           # fit for [:deploy :shape]?
    ./myapp plugins check          # the composition still matches void.lock
    ./myapp jobs work              # the same file, as a worker

This is the answer to "how do I run migrations where there is no source
tree", and it is why a deployment can be one artifact rather than an
image with a toolchain in it. It works because `app-main` is handed the
boot options directly instead of loading them from a module: there is no
`main.janet` on the target for `load-app` to require, and no need for
one.

Migrations still need their *files* — the migration directory is read at
run time — so ship `db/migrations/` beside the binary, or run
`./myapp db migrate` from a checkout that has them.

## A checklist before the first deploy

    void plugins lock          # commit void.lock; `void plugins check` in CI
    void deploy check          # every store fit for [:deploy :shape]
    void assets build          # compile + fingerprint; writes the manifest
    jpm --local build
    ./build/myapp routes       # the binary agrees about the route table
    ./build/myapp plugins check

`deploy check` matters more here than anywhere else: `[:deploy :shape]`
defaults to `:fleet` in `:prod`, and a composition holding a store in one
process's heap is refused at boot with the replacement named (ADR-0030).
A single-replica deployment says so in one line — the one in the
environment block above.

## What this does not do

- **Cross-compilation.** `jpm build` links with the host's `libjanet.a`
  and the host's compiler, so the binary is for the platform that built
  it. Build in a container matching the target — `examples/shop` ships a
  `Dockerfile` that does exactly this for a source deploy, and the same
  base works for a binary one.
- **Static libc.** The executable is dynamically linked against the
  system C library. On glibc that means the target's glibc must be no
  older than the builder's; a container of the deployment's own
  distribution is the usual answer.
- **Assets.** Files served from disk are still files on disk. Nothing in
  the build embeds a directory of static assets, so `void assets build`
  is a step of its own and its output — `[:html :assets :out]`, the
  fingerprinted copies and the `manifest.jdn` beside them — ships with
  the binary. `html/asset` reads that manifest at `:before-start`; a
  deployment that forgets the step gets dev passthrough URLs and no
  far-future caching, not a broken page.

  The step needs no node and no npm. A stylesheet that has to be
  compiled first is `[:html :assets :tailwind]`, and the compiler is
  tailwind's own standalone binary — `void assets install` puts it in
  `.void/bin` (a build image can cache that directory, or vendor the
  binary and name it in `:bin`). `void assets info` says where it is.
