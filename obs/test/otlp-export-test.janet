# The OTLP transport: what actually reaches a collector, what happens
# when it says no, and what the exporter costs the fiber that finished
# a span. The collector here is a void/http server, which is the only
# counterpart that can prove the bytes are a request somebody can read.

(import ../test-support/paths)
(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/server :as server)
(import void/http/ring :as ring)
(import void/obs/metrics :as metrics)
(import void/obs/trace :as trace)
(import void/obs/otlp :as otlp)

(log/set-level! "void.obs" :error)
(log/set-level! "void.http" :error)

# -- the collector -------------------------------------------------------

(def received @[])
(var fail-times 0)

(defn- collector [req]
  (case (req :path)
    "/v1/traces"
    (do
      (array/push received {:signal :traces :body (json/decode (req :body))})
      (if (pos? fail-times)
        (do (-- fail-times) (ring/text 503 "later"))
        (ring/response 200 "{}" @{"content-type" "application/json"})))

    "/v1/metrics"
    (do
      (array/push received {:signal :metrics :body (json/decode (req :body))})
      (ring/response 200 "{}" @{"content-type" "application/json"}))

    "/refuses"
    (ring/text 400 "no such tenant")

    (ring/not-found)))

(def inst (server/start {:handler collector :port "0" :idle-timeout 2}))
(def endpoint (string "http://127.0.0.1:" (inst :port)))

(defn- config [extra]
  (merge {:endpoint endpoint
          :timeout 2
          :retries 1
          :traces {:interval 60}
          :metrics {:enabled false}}
         extra))

(defn- traces-of []
  (filter |(= :traces ($ :signal)) received))

(defn- spans-in [entry]
  (get-in entry [:body "resourceSpans" 0 "scopeSpans" 0 "spans"] []))

# -- a span goes out -----------------------------------------------------

(metrics/reset!)
(otlp/start! (config {}) "shop")

(def span (trace/start "orders.show" {:kind :server :attrs {:http.route "orders.show"}}))
(trace/end! span)
(otlp/span-exporter span)
(otlp/flush!)
(ev/sleep 0.2)

(assert (= 1 (length (traces-of))) "one batch, one request")
(def batch (first (traces-of)))
(assert (= 1 (length (spans-in batch))))
(assert (= "orders.show" (get-in (spans-in batch) [0 "name"])))
(assert (= "shop"
           (first (seq [a :in (get-in batch [:body "resourceSpans" 0 "resource" "attributes"])
                        :when (= "service.name" (a "key"))]
                    (get-in a ["value" "stringValue"]))))
        "and it says which service it came from — without service.name every process is called unknown_service")

(assert (= 1 (metrics/value otlp/exported [:traces]))
        "what left is counted, so an empty dashboard can be told from a silent exporter")

# -- a batch, and one request for it -------------------------------------

(array/clear received)
(each i (range 20)
  (def s (trace/start (string "job." i) {:kind :consumer}))
  (trace/end! s)
  (otlp/span-exporter s))
(otlp/flush!)
(ev/sleep 0.3)

(assert (= 1 (length (traces-of)))
        "twenty spans queued between two flushes leave as one request, not twenty")
(assert (= 20 (length (spans-in (first (traces-of))))))

# -- the queue is bounded, and a full one drops --------------------------

(otlp/stop!)
(metrics/reset!)
(array/clear received)
(otlp/start! (config {:traces {:queue 4 :max-batch 4 :interval 60}}) "shop")

# nothing takes from the queue while this fiber runs: the worker only
# gets the loop back when this one yields
(each i (range 40)
  (def s (trace/start (string "flood." i) nil))
  (trace/end! s)
  (otlp/span-exporter s))
(assert (pos? (metrics/value otlp/dropped [:traces :queue-full]))
        "a full queue drops the span and counts it — a request fiber must never park on a collector")
(ev/sleep 0.3)

# -- the collector says no -----------------------------------------------

(otlp/stop!)
(metrics/reset!)
(array/clear received)
(otlp/start! (config {:traces {:path "/refuses" :interval 60}}) "shop")
(def rejected (trace/start "rejected" nil))
(trace/end! rejected)
(otlp/span-exporter rejected)
(otlp/flush!)
(ev/sleep 0.3)

(assert (= 1 (metrics/value otlp/dropped [:traces :rejected]))
        "a 4xx is dropped, not retried: repeating a payload the collector will never like is a second outage")
(assert (= 1 (metrics/value otlp/requests [:traces :rejected])))

# -- and a collector that is merely down ---------------------------------

(otlp/stop!)
(metrics/reset!)
(array/clear received)
(set fail-times 1)
(otlp/start! (config {}) "shop")
(def retried (trace/start "retried" nil))
(trace/end! retried)
(otlp/span-exporter retried)
(otlp/flush!)
(ev/sleep 2)

(assert (= 1 (metrics/value otlp/requests [:traces :retried]))
        "a 503 is worth repeating once")
