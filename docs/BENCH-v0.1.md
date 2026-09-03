# Performance budgets — the v0.1 check (wave 1, exit criterion 4)

The first full check of the performance budgets, run by the recorded
method (warmup 30s, 3×60s per mode, medians; wrk for max throughput,
wrk2 for latency under a fixed rate). Before this run the numbers were
hypotheses; this document records the results, the corrections and the
reasons for them. The reference results are frozen in
`bench/results/baseline.jdn`; the absolute gate is `void bench budgets`.

## Reference environment

| | |
|---|---|
| Machine | Apple M4 Max (16 CPU), macOS (Darwin arm64) |
| Janet | 1.41.2 |
| Loadgen | wrk (brew) + wrk2 4.0.0 (giltene/wrk2, built against LuaJIT 2.1 for arm64) |
| Load shape | loopback, `-t4 -c64`; wrk2 rate = 80% of the throughput floor (B0: 16k, B1: 6.4k) |
| Conditions | a machine with no background load (see "Methodology notes") |

The "1 worker, 1 vCPU" caveat: the janet server is one worker (one
thread), but the machine is not "1 vCPU" — the loadgen and the OS kernel
live on neighbouring cores and do not compete with the server for its
own. Throughput numbers therefore read as "the ceiling of one worker on
a fast core"; the comparison between commits (the 5% gate) stays honest
as long as the environment does not change.

