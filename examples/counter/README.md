# counter
A [void](https://github.com/bondiano/void) application — the wave-5
experiment: a live counter on `void/datastar`, the Biff idiom.

    void dev            # run the app (dev profile: watcher + netrepl)
    void routes         # print the route table
    void repl           # repl into the running process

Open http://localhost:8080 in two windows and press the buttons: every
tab converges on the same count.

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

The price is named in the ADR: every action renders and ships the
whole page. Where that is too dear, the htmx idiom is one import away
— both live on the same `void/html`.

`datastar.js` is an asset of the application, not the plugin — the
layout pulls it from a CDN the way guestbook brings its own htmx.

## Replicas

The stream registry is per process, and that is the design (`:shared?
:by-design` — an SSE connection lives in the process holding its
socket). This example is a single process; behind a load balancer,
fan-out is a `void/bus` subscriber that calls `poke!` locally — three
lines.
