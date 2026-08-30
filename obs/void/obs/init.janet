### void/obs — observability (SPEC.md §5.13 and §8.4, ROADMAP 3.1).
###
### The three signals, and what each one is here:
###
###   logs     the logger is core and has been since wave 1 (ADR-0018).
###            obs adds trace correlation, sampling and file sinks —
###            ./log.
###   metrics  counters, gauges and histograms with a cardinality cap,
###            rendered as the Prometheus text exposition — ./metrics,
###            ./prometheus. RED per route and the operator endpoints
###            are ./http.
###   traces   spans in a dyn, W3C trace context in and out, exporters
###            as an extension point — ./trace.
###
### plus the two things a single-threaded ev process cannot be run
### without: an event-loop lag histogram (§8.4's "main health
### indicator") and pool/queue instrumentation of whatever else is in
### the composition — ./runtime, ./instrument.
###
### **Two plugins, and the seam is the HTTP kernel.**
###
###   void/obs       the registry, the tracer, the runtime sampler,
###                  the log integration and the instrumentations —
###                  core only. A jobs worker, a CLI command or a
###                  prefork master gets all of it.
###   void/obs-http  RED per route, the root span from an inbound
###                  `traceparent`, the queue-time histogram and
###                  `/metrics`, `/health`, `/ready` — ./http, the
###                  only piece that needs void/http.
###
### the same split void/cache and void/pressure already make, and for
### the same reason: a worker that runs jobs must be able to report
### what it is doing without importing an HTTP server to do it.
###
### What an application composes:
###
###     (void/run! {:plugins [:void/http :void/obs :void/obs-http ...]})
###     # config/prod.janet
###     {:obs {:trace {:sample-rate 0.1}
###            :log {:sample 0.05 :file {:path "/var/log/app/app.jdn"}}}}
###
### and from then on: `GET /metrics` for the scraper, `/health` and
### `/ready` for the orchestrator, `(obs/status)` in the REPL, `void
### obs metrics` from a shell, and every log record inside a request
### carrying the trace id of the span it happened in.
###
###   void/obs-otlp  OTLP/HTTP export of the spans and the metrics to
###                  a collector — ./otlp, wave 4 (ADR-0027). It
###                  arrived as a *contribution* to `:void.obs/exporter`
###                  and a second projection of `metrics/snapshot`, so
###                  nothing in the tracer or the registry changed to
###                  let it in — which is what the point was for.
###
### **What is deliberately not here.** An OTLP sink for *logs*. The
### HTTP client the other two signals needed exists now, so this is a
### choice and not a gap (ADR-0027 §7): every record that reaches the
### file reaches a collector through the agent already reading it,
### which is how most deployments would ship logs anyway.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./metrics :as metrics)
(import ./prometheus :as prometheus)
(import ./trace :as trace)
(import ./runtime :as runtime)
(import ./log :as obslog)
(import ./instrument :as instrument)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.obs")

# -- extension points ----------------------------------------------------

(defn- unique-by [what f]
  (fn [contribs]
    (def seen @{})
    (each c contribs
      (def k (f c))
      (when (in seen k) (errorf "duplicate %s %q" what k))
      (put seen k true))))

(plugin/defextension-point :void.obs/exporter
  :doc "Span exporters: {:name :fn (fn [span]) :doc?}; every finished sampled span is handed to each one, and an exporter that throws is logged rather than allowed to fail the request it was watching"
  :schema {:name :keyword
           :fn :function
           :doc [:optional :string]}
  :validate (unique-by "span exporter" |($ :name))
  :reduce |(sorted-by |($ :name) $))

(plugin/defextension-point :void.obs/instrument
  :doc "Auto-instrumentation (SPEC §5.13): {:name :needs [component keys or interfaces]? :install (fn [boot & instances] teardown-thunk?) :doc?}; applied at :after-start and skipped when a named component is not in the composition"
  :schema {:name :keyword
           :needs [:optional [:vector :keyword]]
           :install :function
           :doc [:optional :string]}
  :validate (unique-by "instrumentation" |($ :name))
  :reduce |(sorted-by |($ :name) $))

