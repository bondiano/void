### void/bench — the bench-suite plugin.
###
### `void bench` is a :void.core/cli contribution like any other — the
### suite itself is a tiny void application (see ../../main.janet)
### whose only plugin is this one. The command needs no components: the
### runner spawns the B* mini-apps and the calibration baselines as
### subprocesses and drives wrk/wrk2 at them.

(import void/core/plugin :as plugin)
(import ./runner :as runner)

(def command
  ``The `void bench` declaration, exported because the suite has a
  second front door: `janet bench/main.janet b0 --quick` runs without a
  binary (CI), and it parses its arguments against *this* struct rather
  than against a copy of it.

  Targets are words — one or more of the target keys, or `all` /
  `baselines` — and `list`, `compare BASE.jdn CURRENT.jdn` and `budgets
  [FILE]` are the three that do something else with them. wrk (max
  throughput) and wrk2 (latency under a fixed rate) have to be on PATH;
  VOID_BENCH_WRK / VOID_BENCH_WRK2 override where.``
  {:name :bench
   :read-only? false
   :doc "Run the bench suite"
   :args ["[TARGETS|all|baselines|list|compare|budgets...]"]
   :flags {"--quick" {:key :quick :type :bool
                      :doc "smoke profile: warmup 3s, 2x5s (CI shared runners)"}
           "--runs" {:key :runs :type :int :doc "timed runs per mode (default 3)"}
           "--duration" {:key :duration :type :int :doc "seconds per run (default 60)"}
           "--warmup" {:key :warmup :type :int :doc "warmup seconds (default 30)"}
           "--out" {:key :out :doc "also write the result set to this file"}
           "--record" {:key :record :type :bool
                       :doc "freeze this run as results/baseline.jdn"}
           "--check" {:key :check :type :bool
                      :doc "compare against the recorded baseline, exit 1 on any >5% regression"}
           "--against" {:key :against :doc "baseline file for --check"}
           "--threshold" {:key :threshold :type :number
                          :doc "allowed degradation percent (default 5)"}
           "--budgets" {:key :budgets :type :bool
                        :doc "also enforce the absolute budgets (reference environment, not shared CI)"}}
   :fn (fn cli-bench [opts & words] (runner/run words opts))})

(plugin/contribute! :void.core/cli command)

(plugin/defplugin void/bench
  :doc "Bench-suite runner: the wrk/wrk2 method over the bench/apps mini-apps and the Go/FastAPI calibration baselines; baseline recording and 5% regression checks."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"})
