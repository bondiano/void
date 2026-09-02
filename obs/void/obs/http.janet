### void/obs-http — RED per route, the root span, and the three
### endpoints an operator needs (SPEC.md §5.13, §8.4 and part II §2.5).
###
### The half of obs that needs the HTTP kernel, kept a separate plugin
### so a jobs worker or a CLI never drags it in — what void/cache-http
### is to void/cache and void/pressure-http to void/pressure.
###
### **RED comes off the route table, never off the path.** SPEC §8.4
### asks for rate, errors and duration "per route, from route
### metadata, automatically", and the reason it says route and not
### path is cardinality: `/orders/8f21…` is an unbounded label and the
### metric that carries it takes the process down (./metrics). So the
### label is the route's name — `:void.obs/name` when a route sets
### one, its `:name` otherwise — a route table is finite by
### construction, and a request that matched nothing is labelled
### `(unmatched)` rather than by the path somebody probed.
###
### **The numbers are taken at two different moments, on purpose.**
###
###   the middleware   phase 1010, right after the request id: it
###                    starts the root span (continuing an inbound
###                    `traceparent` when there is one), binds the
###                    trace ids into the log context so every record
###                    of this request carries them, counts in-flight
###                    requests, and observes the queue time. The span
###                    is built only when something will consume it
###                    (`tracing?` below, ./trace) — the RED numbers
###                    are what a process pays for unconditionally,
###                    and they are a fraction of what a span costs.
###   `:on-response`   after the bytes are on the socket: the counter
###                    and the duration histogram. This stage sees the
###                    *rendered* status — a request aborted with 400
###                    by the validation middleware counts as a 400,
###                    where a wrapper inside the chain would only see
###                    a raised error and have to guess.
###
### **Queue time is the measurable half of §8.4's accept→handler.**
### void/http stamps `:arrived` when a request's first bytes are in
### hand (the accept for the first request on a connection, the moment
### the loop got back to the socket for the ones after it), and the
### middleware observes the delta on the way in. What it shows is the
### process's own backlog: the loop was busy elsewhere while this
### request sat there. What it cannot show is the delay before the
### process knew — nothing inside a process can time an event it has
### not been told about yet — which is why loop lag (./runtime) stays
### the primary saturation signal and this is the corroborating one.
###
### **The three endpoints, and why they are three.**
###
###   GET /metrics  the Prometheus text exposition. Optionally behind
###                 a bearer token: a metrics endpoint is a map of the
###                 inside of a process, and on a public port it
###                 should not be readable by everyone who can reach
###                 the port.
###   GET /health   runs the component health checks and the
###                 `:void.core/health` contributions — 200 when
###                 everything is up, 503 when something is down.
###                 It costs what the checks cost (a redis health
###                 check pings redis), which is the point of it.
###                 Behind the same [:obs-http :token] as /metrics:
###                 the folded report describes the inside of the
###                 process, endpoint addresses included.
###   GET /ready    whether this process is taking traffic: started,
###                 not draining. No checks, no I/O — an orchestrator
###                 polls it every second or two, and a readiness
###                 probe that queries a database is how a slow
###                 database becomes an outage.
###
### **Prefork is the one deployment shape that needs a word.** With
### `[:http :workers] > 1` (ADR-0010) every worker is its own process
### with its own registry, and a scrape reaches whichever worker the
### kernel handed the connection to: the numbers jump between workers,
### and a counter that jumps is not a counter. The answer is the
### ordinary one for prefork and Prometheus — one process per scrape
### target: run a single worker per container and scale containers, or
### read /metrics as a sample of one worker and nothing more.
### `void_obs_process_info{pid="..."}` says which worker answered.
### `/health` and `/ready` are per-worker by nature and are fine as
### they are: that *is* what a load balancer needs to know.
###
### Their paths are fixed, because the route table is built from
### static contributions and a path from config would have to be read
### before the config exists. An application that needs other paths
### mounts `metrics-handler` / `health-handler` / `ready-handler`
### in its own route source and turns `[:obs-http :endpoints]` off.
###
### **`:void.obs/endpoint` is what keeps them answering under load.**
### The routes declare it, and void/pressure-http treats a route
### marked with it as exempt from shedding (ADR-0019): a `/health`
### that 503s while the process sheds takes the worker out of the load
### balancer at exactly the moment it was trying to stay useful.