(plugin/contribute! :void.core/interface
  {:name :void/obs
   :doc "The observability registry: the metrics this process holds, the tracer behind them and the runtime sampler. Depend on the interface rather than the component key."
   :methods {:snapshot "every metric as data"
             :render "the Prometheus text exposition"
             :status "what the runtime sampler is seeing"}})

# obs ships the instrumentations of the wave-2 data plugins itself —
# a package that predates this point cannot contribute to it without
# breaking every application that does not run obs (./instrument).
(each i instrument/built-ins
  (plugin/contribute! :void.obs/instrument i))

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:obs] config slice."
  {:enabled [:optional :boolean]
   :max-label-sets [:optional [:int {:min 1}]]
   :runtime [:optional {:enabled [:optional :boolean]
                        :interval [:optional [:number {:min 0.001}]]}]
   :trace [:optional {:enabled [:optional :boolean]
                      :always [:optional :boolean]
                      :sample-rate [:optional [:number {:min 0 :max 1}]]
                      :exporter [:optional [:enum :log :none]]}]
   :log [:optional {:count [:optional :boolean]
                    :sample [:optional [:number {:min 0 :max 1}]]
                    :min-level [:optional [:enum :trace :debug :info :warn :error :fatal]]
                    :file [:optional {:path :string
                                      :format [:optional [:enum :jdn :json]]
                                      :buffer [:optional [:int {:min 1}]]}]}]
   # true (default) — every instrumentation whose components are
   # present; a list of names — only those; false — none
   :instrument [:optional [:or :boolean [:vector :keyword]]]})

(def defaults
  ``Defaults of the [:obs] slice.

  Three of them are decisions rather than values.

  `[:runtime :interval]` 0.1 s is ten lag samples a second — enough
  for a p99 over a scrape interval, cheap enough that the meter is
  not the load (void/bench/probe samples at 10 ms because it is
  measuring, not living there).

  `[:trace :sample-rate]` is 1: when spans are being created at all,
  every one of them is exported. Cutting the rate is what a
  *collector* asks for, and that is where the number belongs once one
  exists.

  `[:trace :always]` is false, and it is the decision behind SPEC
  §8.2's ≤ 7% instrumentation budget. A request's root span is built
  when something will consume it — an exporter, or a caller who sent
  a `traceparent` — and not otherwise, because a span table, two ids
  and an attribute map per request that no code ever reads is the
  largest single item in what obs costs (see the b1-obs bench row).
  Turning it on puts trace ids in the log records of a process that
  exports nothing; void/http's request id already correlates one
  process's records without it.

  `[:trace :exporter]` is absent on purpose: it defaults to `:log` in
  the `:dev` profile — a span per line is how tracing is visible
  before there is a collector — and to `:none` everywhere else, since
  a production process should not pay for a log line per span nobody
  reads. Composing `void/obs-otlp` is what points spans at a
  collector, and it needs nothing from this value.

  `[:log :sample]` is 1 — no sampling. A framework that quietly
  dropped log records would be a support case nobody could
  reconstruct; sampling is what a service turns on when it has
  measured its volume.``
  {:enabled true
   :max-label-sets metrics/default-max-label-sets
   :runtime {:enabled true :interval 0.1}
   :trace {:enabled true :always false :sample-rate 1}
   :log {:count true :sample 1 :min-level obslog/default-min-level}
   :instrument true})

(defn- slice [cfg0]
  (def cfg (merge defaults (or cfg0 {})))
  (each k [:runtime :trace :log]
    (put cfg k (merge (defaults k) (get (or cfg0 {}) k {}))))
  cfg)

