### void/bench/probe — the runtime budgets, measured from
### inside the process that is under load.
###
### The latency and throughput budgets are measured by wrk from
### outside. The other two are not measurable from out there at all:
###
###   ev loop lag  p99 < 1 ms under target load —
###                "the main health indicator of an ev system". A
###                client sees the *consequence* of loop lag mixed
###                into every latency number; only the process itself
###                can see the lag.
###   GC pauses    max < 10 ms on the B3 profile.
###
### So the mini-apps carry this plugin, a fiber samples the lag they
### actually experience while wrk is hammering them, and the runner
### reads the percentiles off `GET /void/bench/probe` when the timed
### runs are done. It is the same meter void/pressure ships
### (`void/pressure/sample`) — one implementation of loop-lag in the
### monorepo, used by the thing that reacts to it and by the thing
### that budgets it.
###
### **On the GC budget, and why there is no GC number here.** janet
### 1.41 exposes no GC statistics — `gccollect`, `gcinterval`,
### `gcsetinterval`, and nothing that reports a pause. But a janet GC
### is stop-the-world on the one thread the loop runs on, so *every*
### GC pause is loop lag, of at least its own length: `loop-lag max >=
### GC max pause`, always. The maximum is therefore a sound upper
### bound, and `:max-loop-lag` in the budget table is what enforces
### "GC max pause < 10 ms" — conservatively, since a lag maximum over
### the bound may be the GC or may be a slow handler, and the check
### does not pretend to know which. The other half of the GC
### budget — "under 2% of total time" — has no such bound available
### (handler CPU is indistinguishable from collector CPU from in
### here) and stays unmeasured until janet reports its own.
###
### It imports void/pressure's meter but not the plugin: `:requires` would
### force `:void/pressure` into every app carrying a probe, and an app
### that measures B0 must not be dragging a sampler nobody asked for into
### the B0 numbers. What void/pressure costs is its own bench row
### (`b1-pressure`), not a tax on everyone else's.
###
### Sampling costs: one fiber waking every :interval (10 ms by
### default) and one number appended. The B0/B1 rows measured with the
### probe in the app are the ones the thresholds compare, so its cost
### is inside the baseline rather than beside it.

(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/pressure/sample :as sample)
(import ./targets :as targets)

(def Config
  "Schema of the [:bench-probe] config slice."
  {:interval [:optional [:number {:min 0.001}]]
   :max-samples [:optional [:int {:min 100}]]})

(def defaults
  ``Defaults of the [:bench-probe] slice. 10 ms of interval is 100
  samples a second — six thousand over a 60 s run, which is enough
  resolution for a p99 and few enough that the sampling is not itself
  the load.``
  {:interval 0.01
   :max-samples 100000})

(var probe
  "The running probe state, or nil."
  nil)

(defn make
  "A probe state: the reservoir and the fiber handle."
  [cfg]
  @{:interval (get cfg :interval 0.01)
    :max-samples (get cfg :max-samples 100000)
    :samples @[]
    :dropped 0
    :started-at (os/clock :monotonic)
    :running false
    :fiber nil})

(defn reset!
  "Drop every sample and restart the clock — what the runner calls
  before the timed runs, so the numbers describe the load and not the
  warmup."
  [p]
  (array/clear (p :samples))
  (put p :dropped 0)
  (put p :started-at (os/clock :monotonic))
  p)

(defn- percentile [sorted q]
  (when (pos? (length sorted))
    (def i (math/floor (* q (dec (length sorted)))))
    (in sorted i)))

(defn stats
  ``The loop-lag distribution in milliseconds, plus RSS. `:max` is the
  one the GC budget rides on (see the module docstring).``
  [p]
  (def ms (sorted (map |(* 1000 $) (p :samples))))
  (def n (length ms))
  {:samples n
   :dropped (p :dropped)
   :window (- (os/clock :monotonic) (p :started-at))
   :interval (p :interval)
   :loop-lag (if (zero? n)
               {}
               {:p50 (percentile ms 0.5)
                :p90 (percentile ms 0.9)
                :p99 (percentile ms 0.99)
                :max (last ms)
                :mean (/ (sum ms) n)})
   :rss (sample/rss)})

(defn start! [p]
  (unless (p :running)
    (put p :running true)
    (put p :fiber
         (ev/go
           (fn bench-probe []
             (put p :started true)
             (protect
               (while (p :running)
                 # the sleep is the measurement (void/pressure/sample)
                 (def lag (sample/lag (p :interval)))
                 (when (p :running)
                   (if (< (length (p :samples)) (p :max-samples))
                     (array/push (p :samples) lag)
                     (put p :dropped (inc (p :dropped)))))))))))
  p)

(defn stop! [p]
  (put p :running false)
  (when-let [f (p :fiber)]
    (when (p :started) (protect (ev/cancel f "bench probe stopped"))))
  (put p :fiber nil)
  (put p :started false)
  p)

# -- the endpoint --------------------------------------------------------

(def path
  "Where the runner reads the probe — ./targets, with the rest of the
  suite's data. Under /void/ so it can never collide with a bench
  app's own routes."
  targets/probe-path)

(defn handler
  ``GET /void/bench/probe — the stats as JSON. `?reset=1` clears the
  reservoir after reading, which is how the runner brackets a set of
  timed runs.``
  [req]
  (def p (or probe (error "bench probe is not started")))
  (def body (stats p))
  (when (get-in req [:query "reset"]) (reset! p))
  (ring/response 200 (json/encode body)
                 @{"content-type" "application/json"}))

(plugin/contribute! :void.http/route-source
  {:name :bench/probe
   :routes (router/routes {}
             (router/GET path 'handler {:name :bench/probe}))
   :env (router/env-ref (curenv))})

(def component
  (system/component :bench/probe
    :doc "The loop-lag sampler the runtime budgets are read from."
    :config {:key :bench-probe :schema Config}
    :start
    (fn start [_ cfg]
      (def p (make (merge defaults (or cfg {}))))
      (set probe p)
      (start! p))
    :stop
    (fn stop [p]
      (stop! p)
      (set probe nil))
    :health (fn health [p] {:status :up :samples (length (p :samples))})))

(plugin/defplugin bench/probe
  :doc "Runtime budgets from inside the process under load: an event-loop lag reservoir behind GET /void/bench/probe, sampled with the same meter void/pressure uses."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :bench-probe
  :config-schema Config
  :config-defaults defaults
  :components [component])
