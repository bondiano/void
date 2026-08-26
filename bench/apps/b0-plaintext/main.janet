### B0 — plaintext hello through the full router + middleware stack
### (SPEC.md §8.2, ADR-0014). Budget: p50 < 0.5ms, p99 < 3ms,
### ≥ 20k RPS (1 worker, 1 vCPU).
###
### Deliberately nothing but void/http: the number this app produces
### is the price of the kernel itself — PEG routing, the precompiled
### middleware chain, wire I/O. PORT env overrides the listen port
### (default 8100).

(import ../prelude)
(import void)
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/http/ring :as ring)
(require "void/http/init")

(defn hello
  "GET / — the §8.2 B0 handler."
  [req]
  (ring/response 200 "Hello, World!"
                 @{"content-type" "text/plain; charset=utf-8"}))

(plugin/defcontribution :void.http/route-source
  {:name :bench.b0/routes
   :routes (router/routes {}
             (router/GET "/" 'hello {:name :hello}))
   :env (router/env-ref (curenv))})

(plugin/defplugin bench/b0
  :doc "B0 plaintext hello — router + full middleware stack."
  :version "0.0.1"
  :requires {:void/http ">=0.0.1"})

(def app
  {:plugins [:void/http :bench/b0]
   :profile :prod
   :config {:cli {:http {:host "127.0.0.1"
                         :port (or (scan-number (or (os/getenv "PORT") ""))
                                   8100)}}}})

(defn main [& args]
  (void/run! app))
