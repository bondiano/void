# counter
A [void](https://github.com/bondiano/void) application — the wave-5
experiment: a live counter on `void/datastar`, the Biff idiom.

    void dev            # run the app (dev profile: watcher + netrepl)
    void routes         # print the route table
    void repl           # repl into the running process

Open http://localhost:8080 in two windows and press the buttons: every
tab converges on the same count.

That sentence is the smoke test the suite cannot run: `test/smoke-test.janet`
drives both representations of every handler through `test/inject` and
pokes the real registry, but only a browser proves that `datastar.js`
loads (pinned, with its integrity hash), that `data-init` opens `/live`,
and that a click in one tab morphs the other. It was last run by hand
against Datastar v1.0.0-RC.7 in Chrome — and it is how the attribute
became `data-init`: the bundle has no `load` event, so the earlier
`data-on:load` was a page that polled nothing and never connected,
which every inject test passed.

## The idiom

Every handler here returns the **same full page** — there is no code
answering "what exactly changed":

- a plain browser request gets the HTML document;
- a Datastar request on a route marked `:void.datastar/morph` gets the
  rendered page as two SSE morph events (`<title>` by selector,
  `<body>` by selector) — the browser morphs the live DOM, keeping
  focus, scroll and input state;
- `GET /live` is the push half: `morph-stream` parks the connection in
  the `:counter` room, and every mutation calls `(datastar/poke!
  :counter)` — each stream re-renders *its own* view (identity, locale
  and the rest live in dyns the stream fiber inherited) and pushes the
  same two events. Pokes coalesce by construction: the channel holds
  one wake-up, because the page is state, not a delta.

The price is stated up front: every action renders and ships the
whole page. Where that is too dear, the htmx idiom is one import away
— both live on the same `void/html`.

`datastar.js` is loaded by the application's own layout — the plugin
only supplies the tag, `(datastar/script-tag)`: the pinned file with
its integrity hash, the way admin and dash carry htmx's.

## Replicas

The stream registry is per process, and that is the design (`:shared?
:by-design` — an SSE connection lives in the process holding its
socket). This example is a single process; behind a load balancer,
fan-out is a `void/bus` subscriber that calls `poke!` locally — three
lines.
