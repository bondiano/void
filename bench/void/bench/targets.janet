### void/bench/targets — the bench-suite as data (SPEC.md §8.2-8.3,
### ADR-0014).
###
### Three tables: `benches` are the load shapes (what the generator
### does), `targets` are the servers (what it hits — the B* mini-apps
### and the contextual baselines), `budgets` are the §8.2 SLOs.
### The runner is a pure interpreter of these tables; adding B2-B4 in
### later waves means adding rows, not code.

(def benches
  ``Load shapes. :rate is wrk2's fixed RPS for the latency runs —
  80% of the §8.2 throughput floor, never max throughput (latency at
  saturation is meaningless). :script/:body-file are bench-root
  relative; the lua script posts the payload named by BENCH_BODY_FILE.``
  {:plaintext {:path "/"
               :threads 4
               :connections 64
               :rate 16000}
   :json {:path "/echo"
          :threads 4
          :connections 64
          :rate 6400
          :script "loadgen/post-json.lua"
          :body-file "payloads/b1-order.json"}
   :pg-query {:path "/db"
              :threads 4
              :connections 64
              :rate 2400}
   :pg-ssr {:path "/rows"
            :threads 4
            :connections 64
            :rate 1200}})

(def budgets
  "SPEC §8.2 budgets (1 worker, 1 vCPU), verified against the recorded
  reference environment at v0.1 — measurements, adjustments and their
  reasons: docs/BENCH-v0.1.md (b0 :p50 was the 0.5 hypothesis, below
  the loopback methodology floor). Latencies in ms, :rps is the
  throughput floor. Enforced by `void bench budgets` / --budgets."
  {:b0 {:p50 2 :p99 3 :rps 20000 :loop-lag-p99 1}
   :b1 {:p50 2.5 :p99 10 :rps 8000 :loop-lag-p99 1}
   # B2/B3 are the §8.2 hypotheses until this wave measures them on the
   # reference environment; B3 additionally carries the GC budget, and
   # carries it as :loop-lag-max, because a stop-the-world pause on a
   # single-threaded loop is loop lag of at least its own length and
   # janet 1.41 reports no pause of its own (void/bench/probe)
   :b2 {:p50 3 :p99 12 :rps 3000 :loop-lag-p99 1}
   :b3 {:p50 5 :p99 20 :rps 1500 :loop-lag-p99 1 :loop-lag-max 10}})

(def targets
  ``target -> how to serve it. :cmd is a sh line run from the bench
  root with PORT (and GOMAXPROCS=1 — budgets are per 1 vCPU) in the
  environment; `exec` so signals reach the server, not the shell.
  Baselines (:baseline true) calibrate the class (ADR-0014) — Go
  net/http is the ceiling, FastAPI+uvicorn the Python class — and are
  never checked against budgets.``
  {:b0 {:doc "B0 plaintext hello — void router + full middleware stack"
        :bench :plaintext
        :port 8100
        :budget :b0
        :cmd "exec janet apps/b0-plaintext/main.janet"}
   :b1 {:doc "B1 JSON echo 1KB — parse + validate + serialize (void/rest)"
        :bench :json
        :port 8101
        :budget :b1
        :cmd "exec janet apps/b1-json-echo/main.janet"}
   :b1-pressure {:doc "B1 with void/pressure in the chain — the SPEC §8.5 row for its middleware"
                 :bench :json
                 :port 8101
                 # the same app, one plugin heavier: `void bench b1
                 # b1-pressure` prints both rows and the delta is the
                 # answer §8.5 asks every middleware author for. No
                 # budget of its own — B1's budget is B1's
                 :cmd "VOID_BENCH_PRESSURE=1 exec janet apps/b1-json-echo/main.janet"}
   :b1-obs {:doc "B1 with void/obs in the chain — the SPEC §8.2 instrumentation-overhead row"
            :bench :json
            :port 8101
            # the same app, two plugins heavier: `void bench b1 b1-obs`
            # prints both rows, and the delta is what §8.2 budgets at
            # ≤ 7% of throughput. No budget of its own — B1's is B1's,
            # and obs is measured against B1, not against the SLO
            :cmd "VOID_BENCH_OBS=1 exec janet apps/b1-json-echo/main.janet"}
   :b2 {:doc "B2 Postgres single query — pool, prepared statement, ev loop"
        :bench :pg-query
        :port 8102
        :budget :b2
        :needs-pg true
        :cmd "exec janet apps/b2-pg-query/main.janet"}
   :b3 {:doc "B3 Postgres + hiccup SSR ~15KB — the shape a void app actually is"
        :bench :pg-ssr
        :port 8103
        :budget :b3
        :needs-pg true
        :cmd "exec janet apps/b3-pg-ssr/main.janet"}
   :go-plaintext {:doc "Go net/http baseline (the ceiling) — plaintext"
                  :bench :plaintext
                  :port 8180
                  :baseline true
                  :cmd "cd baselines/go-nethttp && go build -o .build/server . && exec .build/server"}
   :go-json {:doc "Go net/http baseline — JSON echo"
             :bench :json
             :port 8180
             :baseline true
             :cmd "cd baselines/go-nethttp && go build -o .build/server . && exec .build/server"}
   :fastapi-plaintext {:doc "FastAPI+uvicorn baseline (the Python class) — plaintext"
                       :bench :plaintext
                       :port 8181
                       :baseline true
                       :cmd "cd baselines/fastapi && exec python3 -m uvicorn app:app --host 127.0.0.1 --port ${PORT} --log-level warning"}
   :fastapi-json {:doc "FastAPI+uvicorn baseline — JSON echo"
                  :bench :json
                  :port 8181
                  :baseline true
                  :cmd "cd baselines/fastapi && exec python3 -m uvicorn app:app --host 127.0.0.1 --port ${PORT} --log-level warning"}})

(def probe-path
  ``Where an app carrying `bench/probe` answers the runtime-budget
  query (void/bench/probe). Here, with the rest of the suite's data,
  so the app that serves it and the runner that reads it cannot
  drift.``
  "/void/bench/probe")

(def order
  "Report/`all` order."
  [:b0 :b1 :b1-pressure :b1-obs :b2 :b3
   :go-plaintext :go-json :fastapi-plaintext :fastapi-json])

(def default-targets
  ``What a bare `void bench` runs: the four B* rows §8.2 budgets in
  wave 2. B2/B3 skip themselves when no Postgres is configured (see
  void/bench/pg) rather than fail — a laptop without a server still
  gets B0/B1.``
  [:b0 :b1 :b2 :b3])

(def pg-targets
  "Targets that need a Postgres to mean anything."
  (filter |(get-in targets [$ :needs-pg]) order))

(def baseline-targets
  "The `baselines` group."
  (filter |(get-in targets [$ :baseline]) order))