(assert (= 1 (metrics/value otlp/requests [:traces :ok])))
(assert (= 2 (length (traces-of))) "and the collector saw the same batch twice, which is what a retry is")
(assert (= 1 (metrics/value otlp/exported [:traces])))
(set fail-times 0)

# -- and a collector that is not there at all ----------------------------

(otlp/stop!)
(metrics/reset!)
(otlp/start! (merge (config {}) {:endpoint "http://127.0.0.1:9"}) "shop")
(def unreachable (trace/start "nobody.home" nil))
(trace/end! unreachable)
(otlp/span-exporter unreachable)
(otlp/flush!)
(ev/sleep 2)

(assert (= 1 (metrics/value otlp/dropped [:traces :failed]))
        "a collector that is not there costs the retries and then one counted loss — never the request that produced the span")
(assert (zero? (or (metrics/value otlp/exported [:traces]) 0)))

# -- metrics -------------------------------------------------------------

(otlp/stop!)
(array/clear received)
(otlp/start! (config {:metrics {:enabled true :interval 3600}}) "shop")
(def requests-metric (metrics/counter :void.test/exported-requests
                       {:doc "requests" :labels [:route]}))
(metrics/inc! requests-metric ["home"] 7)
(assert (= :ok (otlp/export-metrics!)))
(ev/sleep 0.1)

(def pushed (find |(= :metrics ($ :signal)) received))
(assert pushed "the registry goes out on its own period, as a second projection of the same snapshot")
(def names (map |($ "name")
                (get-in pushed [:body "resourceMetrics" 0 "scopeMetrics" 0 "metrics"])))
(assert (index-of "void_test_exported_requests" names)
        "under the name a scraper would see, because a series must not be called two things")

# -- shutdown flushes ----------------------------------------------------

(array/clear received)
(def last-span (trace/start "on.the.way.out" nil))
(trace/end! last-span)
(otlp/span-exporter last-span)
(otlp/stop!)
(ev/sleep 0.1)

(assert (find |(and (= :traces ($ :signal))
                    (= "on.the.way.out" (get-in (spans-in $) [0 "name"])))
              received)
        "a process shutting down holds the spans of the requests it just finished, and they are the interesting ones")
(assert (not (otlp/state :running)))
(assert (nil? (otlp/state :client)) "and the connection to the collector is closed")

# -- credentials in the clear --------------------------------------------

(def [ok err] (protect (otlp/start! {:endpoint "http://collector.example:4318"
                                     :headers {"authorization" "Bearer hunter2"}}
                                    "shop")))
(assert (not ok) "a token to a remote collector fails the boot: there is no TLS (ADR-0010)")
(assert (string/find "ADR-0010" (string err)))
(otlp/stop!)

(def [ok2 err2] (protect (otlp/start! {:endpoint "https://collector.example:4318"} "shop")))
(assert (not ok2) "and so does an https endpoint, at start rather than at the first flush")
(otlp/stop!)

# -- the plugin ----------------------------------------------------------

(def plugins ["void/obs/init" "void/obs/otlp"])

(defn- boot-config [extra]
  {:env @{} :cli (merge {:log {:level :error}} extra)})

(def report (plugin/dry-run {:plugins plugins :profile :test
                             :config (boot-config {})}))
(assert (report :ok) "the exporter composes on obs and core alone — a jobs worker exports what an HTTP process does")
(assert (index-of :obs/otlp (report :components)))
(assert (= 1 (get-in report [:extensions :void.obs/exporter :contributions]))
        "and it reaches the tracer as a contribution to the point wave 3 left for it, not as a change to the tracer")

(each [slice reason]
  [[{:obs-otlp {:endpoint 42}} "an endpoint that is not a string"]
   [{:obs-otlp {:encoding :protobuf}} "an encoding that needs void/proto first"]
   [{:obs-otlp {:retries -1}} "a negative retry count"]
   [{:obs-otlp {:traces {:queue 0}}} "a queue with no room in it"]
   [{:obs-otlp {:metrics {:interval 0}}} "an export period of zero"]]
  (def [ok] (protect (plugin/dry-run {:plugins plugins :profile :test
                                      :config (boot-config slice)})))
  (assert (not ok) (string reason " fails the boot")))

(def booted (plugin/start! {:plugins plugins :profile :test
                            :config (boot-config {:obs-otlp {:endpoint endpoint
                                                             :metrics {:enabled false}}})}))
(assert (get-in booted [:system :instances :obs/otlp]))
(assert (= 1 (length trace/exporters))
        "a started process hands every finished sampled span to the exporter")
(assert (= :obs/otlp ((first trace/exporters) :name)))

(array/clear received)
(trace/with-span "through.the.tracer" {:kind :internal}
  (+ 1 1))
(otlp/flush!)
(ev/sleep 0.3)
(assert (find |(and (= :traces ($ :signal))
                    (find |(= "through.the.tracer" ($ "name")) (spans-in $)))
              received)
        "and a span written the way an application writes one arrives at the collector")

(plugin/shutdown! booted)
(server/stop inst)
