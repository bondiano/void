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

(defn- dirname
  {:params [:string] :ret :string}
  "The directory part of a path, or \".\" when it has none."
  [p]
  (def idxs (string/find-all "/" p))
  (if (empty? idxs) "." (string/slice p 0 (last idxs))))

(defn- add-tree
  {:params [:string] :ret @[:any]}
  "Push this root's :all: source templates onto module/paths, ahead of
  the built-in ones, so it is checked before the installed copy."
  [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(def- here (os/realpath (dirname self)))
(add-tree here)
(add-tree (string here "/../core"))
(add-tree (string here "/../http"))
(add-tree (string here "/../rest"))

(import void/core/cli :as cmd)
(import void/bench/runner :as runner)
(import void/bench/init :as bench)

(def app
  "Boot options the void CLI reads — :void/bench contributes `void bench`."
  {:plugins [:void/bench]
   :profile :prod})

(defn main
  {:params [:string] :ret :nil}
  "Binscript-style entrypoint: errors print to stderr and exit 1."
  [& args]
  (def [ok err]
    (protect
      (let [argv (tuple ;(drop 1 args))]
        (if (cmd/help-wanted? bench/command argv)
          (each l (cmd/help bench/command) (print l))
          (let [[opts words] (cmd/parse bench/command argv)]
            (runner/run words opts))))))
  (unless ok
    (eprintf "bench: %s" (if (string? err) err (describe err)))
    (os/exit 1)))
