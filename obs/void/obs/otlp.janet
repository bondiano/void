### void/obs-otlp — OTLP export of spans and metrics.
###
### The third plugin of the obs package, and the one that takes what
### this process measured somewhere else: finished sampled spans to
### `/v1/traces`, the metric registry to `/v1/metrics`, over OTLP/HTTP
### to a collector. Composed or not composed — an application that
### scrapes `/metrics` and reads spans out of the log never starts a
### fiber of it.
###
### **JSON by default, protobuf by configuration**. The
### exporter shipped on OTLP/JSON before `void/proto` existed, because
### the collector accepts that encoding out of the box — and the seam
### it left, `[:obs-otlp :encoding]`, now has its second legal value.
### The promise held: the binary encoder is a second projection of the
### same payload data (./otlp-proto, loaded only when configured), and
### `encode` is the one function in this file that knows there are two.
###
### **The exporter is a contribution, not a change to the tracer.**
### `:void.obs/exporter` has existed since wave 3 for exactly this,
### and every finished sampled span already reaches every exporter on
### the list. What this plugin adds to that path is one bounded
### `ev/give`: no encoding, no socket, no allocation past the queue
### slot. Everything else happens in a fiber of its own.
###
### **Two projections of what obs already holds, and no third model.**
### A span goes out as the span table the tracer built; a metric goes out
### of `metrics/snapshot`, the same value `prometheus/render` reads
### (promised the OTLP exporter would be a second projection of that
### snapshot, and this is it). The metric *names* are the Prometheus ones
### — `void_http_requests_total`, through `prometheus/metric-name` —
### because a series that is called one thing when it is scraped and
### another when it is pushed is two series to everybody downstream.
###
### **Cumulative temporality, because that is what the registry is.**
### A counter in `./metrics` only goes up and is never reset between
### exports, and `startTimeUnixNano` is this process's start
### (`runtime/state :start-realtime`) on every point. Delta
### temporality would mean subtracting the last export from this one —
### state per series, kept in the exporter, wrong after a scrape it
### did not see. A collector that wants deltas converts; that is what
### collectors are for.
###
### **Bounded queue, bounded batch, and losses are counted.** The
### shape the logger chose for its async sink and the one the
### OpenTelemetry SDKs converge on: 2048 spans queued, 512 to a
### request, five seconds between flushes, and a full queue *drops*
### rather than back-pressures the request fiber that finished the
### span. A telemetry pipeline that can stall the service it observes
### is a worse outage than no telemetry.
###
### **Prefork is the one deployment shape this makes easier.** With
### `[:http :workers] > 1` every worker holds its own registry, and a
### `/metrics` scrape reaches whichever worker the kernel handed the
### connection to — the reason void/obs-http's docstring tells operators
### to run one process per scrape target. A push has no such problem:
### every worker exports its own resource, `process.pid` says which one it
### is, and the collector adds them up. The trade is the mirror image of
### the scrape's.
###
### **The collector is next door, or the channel is encrypted**
### . Credentials — `[:obs-otlp :headers]` — over a plaintext non-loopback
### endpoint are refused *at start*: a bearer token in the clear is the
### same defect void/mail refuses for SMTP AUTH, and a start-time error is
### the only place to catch it before it is a habit. With `:void/tls`
### composed, an `https://` endpoint is a working answer — a hosted
### collector with a token becomes one config line; without the plugin the
### client itself refuses https with both ways out named. The default
### deployment shape stays an agent or a sidecar on loopback, which is
### also where OTLP's own defaults point (`http://127.0.0.1:4318`).

(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/http/client :as client)
(import ./metrics :as metrics)
(import ./prometheus :as prometheus)
(import ./runtime :as runtime)
(import ./trace :as trace)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.obs.otlp")

(def scope
  "The instrumentation scope every span and metric this process
  exports belongs to. One scope, because one library produced all of
  it."
  {"name" "void/obs" "version" "0.0.1"})

(def content-types
  "What an OTLP/HTTP request says it is, by encoding."
  {:json "application/json"
   :protobuf "application/x-protobuf"})

# -- the protobuf encoder, loaded when asked -----------------------------
#
# ./otlp-proto parses the vendored OTLP .proto files when it loads, so
# it is required on first use rather than imported: an application on
# the JSON default never pays for descriptors it will not encode with.

