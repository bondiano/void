### void/bench/targets — the bench-suite as data (SPEC.md §8.2-8.3,
### ADR-0014).
###
### Three tables: `benches` are the load shapes (what the generator
### does), `targets` are the servers (what it hits — the B* mini-apps
### and the contextual baselines), `budgets` are the §8.2 hypotheses.
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
          :body-file "payloads/b1-order.json"}})

(def budgets
  "SPEC §8.2 budgets (1 worker, 1 vCPU) — hypotheses until the first
  recorded baseline turns them into regression thresholds. Latencies
  in ms, :rps is the throughput floor."
  {:b0 {:p50 0.5 :p99 3 :rps 20000}
   :b1 {:p50 1 :p99 5 :rps 8000}})

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

(def order
  "Report/`all` order."
  [:b0 :b1 :go-plaintext :go-json :fastapi-plaintext :fastapi-json])

(def default-targets
  "What a bare `void bench` runs."
  [:b0 :b1])

(def baseline-targets
  "The `baselines` group."
  (filter |(get-in targets [$ :baseline]) order))