# -- the boot value ------------------------------------------------------
#
# Components are handed their config slice and their dependencies,
# never the boot — but the extension points, the hook registry and the
# profile all live in it. A hook is the one thing that is handed one,
# so obs keeps the reference a hook gives it.

(var boot-ref
  "The boot value obs started from (captured at :config-loaded)."
  nil)

(plugin/contribute! :void.core/hooks
  {:hook :config-loaded
   :phase 400
   :name :obs/capture-boot
   :doc "Keep the boot value: the components read the extension points and the profile out of it"
   :fn (fn capture-boot [boot] (set boot-ref boot))})

(defn- resolved [name]
  (get-in boot-ref [:extensions name :resolved] []))

(defn- config-slice []
  (slice (get-in boot-ref [:config :values :obs])))

# -- logs ----------------------------------------------------------------
#
# The logger is configured by plugin/start! before any component runs
# (ADR-0018), and contributed sinks are installed there too — so the
# file sink is a delegating contribution whose target this hook
# supplies once the config is in, and the sampling gate wraps whatever
# the list holds by then (obs's own sinks included).

(var file-sink
  "The file sink state ({:fn :close! :reopen! :path}), or nil."
  nil)

(plugin/contribute! :void.core/log-sink
  {:name :obs/file
   :doc "Records to [:obs :log :file :path], written by their own fiber (ADR-0018); inert until that path is configured"
   :fn (fn obs-file-sink [rec]
         (when-let [s file-sink] ((s :fn) rec)))})

(var count-records?
  "Is the counting sink counting? A var and not a config lookup: this
  runs once per log record."
  true)

(plugin/contribute! :void.core/log-sink
  {:name :obs/count
   :doc "Count records by level into :void.obs/log-records-total — no I/O, one increment"
   :fn (let [counter (obslog/counting-sink)]
         (fn obs-count-sink [rec]
           (when count-records? (counter rec))))})

(defn close-file-sink!
  "Close the file sink, if one is open."
  []
  (when-let [s file-sink]
    (set file-sink nil)
    ((s :close!)))
  nil)

(defn reopen-file-sink!
  ``Reopen the log file — what a rotation that moved the file out from
  under the process needs. There is no CLI command for it on purpose:
  `void obs ...` is a *new* process, and the file to reopen belongs to
  the running one. Either rotate with `copytruncate`, which needs
  nothing from the process, or call this through the netrepl the
  process is already carrying (SPEC part II §1.6) — `void repl`, then

      (obs/reopen-file-sink!)

  Returns the path, or nil when no file sink is configured.``
  []
  (when-let [s file-sink] ((s :reopen!))))

(plugin/contribute! :void.core/hooks
  {:hook :config-loaded
   :phase 600
   :name :obs/logging
   :doc "Open the configured log file and put the sampling gate in front of every sink"
   :fn (fn configure-logging [boot]
         (def cfg (get (config-slice) :log))
         (set count-records? (not= false (get cfg :count)))
         (close-file-sink!)
         (when-let [f (get cfg :file)]
           (set file-sink (obslog/file-sink f))
           (log/info "obs log file open" :ns log-ns
                     :path (f :path) :format (get f :format :jdn)))
         (obslog/install-sampling! (get cfg :sample 1) (get cfg :min-level)))})

(plugin/contribute! :void.core/hooks
  {:hook :after-stop
   :phase 900
   :name :obs/close-log-file
   :doc "Drain and close the log file sink and take the sampling gate back off"
   :fn (fn close-logging [_]
         (close-file-sink!)
         # the gate lives in the logger, which outlives the system it
         # was configured for: a stopped obs must leave the sink list
         # the way it found it, or the next boot in this process (a
         # test suite, a REPL) logs through a gate nobody asked for
         (obslog/install-sampling! 1))})

# -- instrumentation -----------------------------------------------------

(var installed
  "The instrumentations applied to this process ({:name :teardown})."
  [])

