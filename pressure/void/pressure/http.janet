### void/pressure-http — the flag, as a 503 (SPEC.md §5.23,
### ADR-0019).
###
### The piece of void/pressure that needs void/http, kept a separate
### plugin so a jobs worker or a CLI never drags the HTTP kernel in —
### what void/cache-http is to void/cache. One wrapper, in **phase
### 100**: immediately after the panic guard and before everything
### else, because a request that is going to be refused should be
### refused before the process has spent anything on it — no body
### parsed, no session opened, no database connection taken out of the
### pool. Refusing late is most of the cost of serving.
###
### On the calm path it is one var deref (`state/under-pressure?`) and
### a call, which is the whole reason the sampling lives on another
### fiber.
###
### The 503 goes out through the **error renderers**, not around them:
### `http/render-error` produces exactly what a raised 503 would —
### problem+json when void/rest is in the composition, the dev page in
### dev, terse text otherwise — without raising, because a stacktrace
### per refused request is a bill that comes due precisely when the
### process cannot pay it. `Retry-After` is added on top: a client
### that reconnects immediately turns one overloaded process into a
### retry storm, and the number is the only part of a 503 a well-built
### client obeys.
###
### **What a route exempts itself with:**
###
###     (defroutes ops {:void.pressure/exempt true}
###       [:get "/health"  health-handler]
###       [:get "/metrics" metrics-handler])
###
### and the exemption is not a runtime check — the `:when` predicate
### is evaluated once at table-build time, so an exempt route has no
### pressure wrapper in its chain at all. It cannot be shed and it
### costs nothing. This matters more than it looks: an operator's
### `/health` must answer *while* the process sheds, or every load
### balancer takes the whole worker out at the moment it was trying to
### stay useful. Document the pattern with the deployment — `/health`
### exempt, and the LB routing on it — because the 503s the clients
### see are deliberate and the ones the LB sees would not be.
###
### void/obs-http's own `/health`, `/ready` and `/metrics` need no
### such mark: they carry `:void.obs/endpoint`, and the predicate
### below honours that key too (reading a key another plugin declares
### costs nothing when that plugin is absent — the value is nil).
###
### **What it costs a route that is not marked: one boolean.** There
### is no `:when` that would compile it out on a healthy process,
### because "healthy" is a runtime fact and the table is built at boot.
###
### Requests that match no route (404/405, static files) are answered
### outside every route chain and so are never shed. They are also the
### cheapest thing the server does, so nothing here changes that.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http :as http)
(import void/http/ring :as ring)
(import void/http/prefork :as prefork)
(import ./state :as state)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.pressure.http")

(def Config
  "Schema of the [:pressure-http] config slice."
  {:status [:optional [:int {:min 400 :max 599}]]
   # seconds, or :off for a 503 with no Retry-After at all
   :retry-after [:optional [:or [:number {:min 0}] [:enum :off]]]
   # the error value's :message — the dev error page and any custom
   # :void.http/error-renderer see it; problem+json does not, because
   # void/rest hides the detail of every 5xx outside dev and a shed is
   # not the exception that changes that rule
   :message [:optional :string]
   :log [:optional [:enum :first :all :none]]})

(def defaults
  ``Defaults of the [:pressure-http] slice.

  `:log :first` is the one that is a decision rather than a value.
  ADR-0019 asks for refused requests in the log with a counter, and
  under saturation that is thousands of lines per second of logging
  work added to a process that is shedding because it has no work
  left to give — the log becomes part of the overload. So one warning
  per episode, carrying the reasons; the count of everything refused
  in that episode rides out on the `:recovered` event, and `:log :all`
  is there for the person debugging a threshold.``
  {:status 503
   :retry-after 10
   :message "server is under pressure"
   :log :first})

(var settings
  "The [:pressure-http] slice, read at :before-start — the middleware
  runs on the hot path and has no business reaching into the boot
  value there."
  defaults)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :pressure-http/capture-config
   :doc "Read the [:pressure-http] slice once, before the route table is built"
   :fn (fn capture [boot]
         (set settings
              (merge defaults (or (get-in boot [:config :values :pressure-http]) {}))))})

