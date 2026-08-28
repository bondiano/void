# void bench-suite

Performance is a CI contract, not a hope (SPEC §8, ADR-0014). This
package holds the B\* benchmark mini-apps, the load-generation
методика, the calibration baselines and the 5% regression thresholds.

## Quick start

```sh
cd bench
janet main.janet                 # B0 + B1, full методика (≈8 min)
janet main.janet b0 --quick      # smoke profile: warmup 3s, 2×5s
janet main.janet all             # + Go and FastAPI baselines
janet main.janet list            # what exists
void bench b0 b1                 # the same through the void CLI
```

Tools: [`wrk`](https://github.com/wg/wrk) for max throughput,
[`wrk2`](https://github.com/giltene/wrk2) for latency under a fixed
rate — **wrk2 is mandatory for latency numbers** (plain wrk under
closed-loop load suffers coordinated omission and reports fictional
tails). A missing tool skips its mode with a warning, never fakes it.
Override the binaries with `VOID_BENCH_WRK` / `VOID_BENCH_WRK2` (a
multi-word value like `taskset -c 0 wrk` works), or build both in a
container next to the apps:

```sh
docker build -t void-bench-loadgen loadgen
docker run --rm --network host -v "$PWD:/bench" \
  -e BENCH_BODY_FILE=/bench/payloads/b1-order.json void-bench-loadgen \
  wrk2 -t4 -c64 -d60s -R16000 --latency http://127.0.0.1:8100/
```

(`--network host` is Linux-only; on macOS target `host.docker.internal`.)

## Методика (SPEC §8.3)

Encoded in `void/bench/runner.janet`, per target:

1. the app starts as a subprocess (`PORT`, `GOMAXPROCS=1` — budgets
   are per 1 worker / 1 vCPU), readiness = TCP accept;
2. warmup 30s (route table, prepared statements, JIT-less caches);
3. 3×60s per mode, **median** of the runs per metric;
4. environment is recorded with the numbers: janet version, CPU,
   frequency governor, commit.

Modes: max throughput (`wrk -t4 -c64`) and latency under wrk2's fixed
`-R` rate set at 80% of the §8.2 throughput floor — latency at
saturation is meaningless. Results land in `results/last.jdn`.

## Benchmarks and budgets (§8.2, 1 worker / 1 vCPU)

| Target | What it measures | Budget p50 | Budget p99 | Floor |
|---|---|---|---|---|
| `b0` | plaintext hello through router + full middleware stack | < 2 ms | < 3 ms | ≥ 20k RPS |
| `b1` | JSON echo 1KB: codec parse + schema validate + serialize (void/rest) | < 2.5 ms | < 10 ms | ≥ 8k RPS |
| `b2` | Postgres single query: pool, prepared statement, ev loop | < 3 ms | < 12 ms | ≥ 3k RPS |
| `b3` | Postgres + hiccup SSR ~15KB — the shape a void app actually is | < 5 ms | < 20 ms | ≥ 1.5k RPS |

Every budgeted target also carries the two budgets nothing outside the
process can see: **loop-lag p99 < 1 ms** under target load (§8.2, §8.4
— "the main health indicator of an ev system"), and, on `b3`, **GC max
pause < 10 ms**. Both come from `void/bench/probe`, a fiber inside the
app sampling the lag it is actually experiencing, read off
`/void/bench/probe` around the fixed-rate runs. The GC number rides on
loop-lag's *maximum* on purpose: janet 1.41 reports no GC pause of its
own, but a stop-the-world collection on a single-threaded loop **is**
loop lag of at least its own length, so the maximum is a sound upper
bound. §8.2's other GC half ("under 2% of total time") has no such
bound and stays unmeasured. `VOID_BENCH_PROBE=0` runs an app without
the probe — which is how the probe's own cost gets measured.

B4 (WS broadcast) arrives with its wave — a row in
`void/bench/targets.janet`, not new code. The B0/B1 budgets were
verified against the recorded reference environment at v0.1 —
measurements, the b0 p50 adjustment and its reasons live in
[docs/BENCH-v0.1.md](../docs/BENCH-v0.1.md); B2/B3 are §8.2 hypotheses
until the same is done for them. Enforce budgets with `void bench
budgets` (a saved result set) or `--budgets` (after a run); regression
thresholds guard everything else.

## B2 and B3 need a database

```sh
export VOID_BENCH_PG="host=127.0.0.1 port=5432 user=void dbname=void_bench"
janet main.janet b2 b3
```

`VOID_TEST_PG` is the fallback, so a checkout already set up to run the
void/db-postgres suite needs nothing further. Without either, `b2` and
`b3` **skip themselves loudly** rather than run against an imaginary
server. The table they read (`bench_rows`, 10k rows) is created and
seeded by the apps at `:after-start`, idempotently — a benchmark whose
setup is a README step is a benchmark that runs against a
differently-shaped table on somebody else's machine.

Both read the same table on purpose: B3 − B2 is the cost of rendering,
and a different query in each would make the delta unreadable.

## Baselines for calibration, not marketing

`baselines/` holds a Go `net/http` server (the ceiling of the class)
and a FastAPI+uvicorn app (the Python interpreter class void competes
in), both serving the same two shapes. They answer one question: are
we in the expected class, or did something break?

```sh
janet main.janet baselines       # go + fastapi targets
```

FastAPI needs `python3 -m pip install -r baselines/fastapi/requirements.txt`.

## Regression thresholds: 5% (ADR-0014)

```sh
janet main.janet b0 b1 --record            # freeze results/baseline.jdn
janet main.janet b0 b1 --check             # exit 1 on any >5% regression
janet main.janet compare base.jdn head.jdn # any two result files
```

Latency percentiles are only compared inside the wrk2 mode, throughput
only inside the wrk mode; latency moves under 0.1 ms absolute are
treated as noise. `results/baseline.jdn` is committed — the reference
numbers from the recorded environment (see its `:env`).

CI (`.github/workflows/bench.yml`) does not trust shared runners with
absolute numbers: it measures the merge-base and the head **on the
same runner in the same job** and applies the 5% thresholds to that
pair. A dedicated runner can later switch CI to the committed baseline.

## Rules for plugin authors (SPEC §8.5)

Every plugin that contributes middleware owes a row in the bench
table: «B1 with my middleware = −X%». Run `b1` with and without your
plugin in the app list and put the delta in your README.

`b1-pressure` is that row for void/pressure, and the pattern to copy:
the same B1 app with `VOID_BENCH_PRESSURE=1`, one plugin heavier, no
budget of its own.

```sh
janet main.janet b1 b1-pressure     # both rows; the delta is the answer
```
