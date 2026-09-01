### void/bench/results — result files, environment capture and the 5%
### regression comparison (ADR-0014).
###
### A result set is plain data ({:env :settings :rows}) written as jdn;
### компаранды are two such files — a recorded baseline vs the current
### run locally, or the base-commit run vs the head run on the same CI
### runner (shared runners only support relative thresholds). Latency
### percentiles are only compared inside the :latency (wrk2) mode —
### wrk's max-throughput latency is CO-biased; throughput only inside
### :throughput.

(def default-threshold
  "Allowed degradation between commits (ADR-0014): 5%."
  0.05)

(def latency-floor-ms
  "Absolute latency delta below which a percentile move is noise, not
  a regression — sub-0.1ms shifts flap on shared runners."
  0.1)

# -- environment ---------------------------------------------------------

(defn- capture
  "First line of a shell command's stdout, or nil — environment
  capture is best-effort everywhere."
  [cmd]
  (def [ok v]
    (protect
      (do
        (def p (os/spawn ["sh" "-c" cmd] :p {:out :pipe :err :pipe}))
        (def out (string (ev/read (p :out) :all)))
        (ev/read (p :err) :all)
        (def code (os/proc-wait p))
        (when (zero? code)
          (string/trim (first (string/split "\n" out)))))))
  (when (and ok v (not (empty? v))) v))

(defn environment
  "The методика-mandated run context (SPEC §8.3): janet version, CPU,
  frequency governor, plus os/commit/date for the record."
  []
  @{:janet janet/version
    :os (os/which)
    :uname (capture "uname -sm")
    :cpus (or (os/cpu-count)
              (scan-number (or (capture "getconf _NPROCESSORS_ONLN") "")))
    :cpu (or (capture "sysctl -n machdep.cpu.brand_string 2>/dev/null")
             (capture "sed -n 's/^model name[^:]*: //p' /proc/cpuinfo"))
    :governor (capture "cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null")
    :commit (capture "git rev-parse --short HEAD 2>/dev/null")
    :date (capture "date -u '+%Y-%m-%dT%H:%M:%SZ'")})

# -- files ---------------------------------------------------------------

(defn- ensure-parent [path]
  (def parts (string/split "/" path))
  (var cur (if (string/has-prefix? "/" path) "" "."))
  (each part (drop -1 parts)
    (unless (empty? part)
      (set cur (string cur "/" part))
      (unless (os/stat cur)
        (os/mkdir cur)))))

(defn write-file
  "Write a result set as jdn."
  [path results]
  (ensure-parent path)
  (spit path (string/format "%j\n" results)))

(defn read-file
  "Read a result set back."
  [path]
  (parse (slurp path)))

# -- comparison ----------------------------------------------------------

(defn- entry [target mode metric base current]
  {:target target :mode mode :metric metric
   :base base :current current
   :delta (/ (- current base) base)})

(defn compare-results
  ``Compare two result sets under a relative threshold (default 5%).
  Returns {:regressions [entry...] :improvements [entry...]
  :missing [target...]} — :missing lists baseline targets the current
  run did not cover (never a failure: subset runs are normal).``
  [base current &opt threshold]
  (default threshold default-threshold)
  (def regressions @[])
  (def improvements @[])
  (def missing @[])
  (eachp [tname brow] (get base :rows {})
    (def crow (get-in current [:rows tname]))
    (if (nil? crow)
      (array/push missing tname)
      (do
        # higher is better; only the max-throughput mode measures it
        (def brps (get-in brow [:throughput :rps]))
        (def crps (get-in crow [:throughput :rps]))
        (when (and (number? brps) (number? crps) (pos? brps))
          (def e (entry tname :throughput :rps brps crps))
          (cond
            (< (e :delta) (- threshold)) (array/push regressions e)
            (> (e :delta) threshold) (array/push improvements e)))
        # lower is better; only the fixed-rate (wrk2) mode is honest
        (each k [:p50 :p99]
          (def b (get-in brow [:latency k]))
          (def c (get-in crow [:latency k]))
          (when (and (number? b) (number? c) (pos? b))
            (def e (entry tname :latency k b c))
            (cond
              (and (> (e :delta) threshold)
                   (> (- c b) latency-floor-ms))
              (array/push regressions e)

              (and (< (e :delta) (- threshold))
                   (> (- b c) latency-floor-ms))
              (array/push improvements e))))
        # B4's own two numbers: messages delivered per
        # second, higher better, and delivery p50/p99, lower better.
        # They live in their own mode because they mean something
        # different from a request's — the comparison must not put a
        # fan-out and a request latency in the same column
        (let [b (get-in brow [:broadcast :rps])
              c (get-in crow [:broadcast :rps])]
          (when (and (number? b) (number? c) (pos? b))
            (def e (entry tname :broadcast :rps b c))
            (cond
              (< (e :delta) (- threshold)) (array/push regressions e)
              (> (e :delta) threshold) (array/push improvements e))))
        (each k [:p50 :p99]
          (def b (get-in brow [:broadcast k]))
          (def c (get-in crow [:broadcast k]))
          (when (and (number? b) (number? c) (pos? b))
            (def e (entry tname :broadcast k b c))
            (cond
              (and (> (e :delta) threshold) (> (- c b) latency-floor-ms))
              (array/push regressions e)

              (and (< (e :delta) (- threshold)) (> (- b c) latency-floor-ms))
              (array/push improvements e))))
        # the loop's own lag under target load — the signal that moves
        # first when something starts blocking (§8.4). Same absolute
        # floor as the latencies: these numbers live below a
        # millisecond, and a 5% move on 0.05ms is noise with a
        # percentage sign on it
        (let [b (get-in brow [:runtime :loop-lag :p99])
              c (get-in crow [:runtime :loop-lag :p99])]
          (when (and (number? b) (number? c) (pos? b))
            (def e (entry tname :runtime :loop-lag-p99 b c))
            (cond
              (and (> (e :delta) threshold) (> (- c b) latency-floor-ms))
              (array/push regressions e)

              (and (< (e :delta) (- threshold)) (> (- b c) latency-floor-ms))
              (array/push improvements e)))))))
  {:regressions regressions :improvements improvements :missing missing})