(var- proto-module
  # the void/obs/otlp-proto module environment, once something asked
  # for :protobuf
  nil)

(defn use-module!
  ``Hand the exporter the `void/obs/otlp-proto` module instead of
  letting it `require` one. There is exactly one caller: a single
  binary (docs/DEPLOY.md) composing `[:obs-otlp :encoding] :protobuf`,
  which has the module marshaled into the executable and no tree to
  require it from — the same seam, for the same reason, as
  db-sqlite's `use-module!`.``
  [m]
  (set proto-module m))

(defn- proto-encoder
  "The encode-payload function of ./otlp-proto, requiring the module
  on first use. Called from start! too, so a composition that chose
  :protobuf fails at boot rather than at the first flush."
  []
  (unless proto-module
    (def [ok env] (protect (require "void/obs/otlp-proto")))
    (unless ok
      (errorf (string "obs otlp: [:obs-otlp :encoding] :protobuf needs the "
                      "void/obs/otlp-proto module and requiring it failed: %s\n"
                      "In a single binary, require it at the top level of main and hand "
                      "it over with (otlp/use-module! ...) — docs/DEPLOY.md.")
              (if (string? env) env (describe env))))
    (set proto-module env))
  (or (get-in proto-module ['encode-payload :value])
      (errorf "obs otlp: the module handed to use-module! has no encode-payload — it should be void/obs/otlp-proto")))

# -- timestamps ----------------------------------------------------------

(defn nano-str
  ``Seconds since the epoch as OTLP's `unixNano`: a **string** of
  integer nanoseconds.

  A string because the field is a uint64 and the protobuf JSON mapping
  spells 64-bit integers as strings — and because it has to be. A
  nanosecond timestamp is past 2^53 since 1970 plus a few months, so a
  double cannot carry one: the seconds and the fraction are formatted
  apart here and never meet in one number.

  The nine digits are the unit OTLP names, not a precision claim —
  the source is `os/clock :realtime`, a double whose resolution at
  epoch scale is a fraction of a microsecond, so the last few digits
  are noise. Durations are measured on the monotonic clock and are
  exact to what it gives; only the wall-clock stamp they are anchored
  to is this coarse.``
  [seconds]
  (def s (math/floor seconds))
  (var ns (math/round (* 1000000000 (- seconds s))))
  (when (>= ns 1000000000) (set ns 999999999))
  (string/format "%d%09d" s ns))

# -- attributes ----------------------------------------------------------

(defn attr-value
  ``One attribute value in OTLP's tagged form. Janet's types map onto
  the four scalars OTLP has; anything else (a struct an application
  put on a span, an error value) is printed the way `%q` would, which
  is what the log serializers do with the same values.``
  [v]
  (cond
    (boolean? v) {"boolValue" v}
    (and (number? v) (= v (math/floor v)) (< (math/abs v) 9007199254740992))
    {"intValue" (string/format "%d" v)}
    (number? v) {"doubleValue" v}
    (or (string? v) (buffer? v)) {"stringValue" (string v)}
    (or (keyword? v) (symbol? v)) {"stringValue" (string v)}
    (nil? v) {"stringValue" ""}
    (indexed? v) {"arrayValue" {"values" (map attr-value v)}}
    {"stringValue" (string/format "%q" v)}))

(defn attributes
  ``A dictionary as OTLP's `[{key, value}]`. Keys go out as their
  string form, so `:db.system` is `db.system` and the semantic
  conventions can be written the way they are spelled.``
  [dict]
  (def pairs @[])
  (eachp [k v] (or dict {})
    (array/push pairs [(string k) v]))
  (sort-by first pairs)
  (seq [[k v] :in pairs]
    {"key" k "value" (attr-value v)}))

# -- traces --------------------------------------------------------------

(def span-kinds
  "void's span kinds as OTLP's enum."
  {:internal 1 :server 2 :client 3 :producer 4 :consumer 5})

(defn- span-status [span]
  # UNSET (0) unless the span was marked failed. OTLP reserves OK (1)
  # for a status an application set deliberately, and void sets :ok as
  # the *absence* of an error — reporting that as OK would tell a
  # backend something nobody said.
  (if (= :error (span :status))
    (let [err (get-in span [:attrs :error])]
      (if err {"code" 2 "message" (string err)} {"code" 2}))
    {"code" 0}))

(defn span->otlp
  "One finished span as an OTLP span object."
  [span]
  (def start (get span :started-at 0))
  (def out
    @{"traceId" (span :trace-id)
      "spanId" (span :span-id)
      "name" (string (span :name))
      "kind" (get span-kinds (span :kind) 1)
      "startTimeUnixNano" (nano-str start)
      "endTimeUnixNano" (nano-str (+ start (get span :duration 0)))
      "attributes" (attributes (span :attrs))
      "status" (span-status span)})
  (when-let [p (span :parent-id)] (put out "parentSpanId" p))
  (when-let [ts (span :tracestate)] (put out "traceState" ts))
  out)

(defn traces-request
  ``A batch of finished spans as an `ExportTraceServiceRequest`.
  Pure: spans and a resource in, data out — `encode` turns it into
  bytes and the exporter is the only thing that sends any.``
  [spans resource]
  {"resourceSpans"
   [{"resource" {"attributes" resource}
     "scopeSpans" [{"scope" scope
                    "spans" (map span->otlp spans)}]}]})

# -- metrics -------------------------------------------------------------

(defn metric-unit
  ``The UCUM unit of a metric, read off its name. void measures in
  Prometheus base units everywhere, so the suffix a metric already carries
  for the scraper is the unit for OTLP too — and a metric that carries
  none exports none rather than a guess.``
  [name]
  (def s (string name))
  (cond
    (string/has-suffix? "-seconds" s) "s"
    (string/has-suffix? "-seconds-total" s) "s"
    (string/has-suffix? "-bytes" s) "By"
    (string/has-suffix? "-bytes-total" s) "By"
    ""))

(defn- point-attributes [label-names label-values]
  (seq [i :range [0 (length label-names)]]
    {"key" (string (in label-names i))
     "value" (attr-value (get label-values i ""))}))

(defn- number-point [m s start now]
  {"startTimeUnixNano" start
   "timeUnixNano" now
   "asDouble" (let [v (s :value)] (if (number? v) v 0))
   "attributes" (point-attributes (m :labels) (s :labels))})

(defn- histogram-point [m s start now]
  (def counts (get s :buckets []))
  (def total (get s :count 0))
  (def in-buckets (sum counts))
  {"startTimeUnixNano" start
   "timeUnixNano" now
   "count" (string/format "%d" total)
   "sum" (get s :sum 0)
   # OTLP bucket counts are per bucket and there is one more of them
   # than there are bounds: the last holds everything above the last
   # bound, which the registry knows only as the difference between
   # the count and what the buckets caught
   "bucketCounts" (array ;(map |(string/format "%d" $) counts)
                         (string/format "%d" (max 0 (- total in-buckets))))
   "explicitBounds" (array ;(m :buckets))
   "attributes" (point-attributes (m :labels) (s :labels))})

(defn metric->otlp
  ``One entry of `metrics/snapshot` as an OTLP metric object, or nil
  for a metric with no series — a metric that has never fired is
  announced in the Prometheus exposition (a scraper wants to see that
  it exists) but has nothing to push, and an empty data point list is
  a payload a collector has to walk for nothing.``
  [m start now]
  (def series (get m :series []))
  (unless (empty? series)
    (def base {"name" (prometheus/metric-name (m :name))
               "description" (get m :doc "")
               "unit" (metric-unit (m :name))})
    (case (m :kind)
      :counter
      (merge base {"sum" {"dataPoints" (map |(number-point m $ start now) series)
                          "aggregationTemporality" 2
                          "isMonotonic" true}})
      :gauge
      (merge base {"gauge" {"dataPoints" (map |(number-point m $ start now) series)}})
      :histogram
      (merge base {"histogram" {"dataPoints" (map |(histogram-point m $ start now) series)
                                "aggregationTemporality" 2}})
      nil)))

(defn metrics-request
  ``A `metrics/snapshot` as an `ExportMetricsServiceRequest`. The
  second projection promised of the same snapshot the text
  exposition renders — same values, same names, same units.

  `start` is when this process started collecting (cumulative points
  all carry it) and `now` is the moment of the export; both in seconds
  since the epoch.``
  [snapshot resource start now]
  (def start-ns (nano-str start))
  (def now-ns (nano-str now))
  {"resourceMetrics"
   [{"resource" {"attributes" resource}
     "scopeMetrics" [{"scope" scope
                      "metrics" (filter truthy?
                                        (map |(metric->otlp $ start-ns now-ns) snapshot))}]}]})

(defn encode
  "A request payload as bytes — the one place the encoding is chosen.
  Both branches read the same payload data: protobuf is a second
  projection of it (./otlp-proto), not a second payload builder."
  [payload &opt encoding]
  (case (or encoding :json)
    :json (json/encode payload)
    :protobuf ((proto-encoder) payload)
    (errorf "obs otlp: unknown encoding %q (:json or :protobuf)" encoding)))

(defn data-points
  "How many data points a metrics payload carries — what the exporter
  reports as exported, since a 'metric' is a name and a point is a
  number."
  [payload]
  (sum (seq [rm :in (get payload "resourceMetrics" [])
             sm :in (get rm "scopeMetrics" [])
             m :in (get sm "metrics" [])]
         (sum (seq [k :in ["sum" "gauge" "histogram"]
                    :let [body (get m k)]
                    :when body]
                (length (get body "dataPoints" [])))))))

# -- what the exporter counts about itself -------------------------------

(def exported
  "Spans and data points this process handed to a collector — the
  numerator of 'is any of this arriving'."
  (metrics/counter :void.obs/otlp-exported-total
    {:doc "Telemetry items accepted by the collector"
     :labels [:signal]}))

(def dropped
  ``Items that never made it, by why: `queue-full` is this process
  producing faster than the collector accepts, `rejected` is the
  collector refusing the payload (a 4xx — a bad endpoint, a payload it
  will never like), `failed` is the network or a 5xx outliving the
  retries.``
  (metrics/counter :void.obs/otlp-dropped-total
    {:doc "Telemetry items dropped instead of exported"
     :labels [:signal :reason]}))

(def requests
  "Export requests by signal and outcome — the RED of the exporter
  itself."
  (metrics/counter :void.obs/otlp-requests-total
    {:doc "OTLP export requests"
     :labels [:signal :outcome]}))

(def export-duration
  "How long an export request takes. A collector that has started
  taking seconds to answer is the reason a queue is filling."
  (metrics/histogram :void.obs/otlp-export-duration-seconds
    {:doc "Seconds an OTLP export request took"
     :labels [:signal]}))

(def queued
  "Spans waiting in the export queue right now."
  (metrics/gauge :void.obs/otlp-queue-depth
    {:doc "Spans queued for export"}))

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:obs-otlp] config slice."
  {:enabled [:optional :boolean]
   :endpoint [:optional :string]
   :encoding [:optional [:enum :json :protobuf]]
   :headers [:optional [:map-of :string :string]]
   :timeout [:optional [:number {:min 0.001}]]
   :retries [:optional [:int {:min 0}]]
   :traces [:optional {:enabled [:optional :boolean]
                       :path [:optional :string]
                       :max-batch [:optional [:int {:min 1}]]
                       :queue [:optional [:int {:min 1}]]
                       :interval [:optional [:number {:min 0.01}]]}]
   :metrics [:optional {:enabled [:optional :boolean]
                        :path [:optional :string]
                        :interval [:optional [:number {:min 0.1}]]}]
   :service [:optional {:name [:optional :string]
                        :version [:optional :string]
                        :namespace [:optional :string]
                        :instance [:optional :string]}]
   :resource [:optional [:map-of :keyword :any]]})

