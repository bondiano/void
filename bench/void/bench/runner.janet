### void/bench/runner — one `void bench` invocation (SPEC.md §8.3,
### ADR-0014).
###
### Методика, encoded once: start the target's server as a subprocess,
### wait for the port, warmup, then N timed runs per mode and the
### median of the parsed results. Two modes per target — max
### throughput (wrk) and latency under wrk2's fixed rate; whichever
### tool is missing has its mode skipped with a warning, never faked.
### Results land in results/last.jdn; --record freezes them as the
### baseline, --check compares against it with the 5% thresholds.

(import spork/json)
(import ./targets :as targets)
(import ./wrk :as wrk)
(import ./results :as results)
(import ./pg :as pg)

(def- this-file (dyn *current-file*))

(defn- dirname [p]
  (def idxs (string/find-all "/" p))
  (if (empty? idxs) "." (string/slice p 0 (last idxs))))

(def root
  "The bench-suite root — the directory holding apps/, payloads/,
  loadgen/ and results/ (this module lives in <root>/void/bench/)."
  (os/realpath (string (dirname this-file) "/../..")))

# -- server lifecycle ----------------------------------------------------

(defn- ensure-dir [path]
  (unless (os/stat path)
    (os/mkdir path)))

(defn- log-tail [path &opt lines]
  (default lines 20)
  (def [ok text] (protect (slurp path)))
  (if ok
    (string/join (tuple ;(take (- lines) (string/split "\n" (string text)))) "\n")
    "<no log>"))

(defn start-target
  ``Spawn a target's server: sh -c from the bench root, PORT and
  GOMAXPROCS=1 in the environment, stdout+stderr to
  results/logs/<name>.log. Returns the server handle.``
  [name spec]
  (ensure-dir (string root "/results"))
  (ensure-dir (string root "/results/logs"))
  (def logpath (string root "/results/logs/" name ".log"))
  (def logf (file/open logpath :w))
  (def env (merge-into (os/environ)
                       {"PORT" (string (spec :port))
                        "GOMAXPROCS" "1"
                        # a go.work up the tree must not leak into the
                        # baseline build
                        "GOWORK" "off"}))
  (put env :out logf)
  (put env :err logf)
  (def proc
    (os/spawn ["sh" "-c" (string "cd '" root "' && " (spec :cmd))] :ep env))
  @{:proc proc :name name :port (spec :port) :log logpath :logf logf
    :ready (spec :ready)})

(defn stop-target
  "SIGTERM (graceful drain), SIGKILL after 10s of no exit."
  [server]
  (protect (os/proc-kill (server :proc) false :term))
  (def [ok _] (protect (ev/with-deadline 10 (os/proc-wait (server :proc)))))
  (unless ok
    (protect (os/proc-kill (server :proc)))
    (protect (os/proc-wait (server :proc))))
  (protect (file/close (server :logf)))
  server)

(defn- status-200? [port path]
  (def [ok answered]
    (protect
      (with [conn (net/connect "127.0.0.1" (string port))]
        (:write conn (string "GET " path " HTTP/1.1\r\nHost: bench\r\n"
                             "Connection: close\r\n\r\n"))
        (def buf @"")
        (while (net/read conn 4096 buf 5))
        (string/has-prefix? "HTTP/1.1 200" (string buf)))))
  (and ok answered))

(defn wait-ready
  ``Poll until the target is serving, `timeout` seconds (default 60 —
  `go build` and uvicorn cold starts count): TCP accept, and then, for
  a target carrying `:ready` (see targets/targets), a 200 from that
  path.

  The second half is not belt-and-braces. An app opens its listener in
  `system/start` and does its own setup in `:after-start`, so the port
  answers while B2/B3 are still seeding `bench_rows` — a warmup, or a
  test, arriving in that window measures an empty table. The seeding
  apps report 503 until the table is theirs (see the app sources), and
  this is what waits for it.

  On failure the server is stopped and the log tail lands in the
  error.``
  [server &opt timeout]
  (default timeout 60)
  (def deadline (+ (os/clock) timeout))
  (var up false)
  (while (and (not up) (< (os/clock) deadline))
    (def [ok stream] (protect (net/connect "127.0.0.1" (string (server :port)))))
    (if ok
      (do (:close stream) (set up true))
      (ev/sleep 0.1)))
  (when (and up (server :ready))
    (set up false)
    (while (and (not up) (< (os/clock) deadline))
      (if (status-200? (server :port) (server :ready))
        (set up true)
        (ev/sleep 0.1))))
  (unless up
    (stop-target server)
    (errorf "target %s never became ready on port %d — log tail (%s):\n%s"
            (server :name) (server :port) (server :log)
            (log-tail (server :log))))
  server)

