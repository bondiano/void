### B4 — WebSocket broadcast. Budget: delivery < 50 ms to 1000
### connections, 10k messages a second. There is no p50/p99 *request*
### latency here and no throughput floor in requests: B4 measures a
### fan-out, and the number that matters is how long a message takes to
### reach the peers.
###
### The shape: every connection joins one room, and a fiber broadcasts
### into it at a fixed rate (BENCH_BROADCAST_RATE, default 10/s — with the
### generator's 1000 connections that is the budgeted 10k msg/s). Each
### carries the monotonic clock reading at the moment it was framed; the
### generator subtracts it from its own reading when the message arrives,
### which works because CLOCK_MONOTONIC is the machine's, not the
### process's.
###
### **What this measures, precisely**: one encode and N enqueues in the
### broadcaster's fiber (void/ws/rooms), then N writer fibers getting
### their turn on the loop. That second half is the interesting one —
### it is where a fan-out either scales with the number of connections
### or stops doing so, and it is why the delivery percentile and not
### the mean is the budget.
###
### PORT overrides the listen port (default 8104). The app carries
### `bench/probe` like the rest of the suite, so the runner reads the
### loop lag this process saw while it was fanning out.

(import ../prelude)
(import void)
(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import void/ws :as ws)
(require "void/http/init")
(require "void/ws/init")
(require "void/bench/probe")

(def room
  "The one room every connection joins."
  :bench)

(def rate
  "Broadcasts per second (BENCH_BROADCAST_RATE)."
  (or (scan-number (or (os/getenv "BENCH_BROADCAST_RATE") "")) 10))

(def payload-bytes
  "Extra bytes per message (BENCH_BROADCAST_BYTES) — a broadcast of a
  rendered fragment is not 40 bytes, and the fan-out cost of a bigger
  message is a different curve."
  (or (scan-number (or (os/getenv "BENCH_BROADCAST_BYTES") "")) 0))

(def filler (string/repeat "x" (max 0 payload-bytes)))

(defn live
  "The socket: join the room, say nothing, listen."
  [req]
  (ws/accept req {:rooms [room]}))

(defn stats
  "GET /stats — what the fan-out has done, for the generator's report
  and for a human watching a run."
  [req]
  (def st (ws/status))
  (ring/response 200
                 (json/encode (merge (ws/stats)
                                     {:connections (st :connections)
                                      :peak (st :peak)
                                      :rate rate}))
                 @{"content-type" "application/json"}))

(plugin/contribute! :void.http/route-source
  {:name :bench.b4/routes
   :routes (router/routes {}
             (router/GET "/ws" 'live {:name :live :void.ws/socket true})
             (router/GET "/stats" 'stats {:name :stats}))
   :env (router/env-ref (curenv))})

# -- the broadcaster -----------------------------------------------------

(var broadcasting false)

(def broadcaster-component
  (system/component :bench.b4/broadcaster
    :doc "One fiber, one message per tick, into the one room."
    :deps [:ws/registry]
    :start
    (fn start [_ _]
      (def state @{:sent 0 :delivered 0})
      (set broadcasting true)
      (def interval (/ 1 rate))
      (ev/go
        (fn broadcast-loop []
          # a fixed schedule rather than `sleep interval` between ticks:
          # sleeping the interval sleeps *at least* it, and the fan-out's
          # own cost is then added to every period, so the rate drifts
          # below the configured one and the benchmark quietly measures a
          # slower broadcast than it asked for. This is wrk2's argument
          # about coordinated omission, on the sending side
          (var next-at (+ (os/clock :monotonic) interval))
          (while broadcasting
            (def wait (- next-at (os/clock :monotonic)))
            (if (pos? wait)
              (ev/sleep wait)
              # behind schedule: the loop could not keep up, and
              # skipping ahead is what keeps the *next* tick honest
              (set next-at (os/clock :monotonic)))
            (set next-at (+ next-at interval))
            (when broadcasting
              (def [ok n]
                (protect
                  (ws/broadcast!
                    room
                    # the timestamp is taken here, inside the tick, so
                    # what the generator measures is delivery and not
                    # the scheduler's opinion of when this fiber should
                    # have woken up
                    (json/encode {:seq (state :sent)
                                  :t (os/clock :monotonic)
                                  :pad filler}))))
              (when ok
                (put state :sent (inc (state :sent)))
                (put state :delivered (+ (state :delivered) n)))))))
      state)
    :stop (fn stop [state] (set broadcasting false) state)
    :health (fn health [state] (merge {:status :up} (table/to-struct state)))))

(plugin/defplugin bench/b4
  :doc "B4 WebSocket broadcast — one room, N connections, a fixed broadcast rate."
  :version "0.0.1"
  :requires {:void/http ">=0.0.1" :void/ws ">=0.0.1"}
  :components [broadcaster-component])

(def app
  {:plugins [;(if (= "0" (os/getenv "VOID_BENCH_PROBE")) [] [:bench/probe])
             :void/http :void/ws :bench/b4]
   :profile :prod
   :config {:cli {:http {:host "127.0.0.1"
                         :port (or (scan-number (or (os/getenv "PORT") "")) 8104)
                         # the connection ceiling is the benchmark's
                         # subject, so it must not be the kernel's
                         # default (1024) that decides it
                         :max-connections 8192}
                  :ws {:max-connections 8192
                       # a peer that stops reading under a 10k msg/s
                       # fan-out is a result, not a nuisance: the drops
                       # and the closed connections are in /stats
                       :send-queue 256}}}})

(defn main [& args]
  (void/run! app))
