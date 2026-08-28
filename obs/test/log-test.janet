# What obs adds to the logger: counting by level, sampling that keeps a
# sampled trace whole, and a file sink that drops rather than block.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/obs/metrics :as metrics)
(import void/obs/trace :as trace)
(import void/obs/log :as obslog)

(log/set-level! nil :trace)

(defn- rec [level &opt msg]
  @{:ts (os/clock :realtime) :level level :ns "test" :msg (or msg "m")})

# -- the counting sink ---------------------------------------------------

(metrics/reset! :void.obs/log-records-total)
(def count! (obslog/counting-sink))
(count! (rec :info))
(count! (rec :info))
(count! (rec :error))
(assert (= 2 (metrics/value obslog/records [:info])))
(assert (= 1 (metrics/value obslog/records [:error]))
        "an error rate an alert can be built on without parsing a line")

# -- the sampling decision -----------------------------------------------

(def warn-floor (get log/levels :warn))

(assert (obslog/keep? (rec :error) 0 warn-floor)
        "a warning is not a sample — everything at or above the floor is kept whatever the rate")
(assert (obslog/keep? (rec :fatal) 0 warn-floor))
(assert (not (obslog/keep? (rec :info) 0 warn-floor))
        "and below it, a rate of 0 keeps nothing")
(assert (obslog/keep? (rec :info) 1 warn-floor))

(trace/with-span "sampled" {:parent nil :sampled true}
  (assert (obslog/keep? (rec :debug) 0 warn-floor)
          "a record inside a sampled span is kept at any rate: a trace that is being exported must not be half-logged"))
(trace/with-span "unsampled" {:parent nil :sampled false}
  (assert (not (obslog/keep? (rec :debug) 0 warn-floor))
          "and one inside an unsampled span is a record like any other"))

# -- the gate ------------------------------------------------------------

(def seen @[])
(log/set-sinks! [(fn [r] (array/push seen (r :msg)))])
(metrics/reset! :void.obs/log-sampled-out-total)

(obslog/install-sampling! 0 :warn)
(log/info "dropped" :ns "test")
(log/warn "kept" :ns "test")
(assert (and (= 1 (length seen)) (= "kept" (string (first seen))))
        "the gate sits in front of every sink at once")
(assert (= 1 (metrics/value obslog/sampled-out)) "and counts what it dropped")

(obslog/install-sampling! 1 :warn)
(array/clear seen)
(log/info "back" :ns "test")
(assert (and (= 1 (length seen)) (= "back" (string (first seen))))
        "a rate of 1 removes the gate rather than installing one that keeps everything")

(obslog/install-sampling! 0 :warn)
(obslog/install-sampling! 0 :warn)
(obslog/install-sampling! 1 :warn)
(array/clear seen)
(log/info "once" :ns "test")
(assert (= 1 (length seen)) "re-applying does not nest gates — the record is written once")

# a second boot in one process: log/configure! replaces the whole sink
# list (ADR-0018), and the gate has to start from the new one
(obslog/install-sampling! 0 :warn)
(def fresh @[])
(log/set-sinks! [(fn [r] (array/push fresh (r :msg)))])
(obslog/install-sampling! 0 :warn)
(log/warn "second boot" :ns "test")
(assert (and (= 1 (length fresh)) (= "second boot" (string (first fresh))))
        "the gate wraps the sinks the logger holds now, not the ones a previous boot had")

(log/set-sinks! nil)

# -- the file sink -------------------------------------------------------

(def dir (string (os/getenv "TMPDIR" "/tmp") "obs-log-test-" (os/time)))
(os/mkdir dir)
(def path (string dir "/app.jdn"))

(def sink (obslog/file-sink {:path path :buffer 8}))
((sink :fn) (rec :info "to a file"))
((sink :fn) (rec :fatal "flushed now"))
(ev/sleep 0.02)
(def written (slurp path))
(assert (string/find "to a file" written) "records reach the file from the writer fiber")
(assert (string/find "flushed now" written) ":fatal is written synchronously — the process may not be there for the next take")
(assert (= 2 (length (filter |(not (empty? $)) (string/split "\n" written))))
        "one line per record")
((sink :close!))
(ev/sleep 0.02)

(def jpath (string dir "/app.json"))
(def jsink (obslog/file-sink {:path jpath :format :json}))
((jsink :fn) (rec :info "json line"))
(ev/sleep 0.02)
(def jline (string/trim (slurp jpath)))
(assert (string/has-prefix? "{" jline))
(assert (string/find "\"level\":\"info\"" jline)
        "a keyword is a string in JSON — a record carries janet values and an encoder is entitled to refuse them")
((jsink :close!))
(ev/sleep 0.02)

(def rsink (obslog/file-sink {:path (string dir "/rot.jdn")}))
((rsink :fn) (rec :info "before"))
(ev/sleep 0.02)
(os/rename (string dir "/rot.jdn") (string dir "/rot.jdn.1"))
((rsink :reopen!))
((rsink :fn) (rec :info "after"))
(ev/sleep 0.02)
(assert (string/find "before" (slurp (string dir "/rot.jdn.1"))))
(assert (string/find "after" (slurp (string dir "/rot.jdn")))
        "reopen! is the answer to a rotation that moved the file out from under the process")
((rsink :close!))
(ev/sleep 0.02)

(each f (os/dir dir) (os/rm (string dir "/" f)))
(os/rmdir dir)

# -- jsonable ------------------------------------------------------------

(assert (= "info" (obslog/jsonable :info)))
(assert (deep= @{"a" @["b" 1]} (obslog/jsonable {:a [:b 1]})))
(assert (string? (obslog/jsonable (fn [] 1)))
        "and anything a JSON encoder would refuse becomes its printed form, so a log line never throws in the writer")

(print "log-test ok")