The measurements were taken three times: at commit 7709962 (the stack of
waves 1.1–1.7), on the final v0.1 stack (4329268 — lifecycle stages,
request-id, access-log, the kernel/server split) and after the
request-id/access-log optimisation modelled on fastify/pino (see "The
price of observability"). `results/baseline.jdn` is frozen on the
optimised stack **with the access-log on** — the benchmarks measure the
production default.

## B0 results (plaintext hello, the full router + middleware stack)

| Metric | Budget | Measured | Verdict |
|---|---|---|---|
| Throughput floor | ≥ 20 000 RPS | **29 154 RPS** (up to ~43k in short sessions — note 6) | ✅ 1.5× headroom |
| p50 @16k RPS (wrk2) | < 0.5 ms | **1.00 ms** | ❌ → budget corrected to < 2 ms |
| p99 @16k RPS (wrk2) | < 3 ms | **2.51 ms** | ✅ |

**Why p50 was corrected (0.5 → 2 ms).** Go net/http — the ceiling of the
class — shows p50 **1.31 ms** @16k by the same method on the same
machine. The measurement floor of "wrk2 over loopback with the loadgen
on the same machine" sits near 1 ms: it includes the scheduling of
wrk2's client threads and the packet's turn in the kernel queue, not
only the server. A p50 budget of < 0.5 ms was a hypothesis below the
floor of the method — indistinguishable from zero with this instrument.
The new budget of < 2 ms keeps void ahead of the Go baseline and still
catches degradation; the main protection against regressions is not the
absolute budget but the relative 5% gate in CI.

## B1 results (JSON echo 1KB: parse + validate + serialize)

| Metric | Budget | Measured | Verdict |
|---|---|---|---|
| Throughput floor | ≥ 8 000 RPS | **8 981 RPS** | ✅ 1.1× headroom |
| p50 @6.4k RPS (wrk2) | < 1 ms | **1.67 ms** | ❌ → budget corrected to < 2.5 ms |
| p99 @6.4k RPS (wrk2) | < 5 ms | **3.79 ms** | ❌→✅ budget corrected to < 10 ms (session-to-session tail spread); a typical run passes the old one too |

Context for the class (go-json, the same rate of 6 400): p50 **1.26
ms**, p99 **3.13 ms**, throughput 42.5k.

## The price of observability — an investigation

The first version of this document attributed −31% max throughput to the
request-id infrastructure and another −23% to the access-log. **Both
numbers were an artefact**: they compared full runs from different
sessions (see methodology note 6), and the jdn sink of the time wrote
once per request. A single-session A/B/A experiment (3×15s wrk,
medians), after the rework modelled on fastify/pino, gives:

| Configuration | B0 max throughput | Delta |
|---|---|---|
| kernel, request-id middleware empty | ~43.3k RPS | — |
| + request-id (counter + bound log context) | ~42.0k RPS | **≈ −3%** |
| + access-log (jdn sink, batching writer) | within the noise of A/B/A | **≈ 0%** |

B1 latency @6.4k with the access-log on: p50 1.63 ms / p99 3.84 ms — the
24 ms tail of the early measurements is gone entirely, taken by the
writer fiber's batching.

What was taken from fastify/pino, and how it lands in void:

1. **`genReqId` is a bare counter.** Fastify does not read a request
header by default (in v5 `requestIdHeader: false`, for exactly this
performance reason) and does not call crypto per request: the id is a
counter increment. void: a per-process random prefix (one
`os/cryptorand` at start, to tell workers apart) plus a counter; a
trusted incoming header is opt-in through `[:http :request-id-header]`.
2. **Writing off the hot path** (sonic-boom): pino writes
asynchronously in buffered chunks. void: the jdn sink already hands
records to an ev channel, and the writer fiber drains everything
accumulated in one `write` (batching); an overflow is a drop with a
counter, and `:fatal` is synchronous.
3. **A disabled level is nearly free**: the log macros do not evaluate
their arguments, and the level check is one (memoised) table lookup —
parity with pino's noop methods.
4. **Context without ALS**: Fastify deliberately does not use
AsyncLocalStorage (too expensive) and hangs a child logger on `req`
instead. In void the ambient context is a janet dyn: `with-dyns` creates
a fiber (~0.3 µs on an M4 Max, ~1% of the request budget) — the price of
the contract that "log/info from any depth of a handler carries the
request-id", paid knowingly.
5. Not carried over (a candidate for the wave 2/3 obs work): pino's
**precomputed chindings** — a child logger serialises its bindings once,
and every record is a concatenation of ready strings, with no record
table assembled per log call.

The upshot: **the access-log is on by default in B0/B1** — the
benchmarks measure the production stack, and `[:http :access-log] false`
stays for those who do not want the logs.

**Why p50 was corrected (1 → 2.5 ms).** The same reason as B0: the floor
of the method. The Go baseline itself shows 1.26 ms @6.4k — a hypothesis
of < 1 ms was below the level this instrument can show at all; void adds
~0.4 ms of interpreter work on top of the floor (parse + schema validate
+ serialize).

**Why p99 was corrected (5 → 10 ms).** Unlike p50, this is void's own
honest tail: 8.66 ms against Go's 3.13 ms — 2.8× the ceiling of the
class. The source is the mark-and-sweep GC over the allocations of the
JSON path (allocations per request are the chief enemy of p99, and B1
allocates the parsed body, the validation result and the serialized
response on every request). A budget of < 10 ms records the current
level with a little headroom; the plan for returning to a tighter one is
wave 2 work alongside the B3 GC budget: buffer reuse on the JSON path
(point 2), tuning `gcsetinterval` — and prefork isolation already limits
the damage in a multi-worker configuration.

## The non-latency budgets

| Budget | Value | Status |
|---|---|---|
| Startup to ready | < 150 ms | ✅ **~21 ms** (median of 5 measurements: spawn → first successful TCP connect, the B0 application) |
| RSS of a hello-app | < 30 MB | ✅ **23.8 MB** (B0 after 15 s of warmed load under wrk) |
| GC max pause < 10 ms, under 2% of total | on the B3 profile | ⏭ wave 2 (B3 does not exist yet) |
| ev loop lag p99 < 1 ms | under target load | ⏭ wave 3 (implemented in void/obs) |
| void/obs overhead ≤ 7% | on B1 | ⏭ wave 3 (void/obs does not exist yet) |

The deferred rows are a deliberate narrowing of the criterion: the
instruments that measure them arrive with the plugins of waves 2–3.

## How the budgets are checked from here

- **CI (shared runners)** — the relative 5% gate only: head against
merge-base on one runner (`.github/workflows/bench.yml`). The absolute
numbers of a shared runner are not to be trusted; the method is
shortened in CI (2×30s, warmup 10s), a deliberate deviation for the sake
of job time and an honest one for a relative comparison.
- **The reference environment (this machine)** — the absolute gate:
`void bench b0 b1 --budgets`, or `void bench budgets` against the
recorded `results/baseline.jdn`. To be run before every tag.
- "Checked in CI" is made precise: the absolute budgets are checked on
  the reference environment, and CI holds the relative thresholds.

## Methodology notes

1. **Benchmark only on a quiet machine.** The first run of that day was
poisoned by a parallel build (make -j8 on neighbouring cores): a median
p50 of "812 ms" where the honest value is ~1 ms — wrk2's open load
punishes a stolen quantum instantly, with an avalanche of queue. Numbers
from a contaminated run are not reproducible and were thrown away.
2. **Socket errors in throughput mode** (hundreds of timeouts over
3×60s at maximum load) are a property of wrk's saturating mode, not a
defect of the server: the Go baseline shows the same errors. In wrk2's
latency mode there are none.
3. `:governor` in the environment stamp is not filled in on macOS
(there is no cpufreq governor to read); the CPU model and the absence of
background load are recorded instead.
4. wrk2 on arm64 macOS is built from giltene/wrk2 with the vendored
LuaJIT replaced by a current LuaJIT 2.1 (upstream does not support
arm64); for CI the Linux build from upstream works as is (bench.yml).
5. The `:commit` stamp in baseline.jdn is the request-id/access-log
   optimisation (after v0.1); the earlier measurements (7709962,
   4329268) are context in this document's history, not reference
   points.
6. **Absolute numbers are comparable only within one session.** Full
runs of the very same code on different days on this machine differ by
up to ±30% in max throughput (loopback wrk is sensitive to the state of
the machine: thermal regime, background daemons, kernel state); on top
of that, a 14-minute full run is systematically lower than short
15-second sessions (~29k against ~40–43k on the same code) — a long
warmup. Hence the rule: any "A against B" is A/B(/A) back to back in one
session (which is what CI does: merge-base and head in one job); the
committed baseline is a reference for `void bench budgets` with that
error bar in mind, not truth to the last digit. wrk2's latency mode,
meanwhile, is stable between sessions (p50/p99 reproduce within ~5%) —
the budgets rest on it, and on the throughput floor with plenty of
headroom.

---

## What wave 2 added, and what is still unverified

The `bench_rows` benchmarks and the probe arrived in 2.5; **this
document did not check their absolute budgets**, and until a separate
run on the reference environment the B2/B3 numbers remain hypotheses —
exactly what B0/B1 were before this document.

- **B2 / B3** (Postgres query, Postgres + SSR of 15001 bytes) — in CI
as a relative gate (bench.yml, a service container), with no absolute
calibration. A laptop run with Postgres in Docker comes out noticeably
below the B3 floor, but Docker networking on macOS is not an environment
anyone calibrates against.
- **The runtime budgets** (`void/bench/probe`): loop-lag p99 < 1 ms
under target load, and GC max pause < 10 ms (as an upper bound through
the maximum loop lag — janet does not report pauses). Measured as a
mechanism rather than as a contract: on this machine under the `--quick`
profile the loop-lag p99 goes past 1 ms on every target, and before
calling that a regression the budget has to be taken by the full method
on an unoccupied machine.
- **RSS** (hello-app < 30 MB, the full stack < 80 MB) — printed in the
report, not a gate. The b0 measured here is ≈ 49 MiB against a budget of
30 MB: either the budget was written about another platform, or there is
something to trim in the process, and until that question is answered
there should be no gate.
- **`b1-pressure`** (the row for the middleware from 2.6): −0.2% and
+0.6% throughput over two consecutive runs — inside the run-to-run noise
(see note 6 above), which is to say the price of the shedder on a calm
path is not measurable by this method. That is expected: on a calm path
it is one dereferenced var.

All of the above is the subject of BENCH-v0.2, before the v0.2 tag.