(def defaults
  ``Defaults of the [:obs-otlp] slice.

  `:endpoint` is OTLP's own default port on loopback: the deployment
  shape this plugin assumes is a collector or an agent next to the
  process (there is no TLS), and that is also where every OpenTelemetry
  SDK looks first.

  The batching numbers are the OpenTelemetry defaults — 2048 queued,
  512 to a request, five seconds between flushes — not because they
  are magic but because an operator who has tuned them once for
  another service should not have to learn a second set of numbers
  here.

  `[:metrics :interval]` is 60 s, the OTLP default period, and it is
  deliberately not the Prometheus scrape interval: a push every
  fifteen seconds is four times the data for a resolution nobody
  asked for. An application that scrapes as well changes nothing —
  both exports read the same snapshot.``
  {:enabled true
   :endpoint "http://127.0.0.1:4318"
   :encoding :json
   :timeout 10
   :retries 2
   :traces {:enabled true :path "/v1/traces"
            :max-batch 512 :queue 2048 :interval 5}
   :metrics {:enabled true :path "/v1/metrics" :interval 60}})

(defn- slice [cfg0]
  (def cfg (merge defaults (or cfg0 {})))
  (each k [:traces :metrics]
    (put cfg k (merge (defaults k) (get (or cfg0 {}) k {}))))
  cfg)

