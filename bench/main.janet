### bench — the void bench-suite entrypoint.
###
### Standalone (CI, no binary needed):    janet main.janet b0 b1 --quick
### Through the CLI (run from bench/):    void bench b0 b1 --quick
###
### The suite is itself a void application: `app` below is what the
### void CLI reads, and :void/bench contributes the `bench` command.
### The module-path setup points at the in-repo packages relative to
### this file — the suite benchmarks the checkout it lives in.

(def- self (dyn *current-file*))

(defn- dirname [p]
  (def idxs (string/find-all "/" p))
  (if (empty? idxs) "." (string/slice p 0 (last idxs))))

(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(def- here (os/realpath (dirname self)))
(add-tree here)
(add-tree (string here "/../core"))
(add-tree (string here "/../http"))
(add-tree (string here "/../rest"))

(import void/bench/runner :as runner)
(require "void/bench/init")

(def app
  "Boot options the void CLI reads — :void/bench contributes `void bench`."
  {:plugins [:void/bench]
   :profile :prod})

(defn main
  "Binscript-style entrypoint: errors print to stderr and exit 1."
  [& args]
  (def [ok err] (protect (runner/run-cli (tuple ;(drop 1 args)))))
  (unless ok
    (eprintf "bench: %s" (if (string? err) err (describe err)))
    (os/exit 1)))
