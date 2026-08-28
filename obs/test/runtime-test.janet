# The runtime numbers: the loop-lag histogram every other signal is
# downstream of, the sampler fiber behind it, and the pull-based
# process gauges.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/obs/metrics :as metrics)
(import void/obs/runtime :as runtime)

(log/set-level! "void.obs" :error)

# -- one sample ----------------------------------------------------------

(metrics/reset! :void.obs/loop-lag-seconds)
(metrics/reset! :void.obs/loop-lag-samples-total)
(put runtime/state :samples 0)
(put runtime/state :max 0)

(each lag [0.0002 0.002 0.02 0.2]
  (runtime/observe! lag))

(def series (metrics/value runtime/loop-lag))
(assert (= 4 (series :count)) "every sample lands in the histogram")
(assert (= 0.2 (runtime/state :max)) "the maximum is kept beside it — a histogram has no maximum, and the GC bound needs one")
(assert (= 0.2 (metrics/value runtime/loop-lag-max)))
(assert (= 4 (metrics/value runtime/samples-total))
        "and the sample count says whether a quiet histogram is a calm loop or a stopped sampler")

(def s (runtime/stats))
(assert (= 4 (s :samples)))
(assert (= 200 (get-in s [:loop-lag :max])) "the status view is in milliseconds — the unit §8.2 is written in")
(assert (<= (get-in s [:loop-lag :p50]) (get-in s [:loop-lag :p99]))
        "and the percentiles come off the histogram itself, so the REPL and /metrics cannot disagree")

# -- the sampler ---------------------------------------------------------

(assert (not (runtime/sampling?)))
(runtime/start-sampler! 0.005)
(assert (runtime/sampling?))
(def before (runtime/state :samples))
(ev/sleep 0.05)
(assert (> (runtime/state :samples) before) "the fiber is sampling this process's own loop")
(runtime/stop-sampler!)
(def after (runtime/state :samples))
(ev/sleep 0.03)
(assert (= after (runtime/state :samples)) "and stops when it is told to")

# -- the pull-based gauges ----------------------------------------------

(def snap (metrics/snapshot))
(defn- series-of [name]
  (get-in (first (filter |(= name ($ :name)) snap)) [:series]))

(assert (pos? (get-in (series-of :void.obs/process-uptime-seconds) [0 :value]))
        "uptime is collected at scrape time, not written on a timer")
(assert (pos? (get-in (series-of :void.obs/process-start-time-seconds) [0 :value])))
(assert (indexed? (series-of :void.obs/log-dropped-total)))

(def rss (series-of :void.obs/process-resident-memory-bytes))
(if (get-in (runtime/stats) [:available :rss])
  (assert (pos? (get-in rss [0 :value])) "where the platform has an RSS meter, the gauge carries it")
  (assert (empty? rss) "and where it has none there is no series at all, rather than a zero nobody can trust"))

# -- health --------------------------------------------------------------

(def h (runtime/health))
(assert (= :up (h :status)))
(assert (number? (h :metrics)))
(assert (not (h :sampling)) "the health line says whether the sampler is actually running")

(print "runtime-test ok")
