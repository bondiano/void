### void/obs/log — what obs adds to the logger (SPEC.md §3.7 and
### §5.13, ADR-0018, ROADMAP 3.1).
###
### The logger itself is core and has been since wave 1: records are
### plain tables, levels are a per-namespace tree, the context is a
### dyn, and sinks are an extension point. obs adds the three things
### that only make sense once there is a trace and a scraper:
###
###   correlation  every record emitted inside a span carries
###                `:trace-id` and `:span-id`. There is no code for it
###                *here* — `trace/with-span` binds them into the log
###                context (`log/with-context`), which is exactly the
###                seam ADR-0018 left for this. What this module adds
###                is the *use*: a sampling decision that keeps a
###                sampled trace's records whole.
###   sampling     a rate below a severity floor. A service at ten
###                thousand requests a second cannot pay for ten
###                thousand access-log lines a second, and the usual
###                answer — raise the level — throws away the record
###                you needed and the one before it. Sampling keeps a
###                *representative* share, keeps every warning and
###                error unconditionally, and keeps everything
###                belonging to a sampled trace, so a trace that is
###                being exported is never half-logged.
###   file sinks   records to a file, from a writer fiber behind a
###                buffered channel, dropping (and counting) rather
###                than back-pressuring a request fiber — the jdn-sink
###                bargain of ADR-0018, pointed at a path. Rotation is
###                the deployment's (logrotate + copytruncate, or
###                `reopen!` after a move); a log writer that renames
###                its own files is a second, worse cron.
###
### **The OTLP log sink is wave 4, not a gap here.** OTLP/HTTP needs an
### HTTP *client*, and void has none until void/proto (ROADMAP 4.1) —
### the same reason the OTLP span exporter waits. Every log line that
### reaches a file here reaches a collector through the agent that is
### already reading it (vector, fluent-bit, promtail), which is how
### most deployments would ship it anyway.
###
### **Sampling replaces the sink list rather than adding to it.**
### Contributed sinks are *additive* (plugin/start! appends them), and
### a decision to drop a record has to gate every sink at once or the
### file and the console disagree about what happened. So obs wraps
### the whole list in one gate, keeps the originals, and rebuilding is
### idempotent — a re-configure from the REPL does not nest gates.

(import spork/json)
(import void/core/log :as log)
(import ./metrics :as metrics)
(import ./trace :as trace)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.obs.log")

# -- the numbers ---------------------------------------------------------

(def records
  "Records emitted, by level — the cheapest error-rate signal a
  service has, and one an alert can be built on without parsing a
  single line."
  (metrics/counter :void.obs/log-records-total
    {:doc "Log records emitted, by level"
     :labels [:level]}))

(def sampled-out
  "Records dropped by log sampling — the denominator that keeps
  'quiet' and 'sampled' apart."
  (metrics/counter :void.obs/log-sampled-out-total
    {:doc "Log records dropped by obs log sampling"}))

(def file-dropped
  "Records a full file-sink buffer dropped (ADR-0018's bargain: logs
  never take the service down, and every loss is counted)."
  (metrics/counter :void.obs/log-file-dropped-total
    {:doc "Log records dropped by a full file-sink buffer"}))

(def file-written
  "Records written to a file sink."
  (metrics/counter :void.obs/log-file-records-total
    {:doc "Log records written to a file sink"}))

# -- counting sink -------------------------------------------------------

(defn counting-sink
  ``A sink that writes nothing and counts everything: one table lookup
  and an increment per record, which is what makes
  `void_obs_log_records_total{level="error"}` an alert nobody has to
  grep for. The level goes in as the keyword it is — the exposition
  turns label values into text at scrape time, and a string built per
  record is a string built per request.``
  []
  (fn obs-count [rec]
    (metrics/inc! records [(rec :level)])
    nil))

# -- sampling ------------------------------------------------------------

(def default-min-level
  ``The severity at and above which sampling never applies. A dropped
  warning is a defect report nobody filed; the volume that makes
  sampling necessary is :info and below.``
  :warn)

(defn keep?
  ``Does this record survive sampling? Three rules, in order:

    1. at or above `min-level` — always (a warning is not a sample);
    2. inside a sampled span — always, so a trace that is being
       exported carries its own log lines rather than every tenth of
       them;
    3. otherwise the rate decides.``
  [rec rate floor]
  (or (>= (get log/levels (rec :level) 30) floor)
      (if-let [span (trace/current)] (truthy? (span :sampled)) false)
      (< (math/random) rate)))

(var- unsampled-sinks
  "The sink list as it was before the gate went on — what a rebuild
  starts from, so re-applying never nests gates."
  nil)

(var- installed-gate
  ``The gate function currently in the sink list, if it is still
  there. `log/configure!` replaces the whole list on every boot
  (ADR-0018), so "what was under the gate" is only meaningful while
  the gate is what the logger holds — a second boot in one process
  (a test suite, a REPL) starts from the new list, not from the one
  the previous boot wrapped.``
  nil)