(import spork/json)
(import void/core/plugin :as plugin)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import void/http/server :as server)
(import ./metrics :as metrics)
(import ./prometheus :as prometheus)
(import ./trace :as trace)
(import ./log :as obslog)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.obs.http")

# -- the instruments -----------------------------------------------------

(def unmatched-label
  "The route label of a request that matched no route. A constant, so
  a scanner probing ten thousand paths adds one series and not ten
  thousand."
  "(unmatched)")

(def requests
  "The R and the E of RED: every request by route, method and status."
  (metrics/counter :void.http/requests-total
    {:doc "HTTP requests"
     :labels [:route :method :status]}))

(def duration
  "The D: how long a request took, from the first byte in hand to the
  last byte written."
  (metrics/histogram :void.http/request-duration-seconds
    {:doc "HTTP request duration in seconds"
     :labels [:route :method]}))

(def queue-buckets
  ``Bounds for queue time, in seconds. The §8.2 budgets live between 1
  and 20 ms and a queue that long is already the whole budget, so the
  resolution sits below a millisecond and the tail is short.``
  [0.0001 0.00025 0.0005 0.001 0.0025 0.005 0.01 0.025 0.05 0.1 0.5 1])

(def queue
  "Seconds between a request arriving and this process starting to
  work on it — the backlog, and the corroboration of loop lag."
  (metrics/histogram :void.http/queue-seconds
    {:doc "Seconds a request waited before the process started on it"
     :buckets queue-buckets}))

(var- in-flight-count
  ``Requests being served right now. A plain integer and not a gauge
  write: this is incremented and decremented on every request, and a
  number nobody reads between scrapes should not pay for the label
  lookup a metric write does. The gauge below collects it.``
  0)

(def in-flight
  "Requests being served right now — one fiber each (ADR-0010), which
  makes this the closest thing janet lets void report to a fiber
  count."
  (metrics/gauge :void.http/requests-in-flight
    {:doc "Requests currently being served"
     :collect (fn collect-in-flight [] in-flight-count)}))

(def connections
  "Open connections on the server, collected from the kernel at scrape
  time."
  (metrics/gauge :void.http/connections
    {:doc "Open HTTP connections"}))

# -- route labels --------------------------------------------------------

(def- route-info-cache
  ``Route name -> {:label :sample-rate :keys}. Computed once per route
  rather than per request, and keyed by the route's name so a rebuilt
  table (a dev reload, ADR-0002) reuses the entry instead of growing
  the cache.

  `:keys` memoizes the label tuples themselves — `[route method]` for
  the duration histogram and `[route method status]` for the counter.
  A route's method is fixed and its statuses are few, so the tuples a
  request needs have been built before; SPEC §8.5 asks for exactly
  this — what can be computed once is, and the hot path looks it up.``
  @{})

(defn- new-info [e]
  {:label (or (get-in e [:meta :void.obs/name]) (string (e :name)))
   :sample-rate (get-in e [:meta :void.obs/sample-rate])
   :keys @{}})

(def- unmatched-info
  {:label unmatched-label :sample-rate nil :keys @{}})

(def known-methods
  ``The HTTP methods that may become a label value or a cache key, as
  themselves; everything else collapses to :other. The wire accepts a
  method as an arbitrary token of capitals and the server interns it
  as a keyword, so an uncollapsed method is an unbounded label *and*
  an unbounded memo-cache key — a loop of invented methods would grow
  this process's memory for as long as it ran.``
  {:get :get :head :head :post :post :put :put :patch :patch
   :delete :delete :options :options :trace :trace})

(defn normalize-method
  "The closed-set spelling of a request's method: itself for the ones
  HTTP has, :other for anything somebody typed onto the wire."
  [method]
  (get known-methods method :other))