(defn- fmt-value [metric v]
  (if (= metric :rps)
    (string/format "%.0f rps" v)
    (string/format "%.2fms" v)))

(defn print-comparison
  "Human-readable comparison; returns the comparison value."
  [cmp]
  (each [label entries] [["regressions" (cmp :regressions)]
                         ["improvements" (cmp :improvements)]]
    (unless (empty? entries)
      (printf "%s:" label)
      (each e entries
        (printf "  %s %s %s: %s -> %s (%+.1f%%)"
                (e :target) (e :mode) (e :metric)
                (fmt-value (e :metric) (e :base))
                (fmt-value (e :metric) (e :current))
                (* 100 (e :delta))))))
  (unless (empty? (cmp :missing))
    (printf "not covered by this run: %s"
            (string/join (map string (cmp :missing)) " ")))
  (when (and (empty? (cmp :regressions)) (empty? (cmp :improvements)))
    (print "no significant change"))
  cmp)

# -- budgets -------------------------------------------------------------

(defn- broadcast-notes
  ``B4's budget (§8.2's last row): delivery under 50 ms to a thousand
  connections at 10k messages a second. Nothing else applies to it —
  there is no request throughput and no request latency in a fan-out,
  and a check that reported them as unmeasured would be reporting the
  absence of numbers that do not exist.``
  [row budget note]
  (def b (get row :broadcast))
  (if (nil? b)
    (note :skip "the broadcast generator did not run")
    (do
      (def conns (get b :connections 0))
      (note (if (>= conns (budget :connections)) :ok :miss)
            (string/format "%d connections held (budget %d)"
                           conns (budget :connections)))
      (def rps (get b :rps))
      (if (number? rps)
        (note (if (>= rps (budget :rps)) :ok :miss)
              (string/format "%.0f messages/s delivered (floor %d)"
                             rps (budget :rps)))
        (note :skip "message rate not measured"))
      (def p99 (get b :p99))
      (if (number? p99)
        (note (if (< p99 (budget :delivery-p99)) :ok :miss)
              (string/format "delivery p99 %.2fms (budget < %.1fms)"
                             p99 (budget :delivery-p99)))
        (note :skip "delivery p99 not measured"))
      (each k [:errors :closed]
        (when-let [n (get b k)]
          (note :miss (string/format "%d %s during the run" n k)))))))

(defn budget-notes
  ``Check one row against a §8.2 budget ({:p50 :p99 :rps} plus the
  optional runtime keys :loop-lag-p99 and :loop-lag-max). Latency and
  the runtime numbers come from the fixed-rate mode only; a missing
  measurement is reported as unchecked. A budget carrying
  `:kind :broadcast` (B4) is checked against its own metrics instead.
  Returns [[:ok|:miss|:skip text] ...].``
  [row budget]
  (def notes @[])
  (defn note [status text] (array/push notes [status text]))
  (when (= :broadcast (get budget :kind))
    (broadcast-notes row budget note)
    (when-let [limit (budget :loop-lag-p99)]
      (def v (get-in row [:runtime :loop-lag :p99]))
      (if (number? v)
        (note (if (< v limit) :ok :miss)
              (string/format "loop-lag p99 %.3fms (budget < %.1fms)" v limit))
        (note :skip "loop-lag p99 not measured (no probe in the target)")))
    (break notes))
  (def rps (get-in row [:throughput :rps]))
  (if (number? rps)
    (note (if (>= rps (budget :rps)) :ok :miss)
          (string/format "throughput %.0f rps (floor %d)" rps (budget :rps)))
    (note :skip "throughput not measured (wrk missing)"))
  (each k [:p50 :p99]
    (def v (get-in row [:latency k]))
    (if (number? v)
      (note (if (< v (budget k)) :ok :miss)
            (string/format "%s %.2fms (budget < %.1fms)" k v (budget k)))
      (note :skip (string/format "%s not measured under fixed rate (wrk2 missing)" k))))
  # the two budgets only the process itself can see (§8.2, §8.4): the
  # loop-lag p99 under target load, and the GC maximum — which rides on
  # loop-lag max because a stop-the-world pause on a single-threaded
  # loop *is* loop lag of at least its own length, and janet reports no
  # pause of its own (void/bench/probe)
  (each [bkey pkey label] [[:loop-lag-p99 :p99 "loop-lag p99"]
                           [:loop-lag-max :max "loop-lag max (GC pause bound)"]]
    (when-let [limit (budget bkey)]
      (def v (get-in row [:runtime :loop-lag pkey]))
      (if (number? v)
        (note (if (< v limit) :ok :miss)
              (string/format "%s %.3fms (budget < %.1fms)" label v limit))
        (note :skip (string/format "%s not measured (no probe in the target, or no wrk2)" label)))))
  notes)
