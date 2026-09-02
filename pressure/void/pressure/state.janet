### void/pressure/state — the flag, and everything that decides it
### (SPEC.md §5.23, ADR-0019).
###
### One boolean is the whole hot path. Every request that reaches the
### shedding middleware asks exactly one question — "is this process
### under pressure right now?" — and the answer is a var deref, not a
### measurement: the measuring happens on the sampler's own fiber, on
### its own interval, and it writes the boolean the requests read.
###
### **Hysteresis is not a refinement, it is the feature.** A threshold
### compared the same way in both directions turns a process sitting
### near its limit into a process that sheds every other request and
### recovers in between, which is worse than either state — the
### traffic gets neither its latency nor its answers, and every alert
### fires on a square wave. So there are two bars: a sample trips at
### `:max-loop-lag`, and the process only comes back under
### `:recovery-ratio` × that, for `:recovery-samples` samples in a
### row. What comes out of it is a state with edges — `:high` and
### `:recovered` fire once each per episode, not once per sample.
###
### Custom checks (`:void.pressure/check`) get no hysteresis, because
### there is nothing to interpolate: a check answers `{:ok false}` or
### it does not, and "the pool is exhausted" is not a number that can
### be 80% of itself. A check that throws counts as pressure — a
### health probe whose failure means "carry on" is not a probe.
###
### Events are the seam void/bus takes over in wave 3. Until then they
### run as synchronous hooks on the core registry (`:void.pressure/event`)
### plus any listener registered with `listen!`, exactly as void/jobs
### fires its lifecycle events, and a listener that throws is logged
### rather than allowed to break the sampler.

(import void/core/log :as log)
(import void/core/hooks :as hooks)
(import void/core/plugin :as plugin)
(import ./sample :as sample)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.pressure")

# -- the hot path --------------------------------------------------------

(var pressed
  ``The flag itself: true while this process is shedding. A module
  var, read directly by the middleware — the one thing on the request
  path that pressure costs.``
  false)

(defn under-pressure?
  "Is this process under pressure right now?"
  []
  pressed)

(var current
  "The value of the running :pressure/sampler component (set by its
  :start). One per process, like plugin/current-boot."
  nil)

(var mode
  ``What this process is, as far as pressure is concerned.

  `:process` — it serves the traffic, so its own loop is the thing
  worth measuring. The default, and every process that is not the
  other one.

  `:supervisor` — it serves nothing: the prefork master (ADR-0010),
  which spawns workers and waits on them. Its loop is idle by
  construction, so a sampler there would publish a reassuring zero
  that is about nobody's requests, and every worker has its own loop
  and its own sampler anyway. void/pressure-http sets this before the
  component starts; the sampler then does not run, and the health line
  says so rather than implying a measurement nobody took.``
  :process)

(def state-dyn
  "Dynamic binding: state override — bind it to run a scope against a
  state other than the started component (tests, REPL)."
  :void.pressure/state)

(defn active
  "The state this fiber reads: the `state-dyn` override, else the
  started component's."
  []
  (or (dyn state-dyn) current))

# -- events --------------------------------------------------------------

(def event-hook
  "The core hook every pressure transition is run through. Handlers
  receive {:event :high :reasons [...] :at <realtime>}."
  :void.pressure/event)

(def events
  "Every event a state fires: it went over its thresholds, and it came
  back."
  [:high :recovered])

(def listeners
  ``Listeners registered at runtime, by name. The extension-point way
  to hear about pressure is a `:void.core/hooks` contribution for
  `event-hook`; this table is for the code that has no manifest — a
  test, a REPL, and (wave 3) the bridge that forwards these into
  void/bus.``
  @{})

(defn listen!
  "Register a listener under `name` (re-registering replaces it)."
  [name f]
  (put listeners name f)
  f)

(defn unlisten!
  "Remove a listener by name."
  [name]
  (put listeners name nil))

(defn emit!
  ``Fire a transition event: the `event-hook` handlers of the running
  boot, then every `listen!` listener. Nothing here may break the
  sampler, so a handler that throws is logged at :warn and the rest
  still run.``
  [event payload]
  (def ev (merge {:event event :at (os/clock :realtime)} (or payload {})))
  (when-let [reg (get plugin/current-boot :hooks)]
    (each e (hooks/handlers reg event-hook)
      (def [ok err] (protect ((e :fn) ev)))
      (unless ok
        (log/warn "pressure event handler failed" :ns log-ns
                  :handler (e :name) :event event :err err))))
  (each name (sorted (keys listeners))
    (when-let [f (get listeners name)]
      (def [ok err] (protect (f ev)))
      (unless ok
        (log/warn "pressure event listener failed" :ns log-ns
                  :listener name :event event :err err))))
  ev)

