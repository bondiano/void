# void/dash — the dev dashboard as a projection

Phoenix has LiveDashboard and Clojure has Portal; void's kernel already
answers everything either of them shows — as plain data, to a REPL, to
Prometheus, to an agent over MCP and to the CLI. This package is the
**fourth projection** of the same values: HTML, under `[:dash :prefix]`
(default `/dash`).

```janet
{:plugins [:void/http :void/html :void/htmx :void/dash ...]}
```

Open `http://localhost:8080/dash` in the `:dev` profile. That is the
whole of the setup.

## The pages

| Page | The value it projects |
|---|---|
| Overview | `plugin/health` (the same fold `GET /health` and void/mcp answer with), component health tiles, uptime, sparklines over dash's own samples, `:void.dash/tile` contributions |
| Components | `boot :system` — the graph in topological order; `plugin/why` on click |
| Plugins | `plugin/inspect` — every plugin, every extension point, every contribution with the plugin it came from, and the folded value |
| Config | `config/explain` — every value with the layer that set it; secrets are boxes and print as `@{:secret "NAME"}`, safe by construction |
| Routes | the live route table; opening a line is `explain-route`: every metadata key with its origin |
| Deploy | `deploy/survey` — every store the composition keeps, and whether a second replica would see it |
| Logs | the last `[:dash :log-buffer]` records (a ring sink on `:void.core/log-sink` — the buffer `log/emit` never had), level/namespace filters, an SSE live tail, and runtime per-namespace levels |
| Tap | `(dash/tap value)` from code or the netrepl — a ring of values, each a lazily-unfolding tree, a table when it is an array of maps, copyable as JDN |

## Degradation by composition

The package's edges are `void/core`, `void/http`, `void/html`,
`void/htmx` — and `void/datastar` as a *module* edge (the
`void/storage/sign` pose). Everything else is read **through the boot
value**: the RSS/loop-lag card reads the `:obs/registry` component's
own `:health`, the pressure card reads `:pressure/sampler`'s,
connections read `:http/server`'s. A composition without one of them
gets a sentence naming the plugin that would fill the section — never
an empty box, never an import.

With `:void/datastar` composed, the Overview and Logs pages ride a
morph-stream: the page re-renders whole and Datastar morphs the delta —
the Datastar idiom, on its first real consumer. Without it, htmx polls
every 5 seconds — the same data, a moment later.

## Access

- `:dev` — open. The netrepl logic: a dev process already hands an
  unauthenticated REPL to whoever can reach it; a read-only page of the
  same values adds nothing.
- any other profile — **shut**. Every route answers 403 until
  `[:dash :access]` names a predicate:

  ```janet
  {:dash {:access (fn [req] (operator? req))}}
  ```

- pages are read-only. The one action — runtime log levels — sits
  separately behind `[:dash :allow-actions]` (true in `:dev`, false
  everywhere else).

## Memory

Three rings, fixed by construction: `[:dash :log-buffer]` (500)
records, `[:dash :history]` (`{:interval 5 :samples 360}` — half an
hour) samples for the sparklines, `[:dash :tap-buffer]` (100) tapped
values. The loop lag is measured by the dash's own sampler around its
own sleeps, so the sparkline works with no observability plugin at all.

## What it costs a request

Nothing. `void/dash` contributes **no middleware** and no lifecycle
hooks to the application's request chain — only its own routes under
its own prefix. There is no bench line for the same reason there is no
chain entry: a request that is not for `/dash` never meets this
package. The log-ring sink costs one ring write per *emitted* record
(records below the namespace's level are never emitted at all).

## Tap, from the REPL

```janet
(import void/dash :as dash)

(dash/tap (order-totals basket))   # macro: records value + call site, returns the value
(dash/tap* value "label")          # function: the same, with your own label
```

The value appears on `/dash/tap` with a timestamp and the call site,
unfolds lazily (a ten-megabyte map costs the page only what you open),
and copies out as JDN.