(defn- wanted-instrumentations [cfg]
  (def w (get cfg :instrument true))
  (cond
    (= false w) []
    (indexed? w) w
    nil))

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 900
   :name :obs/instrument
   :doc "Apply the :void.obs/instrument contributions whose components are running"
   :fn (fn install-instrumentation [boot]
         (def cfg (config-slice))
         (when (not= false (cfg :enabled))
           (set installed
                (instrument/install! boot (resolved :void.obs/instrument)
                                     (wanted-instrumentations cfg)))
           (unless (empty? installed)
             (log/info "obs instrumentation installed" :ns log-ns
                       :instruments (map |($ :name) installed)))))})

(plugin/contribute! :void.core/hooks
  {:hook :before-stop
   :phase 100
   :name :obs/uninstrument
   :doc "Detach the instrumentations before the components they read stop"
   :fn (fn remove-instrumentation [_]
         (instrument/remove! installed)
         (set installed []))})

# -- the span exporter obs ships -----------------------------------------

(defn log-exporter
  ``The exporter of last resort: one record per finished sampled span,
  through the logger that is already configured. It is what makes
  tracing visible in dev before a collector exists, and what makes it
  visible in production without one — the records carry the same ids
  the request's own log lines do, so a grep is a trace.``
  [span]
  (log/info "span" :ns "void.obs.span"
            :span (span :name)
            :trace-id (span :trace-id)
            :span-id (span :span-id)
            :parent-id (span :parent-id)
            :kind (span :kind)
            :status (span :status)
            :us (math/round (* 1000000 (get span :duration 0)))
            :attrs (span :attrs)))

(defn- exporters [tcfg profile]
  (def choice (get tcfg :exporter (if (= :dev profile) :log :none)))
  (array ;(resolved :void.obs/exporter)
         ;(if (= :log choice)
            [{:name :obs/log :fn log-exporter}]
            [])))

# -- components ----------------------------------------------------------

(def registry-component
  (system/component :obs/registry
    :doc "The metric registry's runtime half: the cardinality cap from
    config, the event-loop lag sampler (SPEC §8.4 — the health
    indicator every other number is downstream of on a single-threaded
    loop) and the process gauges. The metrics themselves are
    module-level and outlive a restart, the way a counter should."
    :provides [:void/obs]
    :config {:key :obs :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (def rt (cfg :runtime))
      (metrics/set-max-label-sets! (cfg :max-label-sets))
      (if (and (not= false (cfg :enabled)) (not= false (rt :enabled)))
        (runtime/start-sampler! (rt :interval))
        (runtime/stop-sampler!))
      (log/info "obs ready" :ns log-ns
                :metrics (length metrics/registry)
                :loop-lag-interval (rt :interval)
                :sampling (runtime/sampling?)
                :max-label-sets (cfg :max-label-sets)
                :log-sample (get-in cfg [:log :sample])
                :log-file (get-in cfg [:log :file :path])
                :enabled (not= false (cfg :enabled)))
      cfg)
    :stop
    (fn stop [_]
      (runtime/stop-sampler!))
    :health
    (fn health [_]
      (runtime/health))))

(def tracer-component
  (system/component :obs/tracer
    :doc "Tracing: whether spans are created at all, the head sampling
    rate they inherit, and the exporter list a finished sampled span
    is handed to. Separate from the registry because a process may
    perfectly well count things without tracing them — and because
    turning tracing off has to be one line, not a redeploy without the
    plugin."
    :deps [:void/obs]
    :config {:key :obs :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (def tcfg (cfg :trace))
      (def es (exporters tcfg (get boot-ref :profile :dev)))
      (trace/set-exporters! es)
      (set trace/enabled (and (not= false (cfg :enabled))
                              (not= false (tcfg :enabled))))
      (set trace/always (true? (get tcfg :always)))
      (set trace/default-sample-rate (get tcfg :sample-rate 1))
      (log/info "obs tracer ready" :ns log-ns
                :enabled trace/enabled
                :sample-rate trace/default-sample-rate
                :always trace/always
                :exporters (map |($ :name) es))
      {:enabled trace/enabled
       :always trace/always
       :sample-rate trace/default-sample-rate
       :exporters (tuple ;(map |($ :name) es))})
    :stop
    (fn stop [_]
      (set trace/enabled false)
      (set trace/always false)
      (trace/set-exporters! []))
    :health
    (fn health [t]
      (merge {:status :up} t))))

