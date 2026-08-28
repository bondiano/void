### void/pressure — load shedding (SPEC.md §5.23, ADR-0019,
### ROADMAP 2.6).
###
### A single-threaded ev-loop process does not degrade gracefully on
### its own: the accept queue grows, loop-lag lands on *every* request
### in flight, and the process stops answering anybody rather than
### answering some people slowly. This plugin is the fastify
### under-pressure move — the process watches its own loop and its own
### RSS, and while it is over its limits it answers 503 + `Retry-After`
### cheaply, to the requests it can still afford to refuse, instead of
### timing out the ones it accepted.
###
### Two plugins, because shedding and measuring are different jobs:
###
###   void/pressure       the sampler, the thresholds, the flag, the
###                       health line and the events — core only. A
###                       jobs worker or a CLI can have all of it.
###   void/pressure-http  the middleware that turns the flag into a
###                       503 — ./http, and the only piece that needs
###                       void/http. (ADR-0019 described one plugin;
###                       the split is the same one void/cache and
###                       void/cache-http already make, and it is what
###                       keeps a worker process from importing the
###                       HTTP kernel to find out its loop is late.)
###
### What an application composes:
###
###     (void/run! {:plugins [:void/http :void/pressure :void/pressure-http ...]})
###     # config/prod.janet
###     {:pressure {:max-loop-lag 70 :max-rss-bytes 1_500_000_000}
###      :pressure-http {:retry-after 5}}
###
### and marks the routes that must answer even then:
###
###     (defroutes ops {:void.pressure/exempt true}
###       [:get "/health" health-handler])
###
### From a REPL, `(pressure/status)`; from a shell, `void pressure
### status`; from an alerting plugin, a `:void.core/hooks` contribution
### for `:void.pressure/event`.
###
### Anything the sampler cannot measure — a database pool at its
### ceiling, a jobs queue growing faster than it drains — is a
### `:void.pressure/check` contribution: a thunk returning `{:ok
### false :reason ...}` is one more reason to shed.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./sample :as sample)
(import ./state :as state)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.pressure")

# -- the extension point -------------------------------------------------

(plugin/defextension-point :void.pressure/check
  :doc "Custom pressure checks (ADR-0019): {:name :db/pool :fn (fn [] {:ok bool :reason ...}) :doc?}; a check that answers :ok false — or throws — is one more reason to shed"
  :schema {:name :keyword
           :fn :function
           :doc [:optional :string]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (when (in seen (c :name))
                  (errorf "duplicate pressure check %q" (c :name)))
                (put seen (c :name) true)))
  :reduce |(sorted-by |($ :name) $))

(plugin/contribute! :void.core/interface
  {:name :void/pressure
   :doc "The pressure state: the flag the shedding middleware reads, the thresholds behind it and the sampler that maintains them. Depend on the interface rather than the key to let a test stand a state in its place."
   :methods {:under-pressure "true while this process is shedding"
             :reasons "why — thresholds crossed and checks that said no"
             :samples "the last sample of each signal"}})

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:pressure] config slice."
  {:enabled [:optional :boolean]
   :sample-interval [:optional [:number {:min 0.01}]]
   # milliseconds: the unit the budget in SPEC §8.2 and every
   # under-pressure-shaped dashboard is already written in
   :max-loop-lag [:optional [:number {:min 0}]]
   :max-rss-bytes [:optional [:number {:min 0}]]
   :recovery-ratio [:optional [:number {:min 0 :max 1}]]
   :recovery-samples [:optional [:int {:min 1}]]})

(def defaults
  ``Defaults of the [:pressure] slice.

  `:max-loop-lag` is the one with an argument behind it. SPEC §8.2
  budgets loop-lag p99 under 1 ms at target load, so a limit two
  orders of magnitude above that is not "slightly busy" — it is a
  process that has already stopped meeting every latency budget it
  has, and 100 ms of lag means the request being accepted right now
  starts 100 ms late. Under-pressure's own examples sit in the same
  decade. Calibration against B2/B3 is ROADMAP 2.5.

  `:max-rss-bytes` is 0 — off. A memory ceiling is the deployment's
  number (the container limit, minus headroom), and a default that
  guesses it either never trips or sheds a healthy process.``
  {:enabled true
   :sample-interval 1
   :max-loop-lag 100
   :max-rss-bytes 0
   :recovery-ratio 0.8
   :recovery-samples 2})

(defn- slice [cfg]
  (merge defaults (or cfg {})))

# -- public surface (re-exports) -----------------------------------------

(def under-pressure? "See state/under-pressure? — the flag the middleware reads." state/under-pressure?)
(def reasons "See state/reasons — why this process is shedding." state/reasons)
(def status "See state/status — everything the sampler knows." state/status)
(def state-dyn "See state/state-dyn — the state override." state/state-dyn)
(def active-state "See state/active." state/active)
(def make-state "See state/make — a state without a bootstrap." state/make)
(def observe! "See state/observe! — feed one sample in, get the transition." state/observe!)
(def start-sampler! "See state/start-sampler!." state/start-sampler!)
(def stop-sampler! "See state/stop-sampler!." state/stop-sampler!)
(def shed! "See state/shed! — count one refused request." state/shed!)

(def event-hook "See state/event-hook — the core hook transitions run through." state/event-hook)
(def events "See state/events — :high and :recovered." state/events)
(def listen! "See state/listen! — hear about transitions without a manifest." state/listen!)
(def unlisten! "See state/unlisten!." state/unlisten!)

