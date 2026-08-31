# The event machinery without a broker: produceva writes a real vu
# array, the pump serves a real queue through a real pipe and
# void/fdwait, and the delivery report arrives — saying failed,
# because there is nobody on the port. That a *failure* exercises the
# whole path is the point: message.timeout.ms guarantees the report
# comes, one way or the other (ADR-0035), and this suite holds it to
# that.
#
# Needs librdkafka on the machine (brew install librdkafka / apt
# install librdkafka1) but no cluster; skips, announcing itself, when
# the library is not there.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/kafka/config :as config)
(import void/kafka/librdkafka :as rk)
(import void/kafka/producer :as producer)

(log/set-level! "void.kafka" :fatal)

(def [have _] (protect (rk/load!)))
(unless have
  (print "driver-test: SKIPPED (no librdkafka on this machine — brew install librdkafka)")
  (os/exit 0))

(printf "librdkafka %s (%s)" (rk/version) rk/library-path)

# nobody listens here; the port is reserved for documentation
(def cfg {:brokers "127.0.0.1:19099" :message-timeout 2})

(def p (producer/make
         (config/properties cfg {} {"message.timeout.ms" (config/message-timeout-ms cfg)})
         {:timeout 2}))

# -- the loop lives while a fiber waits for its report -------------------
#
# The ADR-0033 ticker proof, pointed at ADR-0035's machinery: while
# produce! is parked on its delivery report, a 20 ms ticker must keep
# ticking — the fiber is parked, not the loop blocked.

(var ticks 0)
(var ticking true)
(ev/spawn
  (while ticking
    (ev/sleep 0.02)
    (++ ticks)))

(def before (os/clock :monotonic))
(def [ok err]
  (protect (producer/produce! p {:topic "smoke.test" :value "hello"
                                 :key "k" :headers {"void-id" "abc" "void-meta" "{}"}})))
(def took (- (os/clock :monotonic) before))
(set ticking false)

(assert (not ok) "delivery must fail without a broker")
(assert (string/find "delivery to \"smoke.test\" failed" (string err))
        "at the call site, naming the topic")
(assert (>= took 1.5)
        "after the library waited message.timeout.ms out — the report came, it was not invented")
(assert (< took 10) "and not the library's five-minute default")
(assert (> ticks 40)
        (string/format "the ev loop ran while the fiber waited (%d ticks of 20 ms in %.1f s) — parked, not blocked"
                       ticks took))

# -- fire-and-forget is a counter, not an error --------------------------

(producer/produce! p {:topic "smoke.test" :value "bye" :wait? false})
(def s (producer/stats p))
(assert (= 2 (s :produced)) "both messages were handed over")
(assert (zero? (s :waiting)) "and nobody is left parked")

# -- two confirmed produces wait together, not in line -------------------
#
# Both reports take ~2 s of message timeout; two fibers parked on the
# same producer must serve them concurrently — the second failing at
# ~2 s too, not at ~4.

(def t0 (os/clock :monotonic))
(def done (ev/chan 2))
(each n [1 2]
  (ev/spawn
    (def [_ _] (protect (producer/produce! p {:topic "smoke.test" :value (string n)})))
    (ev/give done (- (os/clock :monotonic) t0))))
(def d1 (ev/take done))
(def d2 (ev/take done))
(assert (< (max d1 d2) 3.5)
        (string/format "two 2 s waits overlap (%.1f / %.1f s), the ADR-0033 shape of the same proof" d1 d2))

# -- the boot probe fails the way a boot wants ---------------------------

(import void/kafka/client :as client)
(def [probed perr] (protect (client/probe! (p :client) "127.0.0.1:19099" 1)))
(if rk/rd_kafka_DescribeCluster
  (do
    (assert (not probed) "no cluster, no boot")
    (assert (string/find "127.0.0.1:19099" (string perr))
            "and the error names where it looked"))
  (assert (and probed (= :skipped perr))
          "an older librdkafka skips the probe and says so"))

# -- close is bounded ----------------------------------------------------

(def t-close (os/clock :monotonic))
(producer/close! p 1)
(assert (< (- (os/clock :monotonic) t-close) 5)
        "close flushes best-effort under its deadline and returns")

(print "driver-test: OK")
