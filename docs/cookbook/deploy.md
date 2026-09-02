# Deploy: one binary, or compose

Two shapes, one application. A single process deploys as one file with
nothing installed on the target; a fleet deploys as `docker compose up`
with the shape declared and checked. The full story with the measured
sizes and the rules is [DEPLOY.md](../DEPLOY.md); the deployed example
is [examples/hub](../../examples/hub).

## One file

```sh
jpm --local build
VOID_PROFILE=prod VOID_HTTP__PORT=8080 ./build/myapp
```

Measured (DEPLOY.md): the scaffold carrying its own CLI is **1.14 MB**;
with `void/db` and sqlite compiled in, **2.35 MB**. No janet, no
source tree, no `jpm_tree` on the target. FFI libraries (libpq,
libssl, librdkafka) stay the *target's* — opened at start from a
configured path, a missing one is a boot error naming where it looked.

The binary is also the CLI — the entrypoint `void new` writes calls
`cli/app-main`, so:

```sh
./build/myapp db migrate   # migrations on the server, same composition
./build/myapp routes       # the binary agrees about the route table
./build/myapp plugins check
```

Ship `db/migrations/` beside the binary — migrations are read at run
time. The four rules that keep a project buildable (read the
environment in `main`, not in a value; prod composition drops
`void/dev`; config from env or a shipped directory; natives in, FFI
out) are each a section of [DEPLOY.md](../DEPLOY.md), with what breaks
if you skip them.

## Compose: the fleet shape

[examples/hub/docker-compose.yml](../../examples/hub/docker-compose.yml)
is a deployment rather than a demo — the shape to crib:

- **web × 2 replicas** — which is what makes
  `[:deploy :shape] :fleet` the truth rather than a setting;
- **worker** — the *same image*, different command
  (`janet main.janet jobs work`);
- **postgres** — deliveries, queue, sessions and accounts in one
  database, so a delivery and the work it caused commit together;
- **minio** — a private bucket for raw payload bodies (a disk is one
  machine's disk; a `:fleet` boot refuses a per-process store and
  names the bucket);
- **caddy** — the TLS lives at the edge (ADR-0010); void serves plain
  HTTP behind it;
- one-shot **migrate** and **createbucket** services — schema is
  deployed the way tables are.

Configuration rides the environment
(`VOID_DB_POSTGRES__URL` → `[:db-postgres :url]`), secrets are
`{:secret "…"}` boxes that never print, and `VOID_PROFILE=prod` flips
the profile — the same image runs every role.

## The check before, not the incident after

```sh
void deploy check
```

surveys every store the composition holds and answers whether this
build fits `[:deploy :shape]`: a fleet composed over an in-memory
session store or an on-disk upload store is an error *printed before
the deploy*, naming what to compose instead — the same verdict boot
would reach, moved earlier. Put it next to `void plugins check` in CI.