(def add-check! "See state/add-check! — register a custom check at runtime." state/add-check!)
(def remove-check! "See state/remove-check!." state/remove-check!)

(def loop-lag "See sample/lag — one event-loop lag sample, in seconds." sample/lag)
(def rss "See sample/rss — resident set size in bytes, or nil." sample/rss)
(def available-signals "See sample/available — what this platform can measure." sample/available)

# -- the sampler component -----------------------------------------------

(defn- resolved-checks []
  (or (get-in plugin/current-boot [:extensions :void.pressure/check :resolved]) []))

(def sampler-component
  (system/component :pressure/sampler
    :doc "The pressure state and the fiber that maintains it: an
    event-loop lag and RSS sample every :sample-interval seconds,
    compared against the thresholds with a recovery bar below them,
    plus every :void.pressure/check contribution. Sets the flag the
    shedding middleware reads; in prefork (ADR-0010) one of these runs
    per worker, because each worker has the loop it is measuring."
    :provides [:void/pressure]
    :config {:key :pressure :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (def checks (resolved-checks))
      (def st (state/make cfg checks))
      (set state/current st)
      (set state/pressed false)
      (state/start-sampler! st)
      (def avail (sample/available))
      (log/info "pressure sampler ready" :ns log-ns
                :mode state/mode
                :interval (cfg :sample-interval)
                :max-loop-lag (cfg :max-loop-lag)
                :max-rss-bytes (cfg :max-rss-bytes)
                :rss-meter (avail :rss)
                :checks (map |($ :name) checks)
                :enabled (not= false (cfg :enabled)))
      (unless (or (avail :rss) (zero? (get cfg :max-rss-bytes 0)))
        (log/warn "[:pressure :max-rss-bytes] is set but this platform has no RSS meter — the limit cannot trip"
                  :ns log-ns :platform (os/which)))
      st)
    :stop
    (fn stop [st]
      (state/stop-sampler! st)
      (set state/pressed false)
      (set state/current nil))
    :health
    (fn health [st]
      (def s (state/status st))
      (merge {:status (if (st :under-pressure) :degraded :up)} s))))

# -- health --------------------------------------------------------------

(plugin/contribute! :void.core/health
  {:name :pressure/state
   :fn (fn pressure-health []
         (if-let [s (state/status)]
           (merge {:status (if (s :under-pressure) :degraded :up)} s)
           {:status :down :reason "void/pressure is not started"}))})

# -- CLI -----------------------------------------------------------------

(defn- fmt-bytes [n]
  (cond
    (not (number? n)) "—"
    (>= n 1073741824) (string/format "%.2f GiB" (/ n 1073741824))
    (>= n 1048576) (string/format "%.1f MiB" (/ n 1048576))
    (string/format "%d B" n)))

(defn print-status
  "Print a status table — the body of `void pressure status`."
  [s]
  (printf "under pressure  %s" (if (s :under-pressure) "yes" "no"))
  (printf "mode            %q%s" (s :mode)
          (if (= :supervisor (s :mode))
            "  (prefork master — every worker samples its own loop)" ""))
  (printf "for             %.1f s" (s :for))
  (printf "sampling        %s every %q s" (if (s :sampling) "on" "off") (s :interval))
  (printf "samples taken   %d" (s :sampled))
  (printf "loop lag        %.3f ms (peak %.3f ms, limit %s)"
          (get-in s [:samples :loop-lag] 0)
          (get-in s [:peaks :loop-lag] 0)
          (if-let [l (get-in s [:limits :max-loop-lag])]
            (string/format "%q ms" l) "off"))
  (printf "rss             %s (peak %s, limit %s)"
          (fmt-bytes (get-in s [:samples :rss]))
          (fmt-bytes (get-in s [:peaks :rss]))
          (if-let [l (get-in s [:limits :max-rss-bytes])] (fmt-bytes l) "off"))
  (printf "recovery        below %q× for %q samples (%d clean)"
          (get-in s [:recovery :ratio]) (get-in s [:recovery :samples])
          (get-in s [:recovery :clean]))
  (printf "episodes        %d" (s :episodes))
  (printf "shed            %d" (s :shed))
  (printf "checks          %s"
          (if (empty? (s :checks))
            "none"
            (string/join (map |(string/format "%q" $) (s :checks)) " ")))
  (unless (empty? (s :reasons))
    (print "reasons")
    (each r (s :reasons)
      (if (r :check)
        (printf "  %q  %s" (r :signal) (r :reason))
        (printf "  %q  %q over %q" (r :signal) (r :value) (r :limit))))))

(plugin/contribute! :void.core/cli
  {:name :pressure/status
   :doc "Show what the pressure sampler is seeing: void pressure status"
   :needs [:pressure/sampler]
   # :needs instances come first, then the string arguments
   :fn (fn cli-status [st & args]
         (unless (empty? args)
           (errorf "void pressure status takes no arguments (got %q)"
                   (string/join args " ")))
         (print-status (state/status st)))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/pressure
  :doc "Load shedding: an event-loop lag and RSS sampler, thresholds with recovery hysteresis behind one boolean, :void.pressure/check contributions for what the runtime cannot measure, and :high / :recovered events."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :pressure
  :config-schema Config
  :config-defaults defaults
  :components [sampler-component])