# -- the state -----------------------------------------------------------

(def signals
  "Sampled signal -> the config key that caps it. Order is the order
  reasons are reported in."
  [[:loop-lag :max-loop-lag]
   [:rss :max-rss-bytes]])

(defn make
  ``A pressure state from the [:pressure] slice and the resolved
  `:void.pressure/check` contributions ({:name :fn} each). Nothing is
  sampled until `start-sampler!`.``
  [cfg &opt checks]
  @{:config (freeze cfg)
    :checks (array ;(or checks []))
    :under-pressure false
    :reasons []
    :samples @{}
    :peaks @{}
    :clean 0
    :sampled 0
    :sheds 0
    :episodes 0
    :since (os/clock :monotonic)
    :changed-at (os/clock :realtime)
    :sampling false
    :fiber nil
    :pid (os/getpid)})

(defn- limit [st key]
  (def v (get-in st [:config key]))
  (when (and (number? v) (pos? v)) v))

(defn- threshold-reasons
  ``The sampled signals that are over their bar. Under pressure the
  bar is `:recovery-ratio` × the limit — the same sample answers
  differently depending on which way the process is crossing.``
  [st samples]
  (def ratio (get-in st [:config :recovery-ratio] 0.8))
  (def down? (st :under-pressure))
  (def out @[])
  (each [signal key] signals
    (def lim (limit st key))
    (def v (get samples signal))
    (when (and lim (number? v))
      (def bar (if down? (* lim ratio) lim))
      (when (> v bar)
        (array/push out {:signal signal :value v :limit lim :bar bar}))))
  out)

(defn- check-reasons
  "The custom checks that said no — or threw, which counts as no."
  [st]
  (def out @[])
  (each c (st :checks)
    (def [ok r] (protect ((c :fn))))
    (cond
      (not ok)
      (array/push out {:signal (c :name) :check true
                       :reason (string "check failed: "
                                       (if (bytes? r) (string r) (describe r)))})

      (and (dictionary? r) (not (get r :ok)))
      (array/push out {:signal (c :name) :check true
                       :reason (get r :reason "check reported pressure")})))
  out)

(defn- record-peaks! [st samples]
  (eachp [k v] samples
    (when (number? v)
      (put (st :peaks) k (max v (get-in st [:peaks k] 0))))))

(defn observe!
  ``Feed one set of samples ({:loop-lag <ms> :rss <bytes>}) into the
  state: evaluate the thresholds and the custom checks, apply the
  hysteresis, and fire :high / :recovered on an edge. Returns the
  transition (:high, :recovered or nil) — the sampler's loop is the
  usual caller, and a test is the other one, which is why the sleeping
  and the deciding are different functions.``
  [st samples]
  (update st :sampled inc)
  (merge-into (st :samples) samples)
  (record-peaks! st samples)
  (def reasons (array/concat (threshold-reasons st samples) (check-reasons st)))
  (def over? (not (empty? reasons)))
  (put st :reasons (tuple ;reasons))
  (var transition nil)
  (cond
    (and over? (not (st :under-pressure)))
    (do
      (put st :under-pressure true)
      (put st :clean 0)
      (put st :since (os/clock :monotonic))
      (put st :changed-at (os/clock :realtime))
      (update st :episodes inc)
      (when (= st (active)) (set pressed true))
      (set transition :high))

    (and (not over?) (st :under-pressure))
    (do
      (update st :clean inc)
      (when (>= (st :clean) (get-in st [:config :recovery-samples] 2))
        (put st :under-pressure false)
        (put st :clean 0)
        (put st :since (os/clock :monotonic))
        (put st :changed-at (os/clock :realtime))
        (when (= st (active)) (set pressed false))
        (set transition :recovered)))

    (put st :clean 0))
  (case transition
    :high
    (do
      (log/warn "under pressure — shedding" :ns log-ns
                :reasons (map |(get $ :signal) reasons)
                :loop-lag (get samples :loop-lag)
                :rss (get samples :rss))
      (emit! :high {:reasons (st :reasons) :samples (freeze (st :samples))}))

    :recovered
    (do
      (log/info "pressure recovered" :ns log-ns
                :shed (st :sheds)
                :loop-lag (get samples :loop-lag)
                :rss (get samples :rss))
      (emit! :recovered {:samples (freeze (st :samples)) :shed (st :sheds)})))
  transition)

