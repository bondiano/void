### void/bench/wrk — driving wrk/wrk2 and reading their output
### (SPEC.md §8.3, ADR-0014).
###
### wrk2 (fixed -R rate) is the only honest latency source — wrk's
### latency numbers under max throughput suffer coordinated omission
### and are parsed but only ever compared against themselves. Both
### tools print a `--latency` percentile block and a Requests/sec
### line; `parse` reads those plus the error counters, `summarize`
### folds the per-run tables into medians (методика: median of 3×60s).

(def- pct-line
  "A percentile row of either tool's --latency block:
  `     50%  634.00us` (wrk) or ` 50.000%    1.23ms` (wrk2). The
  detailed wrk2 spectrum rows (value first, percentile as a fraction,
  no % sign) deliberately do not match."
  (peg/compile
    '(* :s* (<- (some (+ :d "."))) "%" :s+
        (<- (some (+ :d "."))) (<- (some (range "az"))) :s* -1)))

(def- rps-line
  (peg/compile '(* :s* "Requests/sec:" :s* (<- (some (+ :d "."))))))

(def- non2xx-line
  (peg/compile '(* :s* "Non-2xx or 3xx responses:" :s* (<- (some :d)))))

(def- socket-errors-line
  (peg/compile
    '(* :s* "Socket errors: connect " (<- (some :d))
        ", read " (<- (some :d))
        ", write " (<- (some :d))
        ", timeout " (<- (some :d)))))

(defn to-ms
  "A latency value in wrk's unit -> milliseconds."
  [v unit]
  (case unit
    "us" (/ v 1000)
    "ms" v
    "s" (* v 1000)
    "m" (* v 60000)
    (errorf "unknown latency unit %q" unit)))

(def- tracked-percentiles
  {50 :p50 75 :p75 90 :p90 99 :p99 99.9 :p999})

(defn parse
  ``One wrk/wrk2 stdout -> @{:rps <num> :latency @{:p50 <ms> ...}
  :non-2xx <n>? :socket-errors <n>?}. Percentiles other than
  50/75/90/99/99.9 are ignored.``
  [out]
  (def res @{:latency @{}})
  (each line (string/split "\n" out)
    (when-let [[pct val unit] (peg/match pct-line line)]
      (when-let [k (get tracked-percentiles (scan-number pct))]
        (put (res :latency) k (to-ms (scan-number val) unit))))
    (when-let [[rps] (peg/match rps-line line)]
      (put res :rps (scan-number rps)))
    (when-let [[n] (peg/match non2xx-line line)]
      (put res :non-2xx (scan-number n)))
    (when-let [counts (peg/match socket-errors-line line)]
      (put res :socket-errors (sum (map scan-number counts)))))
  res)

(defn median
  "The median of a list of numbers (mean of the middle two for even
  lengths); nil for an empty list."
  [xs]
  (def s (sorted xs))
  (def n (length s))
  (cond
    (zero? n) nil
    (odd? n) (in s (div n 2))
    (/ (+ (in s (dec (div n 2))) (in s (div n 2))) 2)))

(defn summarize
  ``Fold parsed runs into one row: per-metric medians, error counters
  summed. Metrics a run did not report are skipped.``
  [runs]
  (def out @{})
  (when-let [m (median (filter number? (map |(get $ :rps) runs)))]
    (put out :rps m))
  (each k [:p50 :p75 :p90 :p99 :p999]
    (def vs (filter number? (map |(get-in $ [:latency k]) runs)))
    (unless (empty? vs)
      (put out k (median vs))))
  (each k [:non-2xx :socket-errors]
    (def n (sum (map |(get $ k 0) runs)))
    (when (pos? n)
      (put out k n)))
  out)

# -- invocation ----------------------------------------------------------

(defn tool-argv
  "An overridable tool name (VOID_BENCH_WRK / VOID_BENCH_WRK2 may hold
  a multi-word command) -> argv prefix."
  [name]
  (filter |(not (empty? $)) (string/split " " name)))

(defn available?
  "Is the tool invocable? (checks argv[0] on PATH)"
  [name]
  (def head (first (tool-argv name)))
  (and head
       (zero? (os/execute
                ["sh" "-c" (string "command -v '" head "' >/dev/null 2>&1")]
                :p))))

(defn command
  ``The full argv for one run. opts: :tool :url :threads :connections
  :duration (s), :rate (wrk2's fixed RPS; nil for plain wrk),
  :script (lua file for POST bodies).``
  [opts]
  [;(tool-argv (opts :tool))
   "-t" (string (opts :threads))
   "-c" (string (opts :connections))
   "-d" (string (opts :duration) "s")
   "--latency"
   ;(if-let [r (opts :rate)] ["-R" (string r)] [])
   ;(if-let [s (opts :script)] ["-s" s] [])
   (opts :url)])

(defn run
  ``One load-generator run: spawn, capture, parse. Extra env (the lua
  script reads BENCH_BODY_FILE) comes from (opts :env). Throws when
  the tool fails or reports nothing.``
  [opts]
  (def env (merge-into (os/environ) (get opts :env {})))
  (put env :out :pipe)
  (put env :err :pipe)
  (def proc (os/spawn (command opts) :ep env))
  (def out (string (ev/read (proc :out) :all)))
  (def err (string (ev/read (proc :err) :all)))
  (def code (os/proc-wait proc))
  (unless (zero? code)
    (errorf "%s exited %d:\n%s%s" (opts :tool) code out err))
  (def parsed (parse out))
  (when (nil? (parsed :rps))
    (errorf "%s reported no Requests/sec — raw output:\n%s" (opts :tool) out))
  parsed)