# -- the resource --------------------------------------------------------

(defn- loopback? [host]
  (or (= "localhost" host)
      (= "::1" host)
      (= "0.0.0.0" host)
      (string/has-prefix? "127." host)))

(defn display-endpoint
  ``The endpoint with its userinfo cut out. `http://user:token@host/`
  is a supported spelling (client/parse-url reads the credentials
  off), and every place the endpoint is *shown* — the startup line,
  the export warnings, `status` and through it /health — must show
  this form instead: a collector token in a log file or in a health
  body has left the config it was supposed to live in.``
  [endpoint]
  (def s (string endpoint))
  (if-let [i (string/find "://" s)]
    (let [rest (string/slice s (+ i 3))
          slash (string/find "/" rest)
          authority (if slash (string/slice rest 0 slash) rest)
          at (string/find "@" authority)]
      (if at
        (string (string/slice s 0 (+ i 3))
                (string/slice authority (inc at))
                (if slash (string/slice rest slash) ""))
        s))
    s))

(defn resource-attributes
  ``The resource every payload carries: what this process *is*, as
  opposed to what it measured. `service.name` is the one attribute a
  backend genuinely needs — without it every process in the system is
  called `unknown_service` and the traces of two of them look like
  one — so it comes from `[:obs-otlp :service :name]`, then from the
  application's own `[:app :name]`, and only then from a constant.``
  [cfg app-name]
  (def svc (get cfg :service {}))
  (def attrs
    @{:service.name (or (get svc :name) app-name "void")
      :process.pid (os/getpid)})
  (when-let [v (get svc :version)] (put attrs :service.version v))
  (when-let [n (get svc :namespace)] (put attrs :service.namespace n))
  (put attrs :service.instance.id
       (or (get svc :instance)
           (if-let [h (os/getenv "HOSTNAME")]
             (string h "-" (os/getpid))
             (string (os/getpid)))))
  (eachp [k v] (get cfg :resource {}) (put attrs (keyword k) v))
  (attributes attrs))