# -- the runtime probe (§8.2 loop-lag / GC budgets) ----------------------
#
# The app under load carries `bench/probe` and answers
# targets/probe-path with the event-loop lag it has been experiencing.
# The window is bracketed around the *fixed-rate* runs only: max
# throughput saturates the loop on purpose, and "loop-lag p99 < 1 ms"
# is a budget about target load (§8.2), not about saturation. An app
# without the probe (VOID_BENCH_PROBE=0, a baseline written in Go)
# answers 404 or nothing, and the runtime budgets go unmeasured rather
# than unmet.

(defn read-probe
  ``GET the probe endpoint on `port`; the decoded stats, or nil when
  the target has no probe. `reset` clears its reservoir after reading,
  which is how a window is opened.``
  [port &opt reset]
  (def [ok body]
    (protect
      (with [conn (net/connect "127.0.0.1" (string port))]
        (:write conn (string "GET " targets/probe-path
                             (if reset "?reset=1" "")
                             " HTTP/1.1\r\nHost: bench\r\n"
                             "Connection: close\r\n\r\n"))
        (def buf @"")
        (while (net/read conn 4096 buf 5))
        (def raw (string buf))
        (def i (string/find "\r\n\r\n" raw))
        (when (and i (string/has-prefix? "HTTP/1.1 200" raw))
          (json/decode (string/slice raw (+ i 4)) true)))))
  (when ok body))

# -- one target ----------------------------------------------------------

(defn- timed-runs [n opts]
  (seq [i :range [0 n]]
    (printf "    run %d/%d (%ds)..." (inc i) n (opts :duration))
    (wrk/run opts)))

(defn run-target
  ``The full методика for one target: spawn → ready → warmup → runs ×
  duration per available mode → medians. `tools` is
  {:wrk <cmd-or-nil> :wrk2 <cmd-or-nil>}. Returns the result row.``
  [name spec settings tools]
  (def bench (targets/benches (spec :bench)))
  (def base-opts
    @{:url (string "http://127.0.0.1:" (spec :port) (bench :path))
      :threads (bench :threads)
      :connections (bench :connections)
      :script (when-let [s (bench :script)] (string root "/" s))
      :env (if-let [bf (bench :body-file)]
             {"BENCH_BODY_FILE" (string root "/" bf)}
             {})})
  (def server (wait-ready (start-target name spec)))
  (defer (stop-target server)
    (def row @{:bench (spec :bench)})
    (def warm-tool (or (tools :wrk) (tools :wrk2)))
    (when (and warm-tool (pos? (settings :warmup)))
      (printf "    warmup (%ds)..." (settings :warmup))
      (wrk/run (merge base-opts
                      {:tool warm-tool
                       :duration (settings :warmup)
                       :rate (when (= warm-tool (tools :wrk2)) (bench :rate))})))
    (when-let [tool (tools :wrk)]
      (printf "  max throughput (wrk):")
      (put row :throughput
           (wrk/summarize
             (timed-runs (settings :runs)
                         (merge base-opts {:tool tool
                                           :duration (settings :duration)})))))
    (when-let [tool (tools :wrk2)]
      (printf "  latency @ %d rps (wrk2):" (bench :rate))
      # open the runtime window on the fixed-rate runs and nothing else
      (def probed (read-probe (spec :port) true))
      (put row :latency
           (merge (wrk/summarize
                    (timed-runs (settings :runs)
                                (merge base-opts {:tool tool
                                                  :duration (settings :duration)
                                                  :rate (bench :rate)})))
                  {:rate (bench :rate)}))
      (when probed
        (when-let [after (read-probe (spec :port))]
          (put row :runtime after))))
    row))

# -- report --------------------------------------------------------------

(defn- fmt-ms [v] (if (number? v) (string/format "%.2fms" v) "—"))
(defn- fmt-rps [v] (if (number? v) (string/format "%.0f" v) "—"))

