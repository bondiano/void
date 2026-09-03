#!/usr/bin/env bash
### The reference-environment calibration run.
###
### Shared CI runners are only trusted with *relative* numbers; the
### absolute budgets of §8.2 (docs/BENCH-v0.1.md) want one clean
### machine of the class §9 targets — a small VPS — measured once per
### release. This script is that run as one command: it sets a clean
### Ubuntu 24.04 host up (janet, jpm, the one native module, wrk,
### wrk2, a local Postgres, the Go and FastAPI baselines) and drives
### the full method — 3×60s per mode, warmup, all targets including
### the baselines — writing the result set where the repository keeps
### them.
###
###     git clone https://github.com/bondiano/void && cd void
###     ./scripts/bench-reference.sh                 # setup + measure
###     SKIP_SETUP=1 ./scripts/bench-reference.sh    # measure again
###
### The result lands in bench/results/reference-<host>-<date>.jdn and
### the §8.2 budget verdict is printed at the end (--budgets: any MISS
### is exit 1, so the calibration run *is* the check). To freeze the
### run as the repository baseline afterwards:
###
###     cd bench && janet main.janet budgets results/reference-*.jdn
###     cp results/reference-<host>-<date>.jdn results/baseline.jdn
###
### Numbers move into docs/BENCH-v0.1.md by hand, next to the
### the method — that edit is the point of the exercise, not a side
### effect this script hides.

set -euo pipefail
cd "$(dirname "$0")/.."

JANET_VERSION="${JANET_VERSION:-v1.41.2}"
PG_DSN="${VOID_BENCH_PG:-host=127.0.0.1 port=5432 user=void password=void dbname=void_bench}"

setup() {
  echo "== packages"
  sudo apt-get update
  sudo apt-get install -y build-essential git curl \
    libpq5 libssl-dev libssl3 \
    postgresql \
    wrk \
    golang-go \
    python3-venv python3-pip

  if ! command -v janet >/dev/null || [ "$(janet -v)" != "${JANET_VERSION#v}" ]; then
    echo "== janet ${JANET_VERSION}"
    rm -rf /tmp/janet
    git clone --depth 1 --branch "$JANET_VERSION" https://github.com/janet-lang/janet /tmp/janet
    make -C /tmp/janet -j"$(nproc)"
    sudo make -C /tmp/janet install
  fi

  if ! command -v jpm >/dev/null; then
    echo "== jpm"
    rm -rf /tmp/jpm
    git clone --depth 1 https://github.com/janet-lang/jpm /tmp/jpm
    (cd /tmp/jpm && sudo janet bootstrap.janet)
  fi

  echo "== dependencies and the native module"
  (cd dev && sudo jpm deps)
  (cd fdwait && jpm build)

  if ! command -v wrk2 >/dev/null; then
    echo "== wrk2"
    rm -rf /tmp/wrk2
    git clone --depth 1 https://github.com/giltene/wrk2 /tmp/wrk2
    make -C /tmp/wrk2 -j"$(nproc)"
    sudo cp /tmp/wrk2/wrk /usr/local/bin/wrk2
  fi

  echo "== postgres (B2/B3 are a database benchmark or they are nothing)"
  sudo systemctl start postgresql
  sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='void'" | grep -q 1 ||
    sudo -u postgres psql -c "CREATE ROLE void LOGIN PASSWORD 'void'"
  sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='void_bench'" | grep -q 1 ||
    sudo -u postgres createdb -O void void_bench

  echo "== fastapi baseline venv"
  (cd bench/baselines/fastapi &&
    python3 -m venv .venv &&
    ./.venv/bin/pip install -q -r requirements.txt)
}

if [ -z "${SKIP_SETUP:-}" ]; then
  setup
fi

# the fastapi target runs bare `python3` — put the venv first
export PATH="$PWD/bench/baselines/fastapi/.venv/bin:$PATH"
export VOID_BENCH_PG="$PG_DSN"

# B4 opens a thousand sockets from one process, plus the server's own
ulimit -n 8192 || true

host="$(hostname -s)"
stamp="$(date +%Y%m%d)"
out="results/reference-${host}-${stamp}.jdn"

echo "== the full method: 3×60s per mode, all targets (baselines included in 'all')"
echo "   (machine facts worth writing down next to the numbers:)"
nproc; grep -m1 "model name" /proc/cpuinfo 2>/dev/null || true
free -h | head -2 || true

cd bench
janet main.janet all --runs 3 --duration 60 --warmup 30 --out "$out"

echo "== §8.2 budget verdict (a MISS here is the calibration's finding, not a failure of the run)"
janet main.janet budgets "$out" || true

echo
echo "results: bench/$out"
echo "next: numbers into docs/BENCH-v0.1.md; optionally freeze as bench/results/baseline.jdn"
