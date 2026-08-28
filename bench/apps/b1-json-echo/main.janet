### B1 — JSON echo 1KB: parse + validate + serialize (SPEC.md §8.2,
### ADR-0014). Budget: p50 < 2.5ms, p99 < 10ms, ≥ 8k RPS (1 worker,
### 1 vCPU).
###
### The void/rest pipeline end to end: the JSON body codec decodes
### payloads/b1-order.json, the validation middleware checks it
### against the Order schema, the handler echoes it back as a lazy
### rest/json response the serialization middleware encodes. PORT env
### overrides the listen port (default 8101).
###
### The app carries `bench/probe` (void/bench/probe): a fiber sampling
### this process's own event-loop lag, which is the only place §8.2's
### loop-lag and GC budgets can be measured from. `VOID_BENCH_PROBE=0`
### leaves it out — that is how its own cost gets measured.
###
### `VOID_BENCH_PRESSURE=1` adds void/pressure + void/pressure-http,
### which is the `b1-pressure` target: SPEC §8.5 asks every plugin that
### contributes middleware for the row "B1 with my middleware = −X%",
### and that row is this app run twice. The thresholds are configured
### off (`:max-loop-lag 0`) with the sampler *on*, because the question
### is what an un-shed request pays — under wrk's max-throughput load
### the loop is saturated by design, and a shedding B1 would measure
### how fast void answers 503, which is a different (and much better)
### number.

(import ../prelude)
(import void)
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/rest :as rest)
(require "void/http/init")
(require "void/rest/init")
(require "void/bench/probe")
(require "void/pressure/init")
(require "void/pressure/http")

(def Item
  {:sku :string
   :name :string
   :qty [:int {:min 1}]
   :price [:number {:min 0}]})

(def Order
  "The 1KB payload contract (payloads/b1-order.json matches it)."
  {:id :int
   :currency [:enum "usd" "eur" "gbp"]
   :customer {:name :string
              :email :string
              :address {:street :string
                        :city :string
                        :zip :string
                        :country :string}}
   :items [:vector Item {:min 1}]
   :note [:optional :string]})

(defn echo
  "POST /echo — the validated body straight back out."
  [req]
  (rest/json (req :parsed-body)))

(plugin/contribute! :void.http/route-source
  {:name :bench.b1/routes
   :routes (router/routes {}
             (router/POST "/echo" 'echo
               {:name :echo
                :void.schema/body Order
                :void.schema/response {200 Order}}))
   :env (router/env-ref (curenv))})

(plugin/defplugin bench/b1
  :doc "B1 JSON echo 1KB — parse + validate + serialize through void/rest."
  :version "0.0.1"
  :requires {:void/http ">=0.0.1" :void/rest ">=0.0.1"})

(def pressure?
  "Is this the b1-pressure run (SPEC §8.5)?"
  (= "1" (os/getenv "VOID_BENCH_PRESSURE")))

(def app
  {:plugins [;(if (= "0" (os/getenv "VOID_BENCH_PROBE")) [] [:bench/probe])
             ;(if pressure? [:void/pressure :void/pressure-http] [])
             :void/http :void/rest :bench/b1]
   :profile :prod
   :config {:cli {:http {:host "127.0.0.1"
                         :port (or (scan-number (or (os/getenv "PORT") ""))
                                   8101)}
                  :pressure {:max-loop-lag 0}}}})

(defn main [& args]
  (void/run! app))