(defn shed!
  "Count one shed request. Returns the running count for this state."
  [st]
  (update st :sheds inc))

# -- the sampler fiber ---------------------------------------------------

(defn start-sampler!
  ``Start sampling. Idempotent, and a no-op when `:enabled` is false —
  a process that only wants the middleware compiled out (a test, a
  worker under a supervisor that already sheds) says so in config
  rather than by not loading the plugin.``
  [st]
  (def interval (get-in st [:config :sample-interval] 1))
  (when (and (not (st :sampling))
             (not= false (get-in st [:config :enabled]))
             (not= :supervisor mode)
             (pos? interval))
    (put st :sampling true)
    # the meter is a heartbeat thread, not an ev/sleep in this fiber:
    # a sleeping fiber is only resumed when the ready queue goes quiet,
    # so under sustained traffic it sleeps through the whole busy
    # period and then reports it as one giant lag — a shedder fed that
    # way refuses requests the process was serving in milliseconds,
    # and fires an episode right as the load *ends* (sample.janet has
    # the numbers)
    (def hb (sample/start-heartbeat! interval))
    (put st :heartbeat hb)
    (put st :fiber
         (ev/go
           (fn pressure-sampler []
             # the same cancellation race the cache sweeper documents:
             # a state stopped in the turn it was started cannot catch a
             # cancel delivered before the fiber's first instruction, so
             # the fiber marks itself live here and a stop that arrives
             # earlier just clears :sampling
             (put st :started true)
             (protect
               (while (st :sampling)
                 # the wait for the beat *is* the loop-lag measurement
                 (def lag-s (sample/beat hb))
                 (when (nil? lag-s) (put st :sampling false) (break))
                 (def lag-ms (* 1000 lag-s))
                 (when (st :sampling)
                   (def [ok err]
                     (protect (observe! st @{:loop-lag lag-ms :rss (sample/rss)})))
                   (unless ok
                     (log/warn "pressure sample failed" :ns log-ns :err err)))))))))
  st)

(defn stop-sampler!
  "Stop sampling. The heartbeat channel is closed (which both wakes a
  fiber parked in `beat` and tells the thread to exit) and the fiber
  is cancelled rather than waited for, so a shutdown never sits out a
  sample interval."
  [st]
  (put st :sampling false)
  (when-let [hb (st :heartbeat)]
    (protect (sample/stop-heartbeat! hb)))
  (put st :heartbeat nil)
  (when-let [f (st :fiber)]
    (when (st :started)
      (protect (ev/cancel f "pressure sampler stopped"))))
  (put st :fiber nil)
  (put st :started false)
  st)

# -- reading it ----------------------------------------------------------

(defn reasons
  "Why this state is shedding — a tuple of {:signal :value :limit} (a
  threshold) or {:signal :check :reason} (a custom check). Empty when
  it is not."
  [&opt st]
  (default st (active))
  (if st (st :reasons) []))

(defn status
  ``What the sampler knows, for `(pressure/status)`, the health
  contribution and `void pressure status`. Without `st`, the active
  state — nil when void/pressure is not started.``
  [&opt st]
  (default st (active))
  (when st
    {:under-pressure (st :under-pressure)
     :mode mode
     :reasons (st :reasons)
     :samples (freeze (st :samples))
     :peaks (freeze (st :peaks))
     :available (sample/available)
     :limits {:max-loop-lag (limit st :max-loop-lag)
              :max-rss-bytes (limit st :max-rss-bytes)}
     :recovery {:ratio (get-in st [:config :recovery-ratio])
                :samples (get-in st [:config :recovery-samples])
                :clean (st :clean)}
     :interval (get-in st [:config :sample-interval])
     :sampling (truthy? (st :sampling))
     :sampled (st :sampled)
     :shed (st :sheds)
     :episodes (st :episodes)
     :for (- (os/clock :monotonic) (st :since))
     :checks (tuple ;(map |($ :name) (st :checks)))
     :pid (st :pid)}))

# -- checks registered outside a manifest --------------------------------

(defn add-check!
  ``Register a custom check on a state at runtime: (fn [] {:ok bool
  :reason ...}). The extension-point way is a `:void.pressure/check`
  contribution; this is for a test, a REPL and anything else with no
  manifest. Re-registering a name replaces it.``
  [st name f]
  (put st :checks
       (array ;(filter |(not= name ($ :name)) (st :checks))
              {:name name :fn f}))
  st)

(defn remove-check!
  "Drop a check by name."
  [st name]
  (put st :checks (array ;(filter |(not= name ($ :name)) (st :checks))))
  st)