(def- max-label-keys
  # a route's methods are 9 after normalization and its statuses are
  # few, so a full cache means something is inventing label inputs —
  # from there the tuples are built per request instead of remembered
  256)

(defn forget-routes!
  "Drop the memoized route labels — what a rebuilt route table (a dev
  reload, ADR-0002) needs, since an edited `:void.obs/name` must not
  keep reporting under the old one."
  []
  (table/clear route-info-cache)
  nil)

(plugin/contribute! :void.core/hooks
  {:hook :void.dev/reloaded
   # after void/http rebuilds the table (500)
   :phase 600
   :name :obs-http/forget-routes
   :doc "Forget the memoized route labels when the route table is rebuilt"
   :fn (fn on-reloaded [_ _] (forget-routes!))})

(defn route-info
  "The label, head sampling rate and memoized label tuples of the
  request's route."
  [req]
  (if-let [e (req :void/route)]
    (or (get route-info-cache (e :name))
        (let [info (new-info e)]
          (put route-info-cache (e :name) info)
          info))
    unmatched-info))

(defn- labels
  ``The memoized label tuple for one [method status?] of a route —
  built on the first request that needs it and looked up afterwards.
  The cache is capped: past `max-label-keys` entries the tuple is
  built and not remembered, because a growing memo over inputs the
  caller controls is the leak the memo was not supposed to be.``
  [info method &opt status]
  (def cache (info :keys))
  (def k (if (nil? status) method [method status]))
  (or (get cache k)
      (let [t (if (nil? status)
                [(info :label) method]
                [(info :label) method status])]
        (when (< (length cache) max-label-keys)
          (put cache k t))
        t)))

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:obs-http] config slice."
  {:endpoints [:optional :boolean]
   :token [:optional :string]
   :trace [:optional :boolean]
   :metrics [:optional :boolean]})

(def defaults
  ``Defaults of the [:obs-http] slice. Everything on: an application
  that put obs in its plugin list asked for this, and an endpoint that
  has to be turned on is an endpoint that is missing in the incident
  where it was needed. `:token` is unset, because a token that
  defaulted to a value would be a password everybody knows.``
  {:endpoints true
   :trace true
   :metrics true})

(var settings
  "The [:obs-http] slice, read once at :config-loaded — the middleware
  runs on the hot path and has no business reaching into a boot value
  there."
  defaults)

(var boot-ref
  "The boot value (captured at :config-loaded): /health reads the
  component states and the health contributions out of it."
  nil)

(var ready
  "Is this process taking traffic? True from :after-start until
  :before-stop — what /ready answers, and the flag that takes a
  draining worker out of the load balancer before its connections are
  cut."
  false)

(plugin/contribute! :void.core/hooks
  {:hook :config-loaded
   :phase 400
   :name :obs-http/capture
   :doc "Keep the boot value and read the [:obs-http] slice once"
   :fn (fn capture [boot]
         (set boot-ref boot)
         (set settings (merge defaults
                              (or (get-in boot [:config :values :obs-http]) {}))))})

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 950
   :name :obs-http/ready
   :doc "Flip the readiness flag and point the connections gauge at the running server"
   :fn (fn become-ready [boot]
         (set ready true)
         (when-let [inst (get-in boot [:system :instances :http/server])]
           (metrics/set-collector! connections
                                   (fn collect-connections []
                                     (server/connections inst)))))})

(plugin/contribute! :void.core/hooks
  {:hook :before-stop
   :phase 50
   :name :obs-http/draining
   :doc "Answer /ready with 503 before the server starts draining (ADR-0015)"
   :fn (fn start-draining [_]
         (set ready false)
         (metrics/set-collector! connections nil))})

# -- metadata keys -------------------------------------------------------

(plugin/contribute! :void.http/route-meta-key
  {:key :void.obs/name
   :schema :string
   :doc "The name this route carries in metrics and spans (default: the route :name)"
   :merge :replace})

