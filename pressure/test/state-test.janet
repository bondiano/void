(import ../test-support/paths)
(import void/core/log :as log)
(import void/pressure/state :as state)

(log/set-level! "void.pressure" :error)

(defn- st [&opt extra]
  (state/make (merge {:enabled true
                      :sample-interval 60
                      :max-loop-lag 100
                      :max-rss-bytes 0
                      :recovery-ratio 0.8
                      :recovery-samples 2}
                     (or extra {}))))

# -- the threshold, and the bar under it ---------------------------------

(def s (st))
(assert (nil? (state/observe! s @{:loop-lag 5})) "a quiet sample changes nothing")
(assert (not (s :under-pressure)))

(assert (= :high (state/observe! s @{:loop-lag 150})) "over the limit is an edge")
(assert (s :under-pressure))
(assert (= 1 (s :episodes)))
(assert (nil? (state/observe! s @{:loop-lag 150}))
        "and staying over it is not another edge — :high fires once per episode")

(assert (nil? (state/observe! s @{:loop-lag 90}))
        "under the limit but over the recovery bar is still pressure — this is the hysteresis, and without it a process sitting on its limit sheds every other request")
(assert (s :under-pressure))

(assert (nil? (state/observe! s @{:loop-lag 70}))
        "one clean sample is not recovery either")
(assert (s :under-pressure))
(assert (= :recovered (state/observe! s @{:loop-lag 70}))
        "two of them (the configured :recovery-samples) are")
(assert (not (s :under-pressure)))
(assert (= 0 (s :clean)) "and the counter starts over")

(def bouncy (st))
(state/observe! bouncy @{:loop-lag 150})
(state/observe! bouncy @{:loop-lag 70})
(state/observe! bouncy @{:loop-lag 150})
(assert (= 0 (bouncy :clean))
        "a sample back over the bar resets the recovery run — the clean samples must be consecutive")
(assert (= 1 (bouncy :episodes)) "and it is still the same episode")

# -- a limit of 0 is off, a missing signal never trips a limit -----------

(def off (st {:max-loop-lag 0}))
(assert (nil? (state/observe! off @{:loop-lag 100000}))
        "a limit of 0 is off, not a limit of zero")

(def nomem (st {:max-rss-bytes 1000}))
(assert (nil? (state/observe! nomem @{:loop-lag 1 :rss nil}))
        "a threshold over a signal this platform cannot measure cannot trip")
(assert (= :high (state/observe! nomem @{:loop-lag 1 :rss 2000}))
        "and trips as soon as it can")
(assert (= :rss (get-in nomem [:reasons 0 :signal])))

# -- several reasons at once ---------------------------------------------

(def both (st {:max-rss-bytes 1000}))
(state/observe! both @{:loop-lag 150 :rss 2000})
(assert (= 2 (length (both :reasons))) "every signal that is over says so")
(assert (deep= @[:loop-lag :rss] (map |($ :signal) (both :reasons)))
        "in a stable order, so a log line is diffable")

# -- custom checks -------------------------------------------------------

(var pool-ok true)
(def checked (st))
(state/add-check! checked :db/pool (fn [] {:ok pool-ok :reason "pool exhausted"}))
(assert (nil? (state/observe! checked @{:loop-lag 1})))
(set pool-ok false)
(assert (= :high (state/observe! checked @{:loop-lag 1}))
        "a check that says no is pressure, whatever the numbers say")
(def r (get-in checked [:reasons 0]))
(assert (and (= :db/pool (r :signal)) (r :check) (= "pool exhausted" (r :reason))))
(set pool-ok true)
(state/observe! checked @{:loop-lag 1})
(assert (= :recovered (state/observe! checked @{:loop-lag 1})))

(def thrower (st))
(state/add-check! thrower :boom (fn [] (error "no answer")))
(assert (= :high (state/observe! thrower @{:loop-lag 1}))
        "a check that throws counts as pressure — a probe whose failure means 'carry on' is not a probe")