# -- prefork (ADR-0010) --------------------------------------------------
#
# With :workers > 1 the process that started is the master: it spawns
# the workers, waits on them and serves nothing. Sampling its loop
# would publish a zero about nobody's requests, so the sampler is told
# — before it starts, which is why this is a hook and not something the
# component works out for itself — that this process supervises.
#
# There is no aggregation to go with it, and that is ADR-0010's design
# rather than a gap here: prefork workers share nothing but the
# listening socket, so the master has no channel to collect a number
# over. It does not need one. SO_REUSEPORT is the aggregation: the
# worker that is drowning answers 503 immediately, stops accumulating a
# queue, and the kernel keeps handing new connections to workers that
# are keeping up. Per-worker pressure is visible where it happens —
# each worker's own /health, its own log lines, its own :pressure/high
# event — and each of those carries the pid that tells the workers
# apart.

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 440
   :name :pressure-http/prefork-mode
   :doc "In a prefork master (ADR-0010) mark the process a supervisor: it serves no requests, so its loop is not the one worth sampling"
   :fn (fn prefork-mode [boot]
         (def workers
           (prefork/worker-count (get-in boot [:config :values :http :workers] 1)))
         (when (and (> workers 1) (not (prefork/worker?)))
           (set state/mode :supervisor)
           (log/info "prefork master — pressure is sampled per worker" :ns log-ns
                     :workers workers)))})

# -- the metadata key ----------------------------------------------------

(plugin/contribute! :void.http/route-meta-key
  {:key :void.pressure/exempt
   :schema :boolean
   :doc "Never shed this route under load — health, metrics and drain endpoints, which is how an operator (and a load balancer) still sees a process that is refusing everything else"
   :merge :replace})

# -- the response --------------------------------------------------------

(var- logged-episode nil)

(defn- log-shed [st reasons]
  (def mode (settings :log))
  (when (and (not= :none mode)
             (or (= :all mode) (not= logged-episode (st :episodes))))
    (set logged-episode (st :episodes))
    (log/warn "shedding request" :ns log-ns
              :shed (st :sheds)
              :episode (st :episodes)
              :reasons (map |(get $ :signal) reasons))))

(defn shed-response
  ``The response for one refused request: the configured status
  through the error renderers, plus `Retry-After`.``
  [req reasons]
  (def status (settings :status))
  (def resp
    (http/render-error
      {:http/status status
       :message (settings :message)
       # the one extension member that survives void/rest's 5xx rule:
       # *what* is saturated, never the values — which resource is at
       # its ceiling is what a caller's dashboard needs to tell this
       # 503 apart from a dependency's, and the numbers behind it are
       # an operator's business (health, logs, `void pressure status`)
       :problem @{"signals" (map |(string (get $ :signal)) reasons)}}
      req status))
  (def retry (settings :retry-after))
  (when (number? retry)
    (ring/header resp "retry-after" (string (math/round retry))))
  resp)

# -- the middleware ------------------------------------------------------

(plugin/contribute! :void.http/middleware
  {:name :void.pressure/shed
   # phase 100: after the panic guard (0), before the :on-send stage
   # (500) and everything that costs anything
   :phase 100
   :doc "Answer 503 + Retry-After while the process is over its pressure thresholds (ADR-0019); routes marked :void.pressure/exempt are never wrapped"
   # `:void.obs/endpoint` counts as exempt too, and reading a key
   # void/obs-http declares costs nothing when it is not in the
   # composition (an absent key is nil). An operator endpoint that
   # answers 503 while the process sheds is the health check that
   # takes the worker out of the load balancer at the moment it was
   # trying to stay useful — the same argument the doc string above
   # makes for /health, and obs's endpoints should not have to be
   # marked twice.
   :when (fn [rmeta] (not (or (get rmeta :void.pressure/exempt)
                              (get rmeta :void.obs/endpoint))))
   :wrap (fn [handler]
           (fn pressure-shed [req]
             (if (state/under-pressure?)
               (let [st (state/active)
                     reasons (state/reasons st)]
                 (when st (state/shed! st) (log-shed st reasons))
                 (shed-response req reasons))
               (handler req))))})

(plugin/defplugin void/pressure-http
  :doc "Load shedding for void/http: while void/pressure says the process is over its limits, requests are answered 503 + Retry-After in phase 100 — before parsing, sessions or a pooled connection — and routes marked :void.pressure/exempt are never shed."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/pressure ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :pressure-http
  :config-schema Config
  :config-defaults defaults)
