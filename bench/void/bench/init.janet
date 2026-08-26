### void/bench — the bench-suite plugin (SPEC.md §8.3, ADR-0014,
### ROADMAP 1.7).
###
### `void bench` is a :void.core/cli contribution like any other — the
### suite itself is a tiny void application (see ../../main.janet)
### whose only plugin is this one. The command needs no components: the
### runner spawns the B* mini-apps and the calibration baselines as
### subprocesses and drives wrk/wrk2 at them.

(import void/core/plugin :as plugin)
(import ./runner :as runner)

(plugin/defcontribution :void.core/cli
  {:name :bench
   :doc "Run the bench suite: void bench [TARGETS|all|baselines|list|compare] (--help for flags)"
   :fn (fn cli-bench [& args] (runner/run-cli args))})

(plugin/defplugin void/bench
  :doc "Bench-suite runner (ADR-0014): SPEC §8.3 методика over the bench/apps mini-apps and the Go/FastAPI calibration baselines; baseline recording and 5% regression checks."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"})