(assert (string/find "no answer" (get-in thrower [:reasons 0 :reason])))

(state/remove-check! thrower :boom)
(state/observe! thrower @{:loop-lag 1})
(assert (= :recovered (state/observe! thrower @{:loop-lag 1})))

(def replaced (st))
(state/add-check! replaced :one (fn [] {:ok true}))
(state/add-check! replaced :one (fn [] {:ok false}))
(assert (= 1 (length (replaced :checks))) "registering a name twice replaces it")

# -- events --------------------------------------------------------------

(def seen @[])
(state/listen! :test (fn [ev] (array/push seen (ev :event))))
(def evented (st))
(state/observe! evented @{:loop-lag 150})
(state/observe! evented @{:loop-lag 1})
(state/observe! evented @{:loop-lag 1})
(state/unlisten! :test)
(assert (deep= @[:high :recovered] seen) "one event per edge, in order")

(state/listen! :bad (fn [_] (error "listener is broken")))
(def survives (st))
(assert (= :high (state/observe! survives @{:loop-lag 150}))
        "a listener that throws never breaks the sampler")
(state/unlisten! :bad)

# -- the flag is the process's, not one state's --------------------------

(def isolated (st))
(state/observe! isolated @{:loop-lag 150})
(assert (not (state/under-pressure?))
        "a state nobody made active does not flip the process flag — which is what lets a test build one")

(with-dyns [state/state-dyn isolated]
  (def live (st))
  (state/observe! live @{:loop-lag 150})
  (assert (not (state/under-pressure?)) "still not the active one"))

(set state/current isolated)
(state/observe! isolated @{:loop-lag 1})
(state/observe! isolated @{:loop-lag 1})
(assert (not (state/under-pressure?)))
(state/observe! isolated @{:loop-lag 150})
(assert (state/under-pressure?) "the active state does flip it")
(set state/pressed false)
(set state/current nil)

# -- the sampler fiber ---------------------------------------------------

(def sampling (st {:sample-interval 0.01}))
(state/start-sampler! sampling)
(ev/sleep 0.08)
(state/stop-sampler! sampling)
(assert (>= (sampling :sampled) 3) "the fiber samples on its interval")
(assert (not (sampling :sampling)))
(assert (number? (get-in sampling [:samples :loop-lag])) "and what it sampled is readable")

(def disabled (st {:enabled false :sample-interval 0.01}))
(state/start-sampler! disabled)
(ev/sleep 0.05)
(assert (zero? (disabled :sampled)) ":enabled false means no sampler at all")
(state/stop-sampler! disabled)

(set state/mode :supervisor)
(def supervisor (st {:sample-interval 0.01}))
(state/start-sampler! supervisor)
(ev/sleep 0.05)
(assert (zero? (supervisor :sampled))
        "a supervisor process samples nothing — the prefork master's loop is idle by construction, and a zero from it would be a measurement of nobody's requests")
(assert (= :supervisor ((state/status supervisor) :mode)) "and the status says which it is")
(state/stop-sampler! supervisor)
(set state/mode :process)

(def short-lived (st {:sample-interval 0.01}))
(state/start-sampler! short-lived)
(state/stop-sampler! short-lived)
(assert (not (short-lived :sampling))
        "started and stopped in one turn — the cancellation race the cache sweeper documents")

# -- status --------------------------------------------------------------

(def reported (st {:max-rss-bytes 2000}))
(state/observe! reported @{:loop-lag 150 :rss 100})
(state/shed! reported)
(state/shed! reported)
(def snap (state/status reported))
(assert (snap :under-pressure))
(assert (= 2 (snap :shed)))
(assert (= 1 (snap :episodes)))
(assert (= 100 (get-in snap [:limits :max-loop-lag])))
(assert (= 2000 (get-in snap [:limits :max-rss-bytes])))
(assert (= 150 (get-in snap [:peaks :loop-lag])))
(assert (number? (snap :for)))
(assert (nil? (state/status)) "and without a started component there is nothing to report")

(print "state-test ok")