(defn print-report
  "The result table plus §8.2 budget notes for the budgeted targets."
  [res]
  (def env (res :env))
  (def s (res :settings))
  (print)
  (printf "void bench — warmup %ds, %d×%ds per mode, medians"
          (s :warmup) (s :runs) (s :duration))
  (printf "  janet %s · %s · %s · commit %s%s"
          (get env :janet "?") (get env :cpu (get env :uname "?"))
          (get env :os "?") (get env :commit "?")
          (if-let [g (env :governor)] (string " · governor " g) ""))
  (print)
  (printf "%-18s %-10s %-16s %10s %10s %10s"
          "target" "bench" "mode" "rps" "p50" "p99")
  (each tname (filter |(get-in res [:rows $]) targets/order)
    (def row (get-in res [:rows tname]))
    (when-let [t (row :throughput)]
      (printf "%-18s %-10s %-16s %10s %10s %10s"
              tname (row :bench) "throughput"
              (fmt-rps (t :rps)) (fmt-ms (t :p50)) (fmt-ms (t :p99))))
    (when-let [l (row :latency)]
      (printf "%-18s %-10s %-16s %10s %10s %10s"
              tname (row :bench) (string "latency@" (l :rate))
              "" (fmt-ms (l :p50)) (fmt-ms (l :p99))))
    (when-let [ll (get-in row [:runtime :loop-lag])]
      (printf "%-18s %-10s %-16s %10s %10s %10s"
              "" "" "loop-lag" ""
              (fmt-ms (ll :p50)) (fmt-ms (ll :p99)))
      (printf "%-18s %-10s %-16s %10s %10s %10s"
              "" "" "  max / rss" ""
              (fmt-ms (ll :max))
              (if-let [r (get-in row [:runtime :rss])]
                (string/format "%.0fMiB" (/ r 1048576))
                "—")))
    (each k [:non-2xx :socket-errors]
      (def n (+ (get-in row [:throughput k] 0) (get-in row [:latency k] 0)))
      (when (pos? n)
        (printf "%-18s !! %d %s" "" n k))))
  (print)
  (each tname (filter |(get-in res [:rows $]) targets/order)
    (when-let [bkey (get-in targets/targets [tname :budget])]
      (printf "budget %s (§8.2, docs/BENCH-v0.1.md):" tname)
      (each [status text] (results/budget-notes (get-in res [:rows tname])
                                                (targets/budgets bkey))
        (printf "  %s %s"
                (case status :ok "ok  " :miss "MISS" "skip") text)))))

# -- CLI -----------------------------------------------------------------

(def- usage
  ``usage: void bench [TARGETS|all|baselines] [flags]
       void bench compare BASE.jdn CURRENT.jdn [--threshold PCT]
       void bench budgets [FILE]   # §8.2 check of a saved result set
                                   # (default results/baseline.jdn)
       void bench list

flags:
  --quick          smoke profile: warmup 3s, 2×5s (CI shared runners)
  --runs N         timed runs per mode (default 3)
  --duration S     seconds per run (default 60)
  --warmup S       warmup seconds (default 30)
  --out FILE       also write the result set to FILE
  --record         freeze this run as results/baseline.jdn
  --check          compare against the recorded baseline, exit 1 on
                   any >5% regression
  --against FILE   baseline file for --check
  --threshold PCT  allowed degradation percent (default 5)
  --budgets        also enforce the absolute §8.2 budgets on this run,
                   exit 1 on any MISS or unmeasured budget
                   (docs/BENCH-v0.1.md: reference-environment check,
                   not for shared CI runners)

tools: wrk (max throughput) and wrk2 (latency under fixed rate) on
PATH; override with VOID_BENCH_WRK / VOID_BENCH_WRK2.``)

(def- value-flags
  {"--runs" :runs "--duration" :duration "--warmup" :warmup
   "--out" :out "--against" :against "--threshold" :threshold})

(def- bool-flags
  {"--quick" :quick "--record" :record "--check" :check "--help" :help
   "--budgets" :budgets})

(defn- parse-args [args]
  (def flags @{})
  (def words @[])
  (var i 0)
  (while (< i (length args))
    (def a (in args i))
    (cond
      (in bool-flags a)
      (do (put flags (bool-flags a) true) (++ i))

      (in value-flags a)
      (do
        (when (>= (inc i) (length args))
          (errorf "%s expects a value" a))
        (put flags (value-flags a) (in args (inc i)))
        (+= i 2))

      (string/has-prefix? "--" a)
      (errorf "unknown flag %q\n%s" a usage)

      (do (array/push words a) (++ i))))
  [words flags])

(defn- num-flag [flags k dflt]
  (if-let [v (flags k)]
    (or (scan-number v) (errorf "--%s expects a number, got %q" k v))
    dflt))

(defn- resolve-targets [words]
  (def out @[])
  (each w words
    (case w
      "all" (array/concat out targets/order)
      "baselines" (array/concat out targets/baseline-targets)
      (do
        (def k (keyword w))
        (unless (in targets/targets k)
          (errorf "unknown target %q — available: %s all baselines"
                  w (string/join (map string targets/order) " ")))
        (array/push out k))))
  (distinct (if (empty? out) targets/default-targets out)))

