(import ../test-support/paths)
(import void/core/log :as log)
(import void/test :as test)
(import void/obs :as obs)
(import void/obs/trace :as trace)
(import void/bus :as bus)
(import void/bus/router :as router)
(import void/bus/state :as state)

(log/set-level! "void" :error)

# The seam the design asks for — a trace continued out of HTTP: a
# trace that starts in a request and continues in whatever consumes
# the message that request published.
#
# **void/bus has no edge to void/obs**, and this suite is what makes
# that a checked claim rather than a sentence in a docstring: the bus
# is booted *without* obs first and publishes perfectly well, then
# booted with obs on the module path and the same publish carries a
# W3C `traceparent` that the consumer's span hangs under. The
# resolution is `require` at :start (void/bus/state's `resolve-tracer`),
# the same seam void/obs itself uses to instrument void/db without
# importing it.

(def spans @[])
(def consumed @[])

(bus/defhandler note {:topic :trace/one} [msg]
  (array/push consumed (get-in msg [:meta :traceparent])))

# What decides is the *composition*, not the module path: obs is
# imported by this very file, so its functions are reachable in both
# halves of this suite. Composing obs is the decision to observe, and
# it is the one the broker reads at :start.

(defn- start [plugins &opt extra]
  (test/start! {:plugins plugins
                :profile :test
                :config {:env @{}
                         :cli (merge {:log {:level :error}
                                      :bus {:dedup {:enabled false}
                                            :poison {:enabled false}
                                            :retry {:enabled false}}}
                                     (or extra {}))}}))

# -- with obs ------------------------------------------------------------

(def boot
  (start ["void/bus/init" "void/obs/init"]
         {:obs {:trace {:enabled true :sample-rate 1 :always true}}}))

(defer (test/stop! boot)
  (trace/set-exporters! [{:name :collect :fn (fn [span] (array/push spans span))}])

  (assert (get state/current-broker :tracer)
          "with obs started the broker found the three functions it needs")

  # a request's span — what void/obs-http would have opened
  (var published nil)
  (def request-span
    (obs/with-span* "GET /pay" {:kind :server :sampled true}
      (fn []
        (set published (bus/publish :trace/one {:amount 10}))
        (obs/current-span))))

  (assert (get-in published [:meta :traceparent])
          "a message published inside a span carries the trace context")
  (assert (string/has-prefix? (string "00-" (request-span :trace-id))
                              (get-in published [:meta :traceparent]))
          "and it is this request's trace, in the W3C spelling")

  (ev/sleep 0.08)
  (assert (= 1 (length consumed)))
  (assert (= (get-in published [:meta :traceparent]) (first consumed))
          "the consumer receives it unchanged")

  # the consumer's span is a child of the publisher's trace
  (def consumer-span
    (find |(string/has-prefix? "bus consume" ($ :name)) spans))
  (assert consumer-span "the consumer opened a span of its own")
  (assert (= (request-span :trace-id) (consumer-span :trace-id))
          "in the same trace as the request that published — which is the whole point")
  (assert (= (request-span :span-id) (consumer-span :parent-id))
          "hanging under the span that published")
  (assert (= :consumer (consumer-span :kind)))
  (assert (= "void.bus" (get-in consumer-span [:attrs :messaging.system])))
  (assert (= "trace/one" (get-in consumer-span [:attrs :messaging.destination])))

  # -- correlation does not need obs at all ------------------------------

  (assert (= (published :id) (bus/correlation-id published))
          "a correlation id is minted whether or not anything is tracing"))

# -- without obs ---------------------------------------------------------

(array/clear consumed)
(each n (router/defined) (router/forget! n))
(def payloads @[])
(router/define! :plain {:topic :trace/one} {:fn (fn [m] (array/push payloads (m :payload)))})

(def bare (start ["void/bus/init"]))
(defer (test/stop! bare)
  (assert (nil? (get state/current-broker :tracer))
          "without obs in the composition there is no tracer, and that is not an error")
  (def msg (bus/publish :trace/one {:amount 11}))
  (assert (nil? (get-in msg [:meta :traceparent]))
          "nothing writes a trace context nobody produced")
  (ev/sleep 0.08)
  (assert (= 1 (length payloads))
          "and the message is delivered exactly as it would have been")
  (assert (not (get (bus/stats) :tracing)) "which `void bus stats` says out loud"))

(print "void/bus tracing tests OK")
