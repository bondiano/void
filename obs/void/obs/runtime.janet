### void/obs/runtime — what a process knows about itself (SPEC.md
### §5.13 and §8.4).
###
### **The event-loop lag histogram is the point of this module.** On a
### single-threaded ev loop (ADR-0010) every other number is downstream
### of it: a latency p99 rises because the loop is late, a request
### times out because the loop is late, and a GC pause *is* the loop
### being late. SPEC §8.4 names it "the main health indicator of an ev
### system" and budgets its p99 under 1 ms; §8.2 alerts on p99 > 10 ms.
### So it is sampled here, from inside the process, with the same meter
### void/pressure reacts to and void/bench/probe budgets against
### (`void/pressure/sample` — the module, never the plugin: observing a
### process must not start shedding from it).
###
### **There are no GC metrics, and that is janet's limit rather than an
### omission.** janet 1.41 exposes `gccollect`, `gcinterval` and
### `gcsetinterval` — nothing that reports a pause, a collection count
### or an allocation rate. But a janet collection is stop-the-world on
### the one thread the loop runs on, so every pause is loop lag of at
### least its own length: `loop-lag max >= GC max pause`, always. That
### bound is what `:void.obs/loop-lag-seconds` carries, and it is the
### same reasoning void/bench/probe uses for the §8.2 GC budget. A
### fiber count has no such proxy — janet keeps no registry of live
### fibers — so what void can honestly report is the count of the
### fibers it creates itself: in-flight requests and open connections,
### which void/obs-http collects from the kernel it can see.
###
### Everything else here is the process, not the machine: RSS as the
### kernel reports it (nil, and therefore no series at all, where the
### platform has no cheap meter), uptime, and the log records that were
### dropped rather than block a request fiber (ADR-0018).

(import void/core/log :as log)
(import void/pressure/sample :as sample)
(import ./metrics :as metrics)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.obs.runtime")

# -- the instruments -----------------------------------------------------

(def lag-buckets
  ``Bucket bounds for loop lag, in seconds. The budget lives at 1 ms
  and the alert at 10 ms (SPEC §8.2/§8.4), so the resolution is
  packed between 100 µs and 25 ms — a p99 that has to distinguish
  "fine" from "alert" needs bounds on both sides of both numbers. The
  tail runs to 5 s because a loop that late is the incident being
  reconstructed, and a bucket it lands in is the difference between
  "we saw it" and "it was over the last bound".``
  [0.0001 0.00025 0.0005 0.001 0.0025 0.005 0.01 0.025 0.05 0.1 0.25 0.5 1 2.5 5])

(def loop-lag
  "How late the event loop is running — the §8.4 health indicator."
  (metrics/histogram :void.obs/loop-lag-seconds
    {:doc "Event-loop lag: how much longer than it asked for a sleep took"
     :buckets lag-buckets}))

(def loop-lag-max
  ``The largest lag seen since start. A histogram cannot report a
  maximum (the last bucket is unbounded), and this one number is the
  upper bound on the GC pauses janet does not report (see the module
  docstring).``
  (metrics/gauge :void.obs/loop-lag-max-seconds
    {:doc "Largest event-loop lag sampled since start (an upper bound on GC pause)"}))

(def samples-total
  "How many lag samples were taken — the denominator that says whether
  a quiet histogram means a calm loop or a stopped sampler."
  (metrics/counter :void.obs/loop-lag-samples-total
    {:doc "Event-loop lag samples taken"}))

(def uptime
  "Seconds since this module was loaded — process uptime, close
  enough that the difference is the bootstrap."
  (metrics/gauge :void.obs/process-uptime-seconds
    {:doc "Seconds since process start"}))

(def start-time
  "When the process started, in seconds since the epoch — the
  Prometheus `process_start_time_seconds` idiom, which is what a
  dashboard subtracts to find a restart."
  (metrics/gauge :void.obs/process-start-time-seconds
    {:doc "Process start time in seconds since the epoch"}))

(def resident-memory
  "RSS as the kernel reports it, where the platform has a cheap meter
  for it (void/pressure/sample) — and no series at all where it does
  not, because a memory number nobody can measure is worse than a
  missing one."
  (metrics/gauge :void.obs/process-resident-memory-bytes
    {:doc "Resident set size in bytes"}))

(def process-info
  ``A constant 1 carrying this process's pid. Under prefork (ADR-0010)
  every worker has its own registry, and a scrape reaches whichever
  worker the kernel handed the connection to — this label is what
  tells an operator *which* worker answered. See void/obs-http's
  module docstring for what that means for a scraper.``
  (metrics/gauge :void.obs/process-info
    {:doc "Always 1; the labels carry what identifies this process"
     :labels [:pid]}))

(def log-dropped
  "Log records an async sink dropped rather than back-pressure a
  request fiber (ADR-0018). Not zero is a sizing problem, and the
  number is the size of it."
  (metrics/counter :void.obs/log-dropped-total
    {:doc "Log records dropped by a full async sink buffer"}))