(defn gate
  "One sink that runs `sinks` only for the records sampling keeps."
  [sinks rate min-level]
  (fn obs-log-gate [rec]
    (if (keep? rec rate min-level)
      (each s sinks (protect (s rec)))
      (metrics/inc! sampled-out))
    nil))

(defn install-sampling!
  ``Gate every active sink behind the sampling decision. `rate` of 1
  (or nil) removes the gate instead of installing a gate that keeps
  everything — a service that samples nothing should pay nothing.``
  [rate &opt min-level]
  (default min-level default-min-level)
  (def floor (or (get log/levels min-level)
                 (errorf "unknown log level %q (levels: :trace :debug :info :warn :error :fatal)"
                         min-level)))
  (def current (log/sinks))
  (def base
    (if (and installed-gate
             (= 1 (length current))
             (= installed-gate (first current)))
      unsampled-sinks
      (tuple ;current)))
  (set unsampled-sinks base)
  (if (or (nil? rate) (>= rate 1))
    (do (log/set-sinks! base)
        (set unsampled-sinks nil)
        (set installed-gate nil))
    (let [g (gate base rate floor)]
      (set installed-gate g)
      (log/set-sinks! [g])))
  (log/sinks))

# -- the file sink -------------------------------------------------------

(defn jsonable
  ``A value as JSON-encodable data: keywords and symbols become
  strings, dictionaries and arrays are converted through, and
  anything else is printed the way `%q` would. Records carry janet
  values (a level keyword, a route name, an error struct) and a JSON
  encoder is entitled to refuse them; a log line that throws in the
  writer fiber is a log line nobody sees.``
  [v]
  (cond
    (or (keyword? v) (symbol? v)) (string v)
    (buffer? v) (string v)
    (or (string? v) (number? v) (boolean? v) (nil? v)) v
    (dictionary? v) (tabseq [[k x] :pairs v] (string k) (jsonable x))
    (indexed? v) (map jsonable v)
    (string/format "%q" v)))

(defn format-record
  "One record as a line, without the newline: JDN (`%j`, what the core
  jdn-sink writes) or JSON."
  [rec format]
  (case format
    :json (json/encode (jsonable rec))
    (string/format "%j" rec)))

(defn file-sink
  ``A sink writing one line per record to `:path`, from its own fiber
  behind a buffered channel (ADR-0018): a full buffer drops the record
  and counts it instead of back-pressuring the request fiber that
  logged it, and `:fatal` is written synchronously because the process
  may not be there for the next take.

  Options: `:path` (required), `:format` :jdn (default) or :json,
  `:buffer` (records, default 1024).

  Returns {:fn <sink> :close! :reopen! :path}: `close!` drains and
  closes (the component's :stop), `reopen!` closes and opens the same
  path again — the answer to a rotation that moved the file out from
  under the process.``
  [opts]
  (def path (or (get opts :path) (error "file-sink: :path is required")))
  (def format (get opts :format :jdn))
  (def cap (get opts :buffer 1024))
  (def chan (ev/chan cap))
  (def state @{:file nil})
  (defn open! []
    (put state :file
         (or (file/open path :a)
             (errorf "file-sink: cannot open %s for appending" path))))
  (open!)
  (defn write! [line]
    (when-let [f (state :file)]
      (protect (file/write f line))
      (protect (file/flush f))
      (metrics/inc! file-written)))
  (ev/go
    (fn obs-log-file-writer []
      (def acc @"")
      (var run true)
      (while run
        (def rec (ev/take chan))
        (if (or (nil? rec) (= :void.obs.log/close rec))
          (set run false)
          (do
            # batch whatever queued into one write — fewer syscalls
            # under load, still one line per record on disk
            (buffer/push-string acc (format-record rec format))
            (buffer/push-string acc "\n")
            (while (and run (pos? (ev/count chan)) (< (length acc) 65536))
              (def more (ev/take chan))
              (if (or (nil? more) (= :void.obs.log/close more))
                (set run false)
                (do (buffer/push-string acc (format-record more format))
                    (buffer/push-string acc "\n"))))
            (write! acc)
            (buffer/clear acc))))
      (when-let [f (state :file)]
        (put state :file nil)
        (protect (file/close f)))))
  @{:path path
    :format format
    :fn (fn obs-log-file [rec]
          (if (= :fatal (rec :level))
            (write! (string (format-record rec format) "\n"))
            (if (ev/full chan)
              (metrics/inc! file-dropped)
              (ev/give chan rec)))
          nil)
    :close! (fn close-file-sink []
              (protect (ev/give chan :void.obs.log/close))
              nil)
    :reopen! (fn reopen-file-sink []
               (when-let [f (state :file)]
                 (put state :file nil)
                 (protect (file/close f)))
               (open!)
               path)})