# -- public surface (re-exports) -----------------------------------------

(def counter "See metrics/counter — declare a monotonic total." metrics/counter)
(def gauge "See metrics/gauge — declare a number that goes both ways." metrics/gauge)
(def histogram "See metrics/histogram — declare a distribution." metrics/histogram)
(def inc! "See metrics/inc! — add to a counter." metrics/inc!)
(def add! "See metrics/add! — add to a gauge." metrics/add!)
(def set! "See metrics/set! — set a gauge." metrics/set!)
(def observe! "See metrics/observe! — record one observation." metrics/observe!)
(def metric-value "See metrics/value — one series' current value." metrics/value)
(def quantile "See metrics/quantile — a quantile off a histogram." metrics/quantile)
(def find-metric "See metrics/find-metric — the handle behind a name." metrics/find-metric)
(def snapshot "See metrics/snapshot — every metric as data." metrics/snapshot)
(def reset-metrics! "See metrics/reset! — drop the values, keep the declarations." metrics/reset!)
(def registry "See metrics/registry — name -> handle, process-wide." metrics/registry)

(def start-span "See trace/start — start a span without binding it." trace/start)
(def end-span! "See trace/end! — finish a span and export it." trace/end!)
(def current-span "See trace/current — the span this fiber is inside." trace/current)
(def span-context "See trace/context — the correlation ids of a span." trace/context)
(def attr! "See trace/attr! — add an attribute to a span." trace/attr!)
(def span-error! "See trace/error! — mark a span failed." trace/error!)
(def carrying "See trace/carrying — take the span into an ev/go task." trace/carrying)
(def traceparent "See trace/traceparent — the W3C header value of a span." trace/traceparent)
(def parse-traceparent "See trace/parse-traceparent — an inbound header." trace/parse-traceparent)
(def inject! "See trace/inject! — write the trace context into outgoing headers." trace/inject!)
(def trace-headers "See trace/headers — the trace context as a fresh table." trace/headers)

(def with-span* "See trace/with-span* — a span around a thunk." trace/with-span*)
(defmacro with-span
  ``Run `body` inside a span, with its ids bound to the log context —
  see trace/with-span:

      (obs/with-span "orders.load" {:attrs {:db.system "postgres"}}
        (db/query ...))``
  [name opts & body]
  ~(,trace/with-span* ,name ,opts (fn with-span-body [] ,;body)))

(def loop-lag "See runtime/loop-lag — the event-loop lag histogram." runtime/loop-lag)
(def observe-lag! "See runtime/observe! — record one lag sample." runtime/observe!)

(defn render
  "The Prometheus text exposition of every metric in this process."
  []
  (prometheus/render (metrics/snapshot)))

(defn status
  ``What obs is seeing: the runtime sampler's distribution, the
  tracer's settings, the instrumentations that installed and the
  registry's own size. The REPL half of `/metrics` — and the thing to
  read first when a dashboard is empty.``
  []
  (def cfg (config-slice))
  (merge (runtime/stats)
         {:metrics (length metrics/registry)
          :series (sum (seq [m :in (values metrics/registry)] (length (m :values))))
          :dropped (sum (seq [m :in (values metrics/registry)] (m :dropped)))
          :max-label-sets (cfg :max-label-sets)
          :trace {:enabled trace/enabled
                  :always trace/always
                  :sample-rate trace/default-sample-rate
                  :exporters (map |($ :name) trace/exporters)}
          :log {:sample (get-in cfg [:log :sample])
                :min-level (get-in cfg [:log :min-level])
                :file (get-in cfg [:log :file :path])
                :dropped (log/dropped)}
          :instrumented (map |($ :name) installed)}))

