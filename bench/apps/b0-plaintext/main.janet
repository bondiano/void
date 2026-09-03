### B0 — plaintext hello through the full router + middleware stack.
### Budget: p50 < 2ms, p99 < 3ms, ≥ 20k RPS (1 worker, 1 vCPU).
###
### Deliberately nothing but void/http: the number this app produces
### is the price of the kernel itself — PEG routing, the precompiled
### middleware chain, wire I/O. PORT env overrides the listen port
### (default 8100).
###
### The app carries `bench/probe` (void/bench/probe): a fiber sampling
### this process's own event-loop lag, which is the only place the
### loop-lag and GC budgets can be measured from. `VOID_BENCH_PROBE=0`
### leaves it out — that is how its own cost gets measured.

(import ../prelude)
(import void)
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/http/ring :as ring)
(require "void/http/init")
(require "void/bench/probe")

(defn hello
  "GET / — the B0 handler."
  [req]
  (ring/response 200 "Hello, World!"
                 @{"content-type" "text/plain; charset=utf-8"}))

(plugin/contribute! :void.http/route-source
  {:name :bench.b0/routes
   :routes (router/routes {}
             (router/GET "/" 'hello {:name :hello}))
   :env (router/env-ref (curenv))})

(plugin/defplugin bench/b0
  :doc "B0 plaintext hello — router + full middleware stack."
  :version "0.0.1"
  :requires {:void/http ">=0.0.1"})

(def app
  {:plugins [;(if (= "0" (os/getenv "VOID_BENCH_PROBE")) [] [:bench/probe])
             :void/http :bench/b0]
   :profile :prod
   :config {:cli {:http {:host "127.0.0.1"
                         :port (or (scan-number (or (os/getenv "PORT") ""))
                                   8100)}}}})

(defn main [& args]
  (void/run! app))
