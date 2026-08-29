### void/bench/ws — driving the B4 load generator and reading its
### output (SPEC §8.3, ADR-0014, ROADMAP 4.2).
###
### What ./wrk is to B0–B3, this is to B4. The difference is that the
### generator is ours (loadgen/ws-broadcast.janet — wrk speaks HTTP and
### B4 is a fan-out measured at the receiving end), so there is no
### output format to reverse-engineer: it prints one line of JSON after
### a marker, and this parses it.
###
### There is only one mode. B0–B3 have two — max throughput and latency
### under a fixed rate — because a request benchmark can be run either
### open or closed. B4 is already a fixed-rate benchmark by
### construction: the server broadcasts at its configured rate, and
### what is measured is how long the message takes to arrive. Running
### it "at max throughput" would mean broadcasting as fast as the loop
### allows, and the delivery time of a saturated fan-out is the same
### meaningless number as the latency of a saturated server (§8.3).

(import spork/json)

(def marker
  "What the generator prints its report behind."
  "BENCH-WS ")

(defn parse
  "One generator stdout -> its report table. Throws when there is no
  report in it, quoting what there was instead."
  [out]
  (def line
    (find |(string/has-prefix? marker $) (string/split "\n" out)))
  (unless line
    (errorf "the websocket generator printed no %sreport — raw output:\n%s"
            marker out))
  (json/decode (string/slice line (length marker)) true))

(defn summarize
  ``Fold the generator's report into a result row of the shape the rest
  of the suite uses: `:rps` is messages *delivered* per second (§8.2's
  10k msg/s is a fan-out number, not a broadcast rate) and the
  delivery percentiles are milliseconds.``
  [report]
  (def d (get report :delivery {}))
  (def row
    @{:connections (report :connections)
      :requested (report :requested)
      :messages (report :messages)
      :rps (report :rps)
      :duration (report :duration)})
  (each k [:p50 :p90 :p99 :p999 :max :mean]
    (when (number? (get d k)) (put row k (get d k))))
  (each k [:errors :closed :undecodable]
    (when (pos? (get report k 0)) (put row k (get report k))))
  row)

(defn command
  ``The argv for one run. opts: :janet (interpreter), :script (the
  generator), :url :connections :duration :warmup.``
  [opts]
  [(get opts :janet (dyn *executable* "janet"))
   (opts :script)
   "--url" (opts :url)
   "--connections" (string (opts :connections))
   "--duration" (string (opts :duration))
   "--warmup" (string (opts :warmup))])

(defn run
  "One generator run: spawn, capture, parse. Throws when it fails."
  [opts]
  (def env (merge-into (os/environ) (get opts :env {})))
  (put env :out :pipe)
  (put env :err :pipe)
  (def proc (os/spawn (command opts) :ep env))
  (def out (string (ev/read (proc :out) :all)))
  (def err (string (ev/read (proc :err) :all)))
  (def code (os/proc-wait proc))
  (unless (zero? code)
    (errorf "the websocket generator exited %d:\n%s%s" code out err))
  (def report (parse out))
  (when (< (report :connections) (report :requested))
    (printf "!! only %d of %d connections were opened — check ulimit -n"
            (report :connections) (report :requested)))
  report)