(defn- detect-tools []
  (def wrk-cmd (or (os/getenv "VOID_BENCH_WRK") "wrk"))
  (def wrk2-cmd (or (os/getenv "VOID_BENCH_WRK2") "wrk2"))
  (def tools
    @{:wrk (when (wrk/available? wrk-cmd) wrk-cmd)
      :wrk2 (when (wrk/available? wrk2-cmd) wrk2-cmd)})
  (when (and (nil? (tools :wrk)) (nil? (tools :wrk2)))
    (errorf "neither %q nor %q found — install wrk/wrk2 or build the container: docker build -t void-bench-loadgen %s/loadgen"
            wrk-cmd wrk2-cmd root))
  (when (nil? (tools :wrk2))
    (printf "!! %q not found — latency-under-rate runs skipped (wrk's latency is CO-biased; see loadgen/Dockerfile)" wrk2-cmd))
  (when (nil? (tools :wrk))
    (printf "!! %q not found — max-throughput runs skipped" wrk-cmd))
  tools)

(defn- threshold [flags]
  (/ (num-flag flags :threshold (* 100 results/default-threshold)) 100))

(defn enforce-budgets
  ``The absolute §8.2 gate: every budgeted target present in `res`
  must measure and meet its budget — a MISS or an unmeasured budget
  (no wrk2, target not run) throws. Meant for the reference
  environment (docs/BENCH-v0.1.md), not for shared CI runners.``
  [res]
  (def failures @[])
  (each tname (filter |(get-in targets/targets [$ :budget]) targets/order)
    (def row (get-in res [:rows tname]))
    (if (nil? row)
      (array/push failures
                  (string/format "%s: not in this result set%s" tname
                                 (if (get-in targets/targets [tname :needs-pg])
                                   " (a database target — VOID_BENCH_PG)"
                                   "")))
      (each [status text] (results/budget-notes
                            row
                            (targets/budgets (get-in targets/targets [tname :budget])))
        (unless (= :ok status)
          (array/push failures (string/format "%s: %s" tname text))))))
  (if (empty? failures)
    (print "budgets §8.2: all met")
    (errorf "§8.2 budget check failed:\n  - %s"
            (string/join failures "\n  - "))))

(defn- check-against [basefile current thr]
  (printf "check against %s (threshold %.0f%%):" basefile (* 100 thr))
  (def cmp (results/print-comparison
             (results/compare-results (results/read-file basefile) current thr)))
  (unless (empty? (cmp :regressions))
    (errorf "%d regression(s) over the %.0f%% threshold"
            (length (cmp :regressions)) (* 100 thr))))

(defn- print-targets []
  (each tname targets/order
    (def spec (targets/targets tname))
    (printf "  %-18s %s%s" tname (spec :doc)
            (if (spec :baseline) " [baseline]" ""))))

(defn run-cli
  ``Entry point for `void bench` and `janet bench/main.janet` — raw
  string arguments in, throws on any failure (regressions included);
  the CLI turns that into exit code 1.``
  [args]
  (def [words flags] (parse-args args))
  (cond
    (flags :help) (print usage)

    (= (first words) "list") (print-targets)

    (= (first words) "compare")
    (do
      (unless (= 3 (length words))
        (errorf "usage: void bench compare BASE.jdn CURRENT.jdn"))
      (check-against (in words 1)
                     (results/read-file (in words 2))
                     (threshold flags)))

    (= (first words) "budgets")
    (do
      (unless (<= (length words) 2)
        (errorf "usage: void bench budgets [FILE]"))
      (def file (get words 1 (string root "/results/baseline.jdn")))
      (printf "budgets §8.2 check of %s:" file)
      (enforce-budgets (results/read-file file)))

    (do
      (def tnames (resolve-targets words))
      (def settings
        {:runs (math/floor (num-flag flags :runs (if (flags :quick) 2 3)))
         :duration (math/floor (num-flag flags :duration (if (flags :quick) 5 60)))
         :warmup (math/floor (num-flag flags :warmup (if (flags :quick) 3 30)))})
      (def tools (detect-tools))
      (def rows @{})
      (each tname tnames
        (def spec (targets/targets tname))
        (if (and (spec :needs-pg) (not (pg/available?)))
          # loudly, and without failing: a laptop with no server still
          # gets B0/B1, and a benchmark that quietly measures nothing
          # is worse than one that says it did not run
          (printf "!! %s skipped — no Postgres configured (set %s or %s)"
                  tname pg/env-var pg/fallback-env-var)
          (do
            (printf "· %s — %s" tname (spec :doc))
            (put rows tname (run-target tname spec settings tools)))))
      (def res {:env (results/environment) :settings settings :rows rows})
      (print-report res)
      (results/write-file (string root "/results/last.jdn") res)
      (printf "results → results/last.jdn")
      (when-let [f (flags :out)]
        (results/write-file f res)
        (printf "results → %s" f))
      (when (flags :record)
        (results/write-file (string root "/results/baseline.jdn") res)
        (printf "baseline recorded → results/baseline.jdn"))
      (when (flags :check)
        (check-against (or (flags :against)
                           (string root "/results/baseline.jdn"))
                       res (threshold flags)))
      (when (flags :budgets)
        (enforce-budgets res)))))