(plugin/contribute! :void.http/route-meta-key
  {:key :void.obs/sample-rate
   :schema [:number {:min 0 :max 1}]
   :doc "Head sampling rate for this route's traces, overriding [:obs :trace :sample-rate] — a health endpoint at 0, a payment at 1"
   :merge :replace})

(plugin/contribute! :void.http/route-meta-key
  {:key :void.obs/endpoint
   :schema :boolean
   :doc "An operator endpoint (health, readiness, metrics): it must answer while the process is refusing everything else, so void/pressure-http never sheds it"
   :merge :replace})

# -- the middleware ------------------------------------------------------

(defn tracing?
  ``Will this request get a root span? Only when something consumes
  it: an exporter is configured, `[:obs :trace :always]` asks for one,
  or the caller sent a `traceparent` and is tracing this request
  already (see ./trace). The header lookup is last because it is the
  most expensive of the three and the first two answer it for a whole
  process at a time.``
  [req]
  (and trace/enabled
       (settings :trace)
       (or (not (empty? trace/exporters))
           trace/always
           (truthy? (ring/request-header req trace/traceparent-header)))))

(defn- traced [handler req info]
  (trace/with-span* (info :label)
    {:parent nil
     :remote (trace/parse-traceparent (ring/request-header req "traceparent"))
     :kind :server
     :sample-rate (info :sample-rate)
     :attrs @{:http.request.method (req :method)
              :url.path (req :path)
              :http.route (info :label)
              :request-id (req :request-id)}}
    (fn obs-traced []
      (def span (trace/current))
      (put req :trace-id (span :trace-id))
      (put req :span-id (span :span-id))
      (def resp (handler req))
      (def status (get resp :status 200))
      (trace/attr! :http.response.status_code status span)
      # a 5xx is this span's failure; a 4xx is the caller's, and a
      # trace backend that colours every 404 red is a trace backend
      # nobody looks at
      (when (>= status 500) (put span :status :error))
      resp)))

(plugin/contribute! :void.http/middleware
  {:name :void.obs/request
   # after the request id (1000): the id is in the log context before
   # the span joins it, so one record carries both
   :phase 1010
   :doc "Start the request's root span (continuing an inbound W3C traceparent), bind the trace ids into the log context, count requests in flight and observe the queue time"
   :wrap
   (fn [handler]
     (fn obs-request [req]
       (when-let [t (req :arrived)]
         (metrics/observe! queue nil (max 0 (- (os/clock :monotonic) t))))
       (++ in-flight-count)
       (try
         (let [resp (if (tracing? req)
                      (traced handler req (route-info req))
                      (handler req))]
           (-- in-flight-count)
           resp)
         ([err fib]
           (-- in-flight-count)
           (propagate err fib)))))})

(plugin/contribute! :void.http/hook
  {:stage :on-response
   :name :void.obs/red
   :doc "Count the request and observe its duration once the response is written — the stage that sees the status the client actually got"
   :fn (fn obs-red [req resp]
         (def info (route-info req))
         # normalized *before* it becomes a label or a cache key: the
         # wire hands over any token of capitals, and an uncollapsed
         # method is unbounded cardinality (see known-methods). The
         # value then goes in as the keyword it is: the exposition
         # stringifies label values at render time
         # (prometheus/escape-label), so a scrape every fifteen
         # seconds pays for it instead of every request
         (def method (normalize-method (req :method)))
         (metrics/inc! requests (labels info method (get resp :status 200)))
         (when-let [t (req :received)]
           (metrics/observe! duration (labels info method)
                             (max 0 (- (os/clock :monotonic) t))))
         nil)})

# -- the endpoints -------------------------------------------------------

(def metrics-path "Where the exposition is served." "/metrics")
(def health-path "Where the health report is served." "/health")
(def ready-path "Where the readiness answer is served." "/ready")

(defn- off []
  (ring/response 404 "404 Not Found — this obs endpoint is off ([:obs-http :endpoints])"
                 @{"content-type" "text/plain; charset=utf-8"}))

