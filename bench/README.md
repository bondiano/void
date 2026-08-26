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

B2 (PG query), B3 (PG + SSR) and B4 (WS broadcast) arrive with their
waves — each is a row in `void/bench/targets.janet`, not new code.
The B0/B1 budgets were verified against the recorded reference
environment at v0.1 — measurements, the b0 p50 adjustment and its
reasons live in [docs/BENCH-v0.1.md](../docs/BENCH-v0.1.md). Enforce
them with `void bench budgets` (a saved result set) or `--budgets`
(after a run); regression thresholds guard everything else.

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