# -- the boot value ------------------------------------------------------
#
# A component is handed its config slice and its dependencies, never
# the boot — and the application's own name (`[:app :name]`, the
# default `service.name`) lives in neither. A hook is the one thing
# that is handed a boot, so this plugin keeps the reference the way
# void/obs does.

(var boot-ref
  "The boot value this plugin started from (captured at :config-loaded)."
  nil)

(plugin/contribute! :void.core/hooks
  {:hook :config-loaded
   :phase 400
   :name :obs-otlp/capture-boot
   :doc "Keep the boot value: the default service.name is the application's own [:app :name]"
   :fn (fn capture-boot [boot] (set boot-ref boot))})

# -- the exporter --------------------------------------------------------

(def state
  ``The running exporter: its client, its span queue and the fibers
  behind them. A table and not a component instance, because the span
  exporter contributed below is called from `trace/end!` on a request
  fiber and must find it with one lookup.``
  @{:running false
    :client nil
    :queue nil
    :worker nil
    :ticker nil
    :metrics-fiber nil
    :done nil
    :cfg nil
    :resource nil
    :start nil
    :stopping false})

(def- stop-token :void.obs.otlp/stop)
(def- flush-token :void.obs.otlp/flush)

(defn- backoff [attempt]
  # half a second, doubling, with jitter — the same shape void/jobs
  # retries with, and for the same reason: a collector coming back up
  # must not be hit by every process at once
  (* 0.5 (math/exp2 attempt) (+ 0.75 (* 0.5 (math/random)))))