(plugin/contribute! :void.core/store
  {:name :void.obs/metrics
   :what "the metric registry"
   :needs [:obs/registry]
   :doc "Counters and histograms are per process by construction — aggregation belongs to whatever scrapes them"
   :ask (fn ask-metrics [boot]
          (when (get-in boot [:system :instances :obs/registry])
            {:store :process
             :shared? :by-design
             :why "each replica exposes its own series and Prometheus (or the OTLP collector) sums them; a registry shared between processes would double-count"}))})

# -- CLI -----------------------------------------------------------------

(defn- fmt-ms [x]
  (if (number? x) (string/format "%.3f ms" x) "—"))

(defn- fmt-bytes [n]
  (cond
    (not (number? n)) "—"
    (>= n 1073741824) (string/format "%.2f GiB" (/ n 1073741824))
    (>= n 1048576) (string/format "%.1f MiB" (/ n 1048576))
    (string/format "%d B" n)))

(defn print-status
  "Print what `status` knows — the body of `void obs status`."
  [s]
  (printf "metrics         %d (%d series, %d dropped by the cap of %q)"
          (s :metrics) (s :series) (s :dropped) (s :max-label-sets))
  (printf "loop lag        p50 %s  p99 %s  max %s"
          (fmt-ms (get-in s [:loop-lag :p50]))
          (fmt-ms (get-in s [:loop-lag :p99]))
          (fmt-ms (get-in s [:loop-lag :max])))
  (printf "sampling        %s every %q s (%d samples)"
          (if (s :sampling) "on" "off") (s :interval) (s :samples))
  (printf "rss             %s" (fmt-bytes (s :rss)))
  (printf "uptime          %.1f s" (s :uptime))
  (printf "tracing         %s at rate %q%s, exporters %s"
          (if (get-in s [:trace :enabled]) "on" "off")
          (get-in s [:trace :sample-rate])
          (if (get-in s [:trace :always]) ", spans always" "")
          (let [es (get-in s [:trace :exporters])]
            (if (empty? es) "none" (string/join (map |(string/format "%q" $) es) " "))))
  (printf "log             sample %q below %q, dropped %d, file %s"
          (get-in s [:log :sample]) (get-in s [:log :min-level])
          (get-in s [:log :dropped])
          (or (get-in s [:log :file]) "—"))
  (printf "instrumented    %s"
          (let [is (s :instrumented)]
            (if (empty? is) "nothing" (string/join (map |(string/format "%q" $) is) " ")))))

(plugin/contribute! :void.core/cli
  {:name :obs/status
   :read-only? true
   :doc "Show what obs is seeing: void obs status"
   :needs [:obs/registry :obs/tracer]
   :fn (fn cli-status [_ _ & args]
         (unless (empty? args)
           (errorf "void obs status takes no arguments (got %q)" (string/join args " ")))
         (print-status (status)))})

(plugin/contribute! :void.core/cli
  {:name :obs/metrics
   :read-only? true
   :doc "Print this process's Prometheus exposition: void obs metrics"
   :needs [:obs/registry]
   :fn (fn cli-metrics [_ & args]
         (unless (empty? args)
           (errorf "void obs metrics takes no arguments (got %q)" (string/join args " ")))
         (prin (render)))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/obs
  :doc "Observability: a metric registry with a cardinality cap and a Prometheus exposition, spans in a dyn with W3C trace context, an event-loop lag histogram, log sampling and file sinks, and auto-instrumentation of whatever data plugins are in the composition."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :obs
  :config-schema Config
  :config-defaults defaults
  :components [registry-component tracer-component])
