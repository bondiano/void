### The in-process half of the "void/obs on vs off ≤ 7%
### throughput" — what obs costs a B1 request in CPU, measured from
### inside, for the edit-measure loop.
###
### The workload is B1's (bench/apps/b1-json-echo): void/rest decodes the
### 1KB order, the validation middleware checks it against the schema, the
### handler echoes it back through the serialization middleware. What is
### missing is the socket — inject runs the whole stack without one — and
### that makes this reading
### **conservative**: the bytes wrk2 pushes through the kernel are
### denominator obs does not add to, so a ratio measured here is at
### least the ratio measured out there.
###
### The budget itself is a bench row, on the reference environment,
### through wrk2, like every other budgeted number:
###
###     void bench b1 b1-obs
###
### One mode per process, because void/obs keeps its tracer switch in
### a module var — one process, one observability configuration — and
### two systems in one process would measure the last one twice:
###
###     janet test-support/overhead-probe.janet plain
###     janet test-support/overhead-probe.janet obs
###     janet test-support/overhead-probe.janet obs-notrace   # metrics only
###     janet test-support/overhead-probe.janet obs-core      # no obs-http
###
### `VOID_OBS_PROBE_LOG=1` turns the access log on (JDN lines to
### stderr, as a :prod process runs) — that is where obs's log sinks
### show up.

(import ../../scripts/packages :as packages)
(packages/test-paths :void/obs)

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/router :as router)
(import void/rest :as rest)
(require "void/http/init")
(require "void/rest/init")
(require "void/obs/init")
(require "void/obs/http")

(log/set-level! nil :error)

(def Item
  {:sku :string :name :string :qty [:int {:min 1}] :price [:number {:min 0}]})

(def Order
  "B1's payload contract (bench/payloads/b1-order.json matches it)."
  {:id :int
   :currency [:enum "usd" "eur" "gbp"]
   :customer {:name :string
              :email :string
              :address {:street :string :city :string :zip :string :country :string}}
   :items [:vector Item {:min 1}]
   :note [:optional :string]})

(def order
  "The B1 payload, as a value — the bench app reads the same shape off
  disk through wrk2's lua script."
  {"id" 1042
   "currency" "usd"
   "customer" {"name" "Ada Lovelace"
               "email" "ada@example.com"
               "address" {"street" "12 Analytical Way" "city" "London"
                          "zip" "EC1A 1BB" "country" "GB"}}
   "items" (seq [i :range [0 6]]
             {"sku" (string "SKU-" i) "name" (string "Widget " i)
              "qty" (inc i) "price" (+ 9.5 i)})
   "note" "leave at the door"})

(defn echo
  "POST /echo — the validated body straight back out (B1's handler)."
  [req]
  (rest/json (req :parsed-body)))

(def app
  (plugin/manifest 'bench/overhead
    :version "0.0.1"
    :requires {:void/http ">=0.0.1" :void/rest ">=0.0.1"}
    :contributes {:void.http/route-source
                  [{:name :bench/overhead
                    :routes (router/routes {}
                              (router/POST "/echo" 'echo
                                {:name :echo
                                 :void.schema/body Order
                                 :void.schema/response {200 Order}}))
                    :env (router/env-ref (curenv))}]}))

(defn- plugins-for [mode]
  (case mode
    "plain" [:void/http :void/rest app]
    # void/obs without void/obs-http: what the plugin costs a request
    # it does not touch (the log sinks, and nothing else)
    "obs-core" [:void/http :void/rest :void/obs app]
    [:void/http :void/rest :void/obs :void/obs-http app]))

(defn- start [mode &opt log-cfg]
  (def obs? (not= "plain" mode))
  (test/start!
    {:plugins (plugins-for mode)
     :only (if obs? [:http/kernel :obs/registry :obs/tracer] [:http/kernel])
     :config {:cli {:log (merge {:level :error} (or log-cfg {}))
                    :obs {:runtime {:interval 0.1}
                          :trace {:enabled (= "obs" mode)}}}}}))

(defn- run [c n]
  (def t (os/clock :monotonic))
  (loop [_ :range [0 n]] (test/inject c {:method :post :uri "/echo" :json order}))
  (- (os/clock :monotonic) t))

(defn- median [xs] (in (sorted xs) (math/floor (/ (length xs) 2))))

(defn measure
  ``Median microseconds per request over `rounds` rounds of `n`. With
  VOID_OBS_PROBE_LOG=1 the access log is on and writing JDN lines to
  stderr, which is the shape a :prod process actually runs in (send
  stderr to /dev/null when measuring).``
  [mode &opt n rounds]
  (default n 2000)
  (default rounds 5)
  (def boot (start mode
                   (when (os/getenv "VOID_OBS_PROBE_LOG")
                     {:level :info :sink :jdn})))
  (defer (test/stop! boot)
    (def c (test/client boot))
    (assert (= 200 ((test/inject c {:method :post :uri "/echo" :json order}) :status))
            "the probe's own request has to be the one B1 serves")
    (run c 500)                                   # warmup
    (* 1000000 (/ (median (seq [_ :range [0 rounds]] (run c n))) n))))

(defn main [_ &opt mode n rounds]
  (printf "%-12s %6.2f us/request"
          (or mode "plain")
          (measure (or mode "plain")
                   (when n (scan-number n))
                   (when rounds (scan-number rounds)))))