(defn- post!
  ``POST one payload to the collector. Returns :ok, :rejected (the
  collector said no in a way repeating will not fix) or :failed.
  Retries only what is worth retrying — a timeout, a refused
  connection, a 429 or a 5xx — and never past `:retries`, because a
  queue that is filling while the exporter retries is a second
  outage.``
  [signal path payload]
  (def cfg (state :cfg))
  (def bytes (encode payload (get cfg :encoding :json)))
  (def tries (if (state :stopping) 0 (get cfg :retries 2)))
  (var attempt 0)
  (var out nil)
  (while (nil? out)
    (def started (os/clock :monotonic))
    (def [ok res]
      (protect (client/send! (state :client)
                             {:method :post :target path
                              :headers {"content-type"
                                        (get content-types (get cfg :encoding :json))}
                              :body bytes})))
    (metrics/observe! export-duration [signal] (- (os/clock :monotonic) started))
    (def status (when ok (res :status)))
    (cond
      (and ok (>= status 200) (< status 300))
      (do (metrics/inc! requests [signal :ok])
          (set out :ok))

      (and ok (not (or (= 408 status) (= 429 status) (>= status 500))))
      (do
        (metrics/inc! requests [signal :rejected])
        (log/warn "otlp export rejected" :ns log-ns :signal signal
                  :status status :endpoint (display-endpoint (get cfg :endpoint))
                  :body (let [b (get res :body "")]
                          (string/slice b 0 (min 200 (length b)))))
        (set out :rejected))

      (< attempt tries)
      (do
        (metrics/inc! requests [signal :retried])
        (ev/sleep (backoff attempt))
        (++ attempt))

      (do
        (metrics/inc! requests [signal :failed])
        (log/warn "otlp export failed" :ns log-ns :signal signal
                  :endpoint (display-endpoint (get cfg :endpoint))
                  :status status
                  :err (when (not ok) (if (string? res) res (describe res))))
        (set out :failed))))
  out)

(defn export-spans!
  ``Send one batch of finished spans. Public so a test — and a REPL
  during an incident — can push a span without waiting for the flush
  interval.``
  [spans]
  (when (and (state :running) (not (empty? spans)))
    (def path (get-in state [:cfg :traces :path]))
    (def outcome (post! :traces path (traces-request spans (state :resource))))
    (if (= :ok outcome)
      (metrics/inc! exported [:traces] (length spans))
      (metrics/inc! dropped [:traces outcome] (length spans)))
    outcome))

(defn export-metrics!
  "Send the registry as it is right now. The same snapshot `/metrics`
  renders, projected the other way."
  []
  (when (state :running)
    (def path (get-in state [:cfg :metrics :path]))
    (def payload (metrics-request (metrics/snapshot) (state :resource)
                                  (state :start) (os/clock :realtime)))
    (def points (data-points payload))
    (def outcome (post! :metrics path payload))
    (if (= :ok outcome)
      (metrics/inc! exported [:metrics] points)
      (metrics/inc! dropped [:metrics outcome] points))
    outcome))

(defn span-exporter
  ``The `:void.obs/exporter` contribution: one bounded `ev/give` on
  the fiber that finished the span, and nothing else. A full queue
  drops the span and counts it — the alternative is a request fiber
  parked on a collector that has stopped answering.

  With no exporter running there is no queue and the span is dropped
  without a count: that is the shutdown window (the component stopped,
  the server has not finished draining), and a counter nobody will
  scrape again is not worth the write.``
  [span]
  (when-let [q (state :queue)]
    (if (ev/full q)
      (metrics/inc! dropped [:traces :queue-full])
      (ev/give q span)))
  nil)

(plugin/contribute! :void.obs/exporter
  {:name :obs/otlp
   :doc "Queue every finished sampled span for OTLP export (bounded; a full queue drops and counts rather than back-pressuring the request)"
   :fn span-exporter})