# -- the sampler ---------------------------------------------------------

(def state
  "The sampler: its fiber, its interval and the numbers that are not
  in the histogram."
  @{:running false
    :fiber nil
    :started false
    :interval 0.1
    :samples 0
    :max 0
    :last 0
    :started-at (os/clock :monotonic)
    :start-realtime (os/clock :realtime)})

(defn observe!
  "Record one lag sample, in seconds — the histogram, the maximum and
  the counter. Public because a test (and a REPL) has no reason to
  wait a tenth of a second to see the effect."
  [lag]
  (metrics/observe! loop-lag nil lag)
  (metrics/inc! samples-total)
  (put state :samples (inc (state :samples)))
  (put state :last lag)
  (when (> lag (state :max))
    (put state :max lag)
    (metrics/set! loop-lag-max nil lag))
  lag)

(defn start-sampler!
  ``Start the lag sampler: a heartbeat thread stamps the clock every
  `interval` and the fiber records how long each stamp waited to be
  taken — the cost SPEC §8.4 asks for in exchange for the only signal
  that sees a blocked loop. A heartbeat rather than an ev/sleep,
  because janet resumes sleeping fibers only when the ready queue goes
  quiet: an ev/sleep sampler under sustained traffic sleeps through
  the busy period and then books all of it as one enormous "GC pause"
  (void/pressure/sample.janet has the measurement).``
  [&opt interval]
  (default interval (state :interval))
  (unless (state :running)
    (put state :interval interval)
    (put state :running true)
    (def hb (sample/start-heartbeat! interval))
    (put state :heartbeat hb)
    (put state :fiber
         (ev/go
           (fn obs-loop-lag []
             (put state :started true)
             (protect
               (while (state :running)
                 # the wait for the beat is the measurement
                 (def lag (sample/beat hb))
                 (when (nil? lag) (put state :running false) (break))
                 (when (state :running) (observe! lag))))))))
  state)

(defn stop-sampler!
  "Stop the lag sampler: close the heartbeat (which wakes the fiber
  and retires the thread), then cancel the fiber."
  []
  (put state :running false)
  (when-let [hb (state :heartbeat)]
    (protect (sample/stop-heartbeat! hb)))
  (put state :heartbeat nil)
  (when-let [f (state :fiber)]
    (when (state :started) (protect (ev/cancel f "obs sampler stopped"))))
  (put state :fiber nil)
  (put state :started false)
  state)

(defn sampling?
  "Is the lag sampler running?"
  []
  (truthy? (state :running)))

# -- the pull-based numbers ----------------------------------------------
#
# Collected at scrape time rather than written on a timer: a gauge
# nobody reads should cost nothing, and a number read from the kernel
# is as current as the read.

(metrics/set-collector! uptime
  (fn collect-uptime [] (- (os/clock :monotonic) (state :started-at))))

(metrics/set-collector! start-time
  (fn collect-start-time [] (state :start-realtime)))

(metrics/set-collector! resident-memory
  (fn collect-rss [] (sample/rss)))

(metrics/set-collector! log-dropped
  (fn collect-log-dropped [] (log/dropped)))

(metrics/set-collector! process-info
  (let [pid (os/getpid)]
    (fn collect-process-info [] [[[pid] 1]])))

# -- the status view -----------------------------------------------------

(defn stats
  ``What the sampler has seen, in **milliseconds** — the unit §8.2 and
  every under-pressure-shaped dashboard are written in, and the unit
  `void obs status` prints. The percentiles come off the histogram
  itself (`metrics/quantile`), so what an operator reads in the REPL
  is what a scraper reads from /metrics, to the bucket.``
  []
  (defn ms [x] (when x (* 1000 x)))
  {:sampling (truthy? (state :running))
   :interval (state :interval)
   :samples (state :samples)
   :uptime (- (os/clock :monotonic) (state :started-at))
   :rss (sample/rss)
   :available (sample/available)
   :loop-lag {:last (ms (state :last))
              :p50 (ms (metrics/quantile loop-lag 0.5))
              :p90 (ms (metrics/quantile loop-lag 0.9))
              :p99 (ms (metrics/quantile loop-lag 0.99))
              :max (ms (state :max))}})

(defn health
  ``The health value of the runtime component: up, plus the numbers
  that make a /health response worth reading. `:degraded` is
  deliberately not in here — void/pressure is the plugin that decides
  a process is in trouble, and two plugins with two opinions about it
  is how a load balancer gets contradictory answers.``
  []
  (def s (stats))
  {:status :up
   :sampling (s :sampling)
   :samples (s :samples)
   :loop-lag-p99 (get-in s [:loop-lag :p99])
   :loop-lag-max (get-in s [:loop-lag :max])
   :rss (s :rss)
   :uptime (s :uptime)
   :metrics (length metrics/registry)})
