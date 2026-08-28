### B1 — JSON echo 1KB: parse + validate + serialize (SPEC.md §8.2,
### ADR-0014). Budget: p50 < 1ms, p99 < 5ms, ≥ 8k RPS (1 worker,
### 1 vCPU).
###
### The void/rest pipeline end to end: the JSON body codec decodes
### payloads/b1-order.json, the validation middleware checks it
### against the Order schema, the handler echoes it back as a lazy
### rest/json response the serialization middleware encodes. PORT env
### overrides the listen port (default 8101).

(import ../prelude)
(import void)
(import void/core/plugin :as plugin)
(import void/http/router :as router)
(import void/rest :as rest)
(require "void/http/init")
(require "void/rest/init")

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

(def app
  {:plugins [:void/http :void/rest :bench/b1]
   :profile :prod
   :config {:cli {:http {:host "127.0.0.1"
                         :port (or (scan-number (or (os/getenv "PORT") ""))
                                   8101)}}}})

(defn main [& args]
  (void/run! app))