(defn- drain-worker
  "The batching fiber: take spans, send when the batch is full or a
  flush ticks, and flush what is left on the way out."
  []
  (def q (state :queue))
  (def max-batch (get-in state [:cfg :traces :max-batch]))
  (def batch @[])
  (defn flush! []
    (unless (empty? batch)
      (def items (tuple ;batch))
      (array/clear batch)
      (protect (export-spans! items))))
  (var run true)
  (while run
    (def item (ev/take q))
    (cond
      (or (nil? item) (= stop-token item)) (set run false)
      (= flush-token item) (flush!)
      (do
        (array/push batch item)
        # take whatever is already queued in the same pass: under load
        # this is one request per max-batch spans instead of one per
        # flush interval
        (while (and (< (length batch) max-batch) (pos? (ev/count q)))
          (def more (ev/take q))
          (cond
            (or (nil? more) (= stop-token more)) (set run false)
            (= flush-token more) (flush!)
            (array/push batch more)))
        (when (>= (length batch) max-batch) (flush!)))))
  (flush!)
  (when-let [d (state :done)] (ev/give d :done))
  nil)

# A ticker is cancelled at :stop while it is parked in ev/sleep, and a
# cancellation arrives inside the fiber as an error: caught here, so a
# shutdown is a shutdown and not a stack trace on stderr.

(defn- flush-ticker []
  (def interval (get-in state [:cfg :traces :interval]))
  (try
    (forever
      (ev/sleep interval)
      (def q (state :queue))
      (when (and q (not (ev/full q)))
        (ev/give q flush-token)))
    ([_] nil)))

(defn- metrics-ticker []
  (def interval (get-in state [:cfg :metrics :interval]))
  (try
    (forever
      (ev/sleep interval)
      (protect (export-metrics!)))
    ([_] nil)))

(defn flush!
  "Ask the exporter to send what it is holding. Returns immediately —
  the batch leaves on the exporter's own fiber."
  []
  (when-let [q (state :queue)]
    (unless (ev/full q) (ev/give q flush-token)))
  nil)

# -- component -----------------------------------------------------------

(defn- check-endpoint! [cfg]
  (def endpoint (get cfg :endpoint))
  # parsing here rather than at the first export: an https:// endpoint
  # or a typo should fail the boot, not the flush five seconds into
  # the first incident
  (def u (client/parse-url endpoint))
  (def headers (get cfg :headers {}))
  # an https endpoint (possible when :void/tls is composed — parse-url
  # gates that itself) is an encrypted channel: credentials on it are
  # fine, and so is leaving the host
  (def encrypted? (= "https" (u :scheme)))
  (when (and (not (empty? headers)) (not (loopback? (u :host))) (not encrypted?))
    (errorf (string "obs otlp: [:obs-otlp :headers] carries credentials and %s is "
                    "neither loopback nor https — they would go out in the clear. "
                    "Use an https endpoint (:void/tls composed), or point "
                    "the endpoint at a collector or agent on this host and let it "
                    "hold the credentials.")
            (display-endpoint endpoint)))
  (unless (or (loopback? (u :host)) encrypted?)
    (log/warn "otlp endpoint is neither loopback nor https — telemetry leaves this host unencrypted"
              :ns log-ns :endpoint (display-endpoint endpoint)))
  u)

(defn start!
  ``Start exporting. Separate from the component's `:start` so a test
  can drive the exporter without a boot — everything a component
  gives it is in `cfg`.``
  [cfg0 &opt app-name]
  (def cfg (slice cfg0))
  (check-endpoint! cfg)
  # a :protobuf composition loads its encoder here: a module that
  # cannot be required should fail the boot, not the first flush
  (when (= :protobuf (cfg :encoding)) (proto-encoder))
  (def traces (cfg :traces))
  (def mcfg (cfg :metrics))
  (put state :cfg cfg)
  (put state :stopping false)
  (put state :resource (resource-attributes cfg app-name))
  (put state :start (or (runtime/state :start-realtime) (os/clock :realtime)))
  (put state :client (client/open {:url (cfg :endpoint)
                                   :headers (get cfg :headers {})
                                   :timeout (cfg :timeout)}))
  (put state :running true)
  (when (get traces :enabled true)
    (def q (ev/chan (get traces :queue)))
    (put state :queue q)
    (put state :done (ev/chan 1))
    (metrics/set-collector! queued (fn collect-queued [] (ev/count q)))
    (put state :worker (ev/go drain-worker))
    (put state :ticker (ev/go flush-ticker)))
  (when (get mcfg :enabled true)
    (put state :metrics-fiber (ev/go metrics-ticker)))
  (log/info "obs otlp ready" :ns log-ns
            :endpoint (display-endpoint (cfg :endpoint))
            :encoding (cfg :encoding)
            :traces (get traces :enabled true)
            :metrics (get mcfg :enabled true)
            :metrics-interval (get mcfg :interval)
            :queue (get traces :queue)
            :max-batch (get traces :max-batch))
  {:endpoint (display-endpoint (cfg :endpoint))
   :encoding (cfg :encoding)
   :traces (get traces :enabled true)
   :metrics (get mcfg :enabled true)})