(defn- same-secret?
  ``Compare two secrets without leaking their common prefix in the
  time it takes. A token check is not a hot path, and a comparison
  that returns early is the one thing about it worth being careful
  with.``
  [a b]
  (def x (string a))
  (def y (string b))
  (var diff (if (= (length x) (length y)) 0 1))
  (def n (min (length x) (length y)))
  (loop [i :range [0 n]]
    (set diff (bor diff (bxor (in x i) (in y i)))))
  (zero? diff))

(defn- authorized? [req]
  (if-let [token (settings :token)]
    (if-let [given (ring/request-header req "authorization")]
      (same-secret? (string "Bearer " token) given)
      false)
    true))

(defn- unauthorized []
  (ring/response 401 "401 Unauthorized"
                 @{"content-type" "text/plain; charset=utf-8"
                   "www-authenticate" "Bearer"}))

(defn metrics-handler
  ``GET /metrics — the Prometheus text exposition of every metric this
  process holds. Public so an application can mount it on a path (or a
  port) of its own.``
  [req]
  (cond
    (not (and (settings :endpoints) (settings :metrics))) (off)
    (not (authorized? req)) (unauthorized)
    (ring/response 200 (prometheus/render (metrics/snapshot))
                   @{"content-type" prometheus/content-type})))

(defn health-report
  ``The health of this process as data — `plugin/health` (every
  running component's `:health` plus every `:void.core/health`
  contribution, folded) with this endpoint's own readiness flag on
  top. The fold moved into the core when it got a second reader
  (void/mcp publishes the same report as a resource); `:ready` stays
  here, because draining is the HTTP server's state and nobody else's.``
  []
  (merge (plugin/health boot-ref) {:ready ready}))

(defn- json-response [status value]
  # every value that reaches here has been through jsonable: a health
  # contribution may return anything at all, and an endpoint that
  # throws because a component reported a function is an endpoint that
  # fails exactly when something is already wrong
  (ring/response status (json/encode (obslog/jsonable value))
                 @{"content-type" "application/json"}))

(defn health-handler
  ``GET /health — the health report, 200 when nothing is down and 503
  when something is. Behind the same bearer token as /metrics when
  `[:obs-http :token]` is set: the report folds every component's
  `:health` — endpoints, channel lists, runtime numbers — which is a
  map of the inside of this process, and on a public port it deserves
  the same door the exposition has. /ready stays bare on purpose —
  it answers with a boolean an orchestrator needs, and nothing else.``
  [req]
  (cond
    (not (settings :endpoints)) (off)
    (not (authorized? req)) (unauthorized)
    (let [report (health-report)]
      (json-response (if (= :down (report :status)) 503 200) report))))

(defn ready-handler
  ``GET /ready — is this process taking traffic? The flag and the
  component states, and deliberately nothing else: a readiness probe
  runs every second or two, and one that reaches a database turns a
  slow database into an outage.``
  [req]
  (if (settings :endpoints)
    (let [states (get-in boot-ref [:system :states] {})
          not-running (sorted (map string
                                   (filter |(not= :running (get states $))
                                           (keys states))))
          ok (and ready (empty? not-running))]
      (json-response (if ok 200 503)
                     {:status (if ok "ready" "not ready")
                      :draining (not ready)
                      :waiting-for not-running}))
    (off)))

(plugin/contribute! :void.http/route-source
  {:name :void.obs/endpoints
   :routes (router/routes {:void.obs/endpoint true
                           # the endpoints are not part of anybody's
                           # traces: a scraper hitting /metrics every
                           # fifteen seconds would otherwise be the
                           # most-traced route in the system
                           :void.obs/sample-rate 0}
             (router/GET metrics-path 'metrics-handler {:name :obs/metrics})
             (router/GET health-path 'health-handler {:name :obs/health})
             (router/GET ready-path 'ready-handler {:name :obs/ready}))
   :env (router/env-ref (curenv))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/obs-http
  :doc "Observability for void/http: RED per route from the route table, the request's root span with W3C trace context in and out, a queue-time histogram, and GET /metrics /health /ready."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/obs ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :obs-http
  :config-schema Config
  :config-defaults defaults)
