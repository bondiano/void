### The B4 load generator (SPEC §8.2, ROADMAP 4.2).
###
### wrk and wrk2 speak HTTP, and B4 is not an HTTP benchmark: it is a
### fan-out, measured from the receiving end. So this is the generator
### for it — N websocket connections in one Janet process, each with a
### fiber reading its own socket, and one number per message: the
### monotonic clock at delivery minus the one the server framed into
### the payload.
###
###     janet loadgen/ws-broadcast.janet --url ws://127.0.0.1:8104/ws \
###       --connections 1000 --duration 30 --warmup 3
###
### It prints one line of JSON after a `BENCH-WS ` marker, which is
### what void/bench/ws parses. Everything else it prints is progress.
###
### **Two honesty notes, because a load generator that flatters itself
### is worse than none.**
###
###   * The clock is shared, not compared. `os/clock :monotonic` is
###     CLOCK_MONOTONIC, which counts from the machine's boot and is
###     the same reading in both processes — so the subtraction is
###     valid without a handshake, and would not be across a network.
###   * The number includes this process. A thousand fibers waking on
###     10k messages a second is work, and its own scheduling delay is
###     inside every sample. The measurement is therefore an upper
###     bound on delivery, and the server's own loop lag (the runner
###     reads it from `bench/probe`) is what says whose delay it was.
###     A generator on the same core as the server is measuring both.

# The module path is a projection of the package graph (ADR-0020), the
# way every other entry point in the repository builds it.
(import ../../scripts/packages :as packages)
(packages/add-paths [:void/ws])

(import spork/json)
(import void/ws/client :as wsc)

(def usage
  ``usage: janet loadgen/ws-broadcast.janet [flags]

  --url URL          websocket to open (default ws://127.0.0.1:8104/ws)
  --connections N    connections to hold open (default 1000)
  --duration S       measured seconds (default 30)
  --warmup S         seconds to discard before measuring (default 3)
  --report FILE      also write the JSON report to a file``)

(def defaults
  {:url "ws://127.0.0.1:8104/ws"
   :connections 1000
   :duration 30
   :warmup 3})

(defn parse-args [args]
  (def out (merge @{} defaults))
  (var i 0)
  (while (< i (length args))
    (def a (in args i))
    (def key (case a
               "--url" :url
               "--connections" :connections
               "--duration" :duration
               "--warmup" :warmup
               "--report" :report
               "--help" :help
               (errorf "unknown flag %q\n%s" a usage)))
    (if (= :help key)
      (do (put out :help true) (++ i))
      (do
        (when (>= (inc i) (length args)) (errorf "%s expects a value" a))
        (def raw (in args (inc i)))
        (put out key (if (or (= key :url) (= key :report)) raw
                       (or (scan-number raw)
                           (errorf "%s expects a number, got %q" a raw))))
        (+= i 2))))
  out)

# -- percentiles ---------------------------------------------------------

(defn percentile
  "The p-th percentile of a *sorted* array of numbers, in milliseconds."
  [sorted-values p]
  (def n (length sorted-values))
  (when (pos? n)
    (def idx (min (dec n) (math/floor (* (/ p 100) n))))
    (in sorted-values idx)))

(defn summarize
  "Latency samples (seconds) -> the report's delivery block, in ms."
  [samples]
  (def ms (sorted (map |(* 1000 $) samples)))
  (if (empty? ms)
    {:samples 0}
    {:samples (length ms)
     :p50 (percentile ms 50)
     :p90 (percentile ms 90)
     :p99 (percentile ms 99)
     :p999 (percentile ms 99.9)
     :max (last ms)
     :mean (/ (sum ms) (length ms))}))

# -- one connection ------------------------------------------------------

(defn- reader
  ``One connection's fiber: read forever, and while `state :measuring`
  is on, record the delivery delay of each message.``
  [client state]
  (var running true)
  (while (and running (state :running))
    (def [ok msg] (protect (wsc/receive client 5)))
    (cond
      (not ok) (do (put state :errors (inc (state :errors))) (set running false))
      (nil? msg) (set running false)
      (= :close (msg :type)) (do (put state :closed (inc (state :closed)))
                                 (set running false))
      (do
        (def now (os/clock :monotonic))
        (put state :received (inc (state :received)))
        (when (state :measuring)
          (def [pok value] (protect (json/decode (msg :data) true)))
          (if (and pok (number? (get value :t)))
            (array/push (state :samples) (- now (value :t)))
            (put state :undecodable (inc (state :undecodable))))))))
  (protect (wsc/close! client :going-away nil 0.2)))

# -- the run -------------------------------------------------------------

(defn run [opts]
  (def state @{:running true :measuring false
               :received 0 :errors 0 :closed 0 :undecodable 0
               :samples @[]})
  (def clients @[])
  (def wanted (opts :connections))
  (eprintf "opening %d connections to %s ..." wanted (opts :url))
  (var refused nil)
  (for i 0 wanted
    (def [ok client] (protect (wsc/connect (opts :url) {:timeout 30})))
    (if ok
      (do
        (array/push clients client)
        (ev/go (fn conn-reader [] (reader client state))))
      (do (set refused (string client)) (break))))
  (when (empty? clients)
    (errorf "could not open a single connection to %s: %s" (opts :url) refused))
  (when (< (length clients) wanted)
    (eprintf (string "!! only %d of %d connections opened (%s) — a benchmark of "
                     "1k connections needs a file-descriptor limit above it "
                     "(ulimit -n)")
             (length clients) wanted refused))

  (eprintf "warmup %ds ..." (opts :warmup))
  (ev/sleep (opts :warmup))
  (put state :measuring true)
  (def started (os/clock :monotonic))
  (eprintf "measuring %ds ..." (opts :duration))
  (ev/sleep (opts :duration))
  (put state :measuring false)
  (def elapsed (- (os/clock :monotonic) started))
  (put state :running false)

  (def delivery (summarize (state :samples)))
  (def report
    {:connections (length clients)
     :requested wanted
     :duration elapsed
     :messages (delivery :samples)
     # what §8.2 budgets as "10k msg/s": messages *delivered* to peers
     # per second, which is the fan-out and not the broadcast rate
     :rps (if (pos? elapsed) (/ (delivery :samples) elapsed) 0)
     :delivery delivery
     :errors (state :errors)
     :closed (state :closed)
     :undecodable (state :undecodable)})

  (each c clients (protect (wsc/close! c :going-away nil 0.05)))
  report)

(defn main [& args]
  (def opts (parse-args (tuple ;(drop 1 args))))
  (when (opts :help)
    (print usage)
    (os/exit 0))
  (def [ok report] (protect (run opts)))
  (unless ok
    (eprintf "ws-broadcast: %s" (if (string? report) report (describe report)))
    (os/exit 1))
  (when-let [path (opts :report)]
    (spit path (json/encode report)))
  (printf "BENCH-WS %s" (json/encode report)))