(defn stop!
  ``Stop exporting, after one last flush of what is queued — a
  process that is shutting down holds the spans of the requests it
  just finished, and they are the interesting ones.

  The final flush does not retry (`:stopping`), so shutdown is bounded
  by one request timeout and not by the retry schedule.``
  []
  (put state :stopping true)
  (each k [:ticker :metrics-fiber]
    (when-let [f (get state k)]
      (put state k nil)
      (protect (ev/cancel f "stop"))))
  (when (and (state :running) (get-in state [:cfg :metrics :enabled] true))
    (protect (export-metrics!)))
  (when-let [q (state :queue)]
    (protect (ev/give q stop-token))
    # the worker's last act is to say it is done; its flush is bounded
    # by the client's timeout, so this waits for something that ends
    (when-let [d (state :done)]
      (protect (ev/take d))))
  (put state :running false)
  (put state :queue nil)
  (put state :done nil)
  (put state :worker nil)
  (metrics/set-collector! queued nil)
  (when-let [c (state :client)]
    (put state :client nil)
    (protect (client/close! c)))
  nil)

(defn status
  "What the exporter is doing — the REPL half of the numbers it
  reports about itself."
  []
  {:running (state :running)
   :endpoint (display-endpoint (get-in state [:cfg :endpoint]))
   :encoding (get-in state [:cfg :encoding])
   :queued (when-let [q (state :queue)] (ev/count q))
   :queue-capacity (get-in state [:cfg :traces :queue])
   :exported (tabseq [[k v] :pairs (get exported :values {})] (first k) v)
   :dropped (tabseq [[k v] :pairs (get dropped :values {})] k v)})

(def otlp-component
  (system/component :obs/otlp
    :doc "The OTLP exporter: a bounded queue of finished spans behind a
    batching fiber, a metrics push on its own period, and one keep-alive
    connection to the collector. Depends on :void/obs because the
    registry and the tracer are what it exports — and on nothing else,
    so a jobs worker exports exactly what an HTTP process does."
    :deps [:void/obs]
    :config {:key :obs-otlp :schema Config}
    :start
    (fn start [_ cfg]
      (start! cfg (get-in boot-ref [:config :values :app :name])))
    :stop
    (fn stop [_] (stop!))
    :health
    (fn health [_]
      (def s (status))
      (merge {:status (if (s :running) :up :down)} s))))

# -- CLI -----------------------------------------------------------------

(plugin/contribute! :void.core/cli
  {:name :obs/otlp-check
   :read-only? true
   :doc "Send an empty batch to the configured collector and report what it said: void obs otlp-check"
   :needs [:obs/otlp]
   :fn (fn cli-check [_ & args]
         (unless (empty? args)
           (errorf "void obs otlp-check takes no arguments (got %q)" (string/join args " ")))
         (def cfg (state :cfg))
         (printf "endpoint  %s (%q)" (get cfg :endpoint) (get cfg :encoding))
         (def outcome (post! :traces (get-in cfg [:traces :path])
                             (traces-request [] (state :resource))))
         (printf "traces    %s" (case outcome
                                  :ok "accepted"
                                  :rejected "refused by the collector"
                                  "no answer"))
         (def m (post! :metrics (get-in cfg [:metrics :path])
                       (metrics-request (metrics/snapshot) (state :resource)
                                        (state :start) (os/clock :realtime))))
         (printf "metrics   %s" (case m
                                  :ok "accepted"
                                  :rejected "refused by the collector"
                                  "no answer")))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/obs-otlp
  :doc "OTLP/HTTP export of what void/obs holds: finished sampled spans through a bounded batching queue and the metric registry on its own period, JSON by default or protobuf via [:obs-otlp :encoding], to a collector next to the process."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/obs ">=0.0.1"}
  :config-key :obs-otlp
  :config-schema Config
  :config-defaults defaults
  :components [otlp-component])
