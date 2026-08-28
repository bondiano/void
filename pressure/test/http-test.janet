(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/init :as http)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import void/pressure :as pressure)
(import void/pressure/state :as state)
(require "void/pressure/http")

(log/set-level! "void" :error)

# -- an application with a route that may be shed and one that may not ---

(var served 0)

(defn work [req]
  (++ served)
  (ring/text 200 "worked"))

(defn health [req]
  (++ served)
  (ring/text 200 "ok"))

(def app-routes
  (router/routes {}
    (router/GET "/work" 'work {:name :work})
    (router/GET "/ops/health" 'health {:name :health :void.pressure/exempt true})))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/pressure-http ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]
     # what a plugin that knows something the sampler cannot measure
     # contributes (ADR-0019): a pool at its ceiling, a queue growing
     # faster than it drains
     :void.pressure/check [{:name :test/pool
                            :fn (fn [] {:ok (not (dyn :pool-exhausted))
                                        :reason "pool exhausted"})}]}))

(def plugins [:void/http :void/pressure :void/pressure-http app-manifest])

(defn- config [extra]
  {:env @{}
   :cli (merge {:log {:level :error}
                :http {:port 0 :strict-meta true}
                # a sample interval long enough that the fiber never
                # fires during the test: the samples here are fed in by
                # hand, which is the only way a threshold test is not
                # also a timing test
                :pressure {:sample-interval 600 :max-loop-lag 100}}
               extra)})

# -- the declaration -----------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "the composition validates")
(assert (= 1 (get-in report [:extensions :void.pressure/check :contributions]))
        "and the check the app contributed is in the point")

(def [bad] (protect (plugin/dry-run {:plugins plugins :profile :test
                                     :config (config {:pressure-http {:retry-after "soon"}})})))
(assert (not bad) "a bad [:pressure-http] slice fails the boot")

(def [bad2] (protect (plugin/dry-run {:plugins plugins :profile :test
                                      :config (config {:pressure-http {:status 200}})})))
(assert (not bad2) "and a shed status that is not an error status does too")

# -- started -------------------------------------------------------------

(def boot (plugin/start! {:plugins plugins :profile :test
                          :config (config {:pressure-http {:retry-after 3}})}))

(defer (plugin/shutdown! boot 3)
  (def st (get-in boot [:system :instances :pressure/sampler]))
  (assert st "the sampler component started")
  (assert (= st (state/active)) "and it is what the middleware reaches for")
  (assert (= 1 (length (st :checks))) "with the contributed check wired in")

  # -- what an exempt route pays ----------------------------------------

  (def shed-able (http/explain-route "/work"))
  (def exempt (http/explain-route "/ops/health"))
  (assert (index-of :void.pressure/shed (shed-able :middleware))
          "an ordinary route has the shedder in its chain")
  (assert (not (index-of :void.pressure/shed (exempt :middleware)))
          "and an exempt one does not have it at all — it cannot be shed, and it costs nothing")

  # -- the calm path -----------------------------------------------------

  (set served 0)
  (def calm (http/with-request {:uri "/work"}))
  (assert (= 200 (calm :status)))
  (assert (= 1 served) "with no pressure, the handler runs")

  # -- under pressure ----------------------------------------------------

  (state/observe! st @{:loop-lag 500})
  (assert (pressure/under-pressure?) "the process is shedding")

  (set served 0)
  (def refused (http/with-request {:uri "/work"}))
  (assert (= 503 (refused :status)) "and an ordinary request is refused")
  (assert (zero? served) "before the handler ran — the point of shedding early")
  (assert (= "3" (get-in refused [:headers "retry-after"]))
          "with the Retry-After a client needs to not make it worse")
  (assert (string/find "503" (string (refused :body)))
          "rendered by the error path, not by a body written here")

  (def still-up (http/with-request {:uri "/ops/health"}))
  (assert (= 200 (still-up :status))
          "and /health still answers — an operator (and the load balancer) must see a process that is refusing everything else")

  (assert (= 1 (st :sheds)) "refused requests are counted")
  (http/with-request {:uri "/work"})
  (assert (= 2 (st :sheds)))

  # -- back down ---------------------------------------------------------

  (state/observe! st @{:loop-lag 1})
  (state/observe! st @{:loop-lag 1})
  (assert (not (pressure/under-pressure?)))
  (assert (= 200 ((http/with-request {:uri "/work"}) :status))
          "and the process serves again")

  # -- a check is a reason like any other --------------------------------

  (with-dyns [:pool-exhausted true]
    (state/observe! st @{:loop-lag 1}))
  (assert (pressure/under-pressure?)
          "a :void.pressure/check that says no sheds just as a threshold does")
  (def by-check (http/with-request {:uri "/work"}))
  (assert (= 503 (by-check :status)))
  (state/observe! st @{:loop-lag 1})
  (state/observe! st @{:loop-lag 1})
  (assert (not (pressure/under-pressure?)))

  # -- the status surface ------------------------------------------------

  (def s (pressure/status))
  (assert (not (s :under-pressure)))
  (assert (= 3 (s :shed)))
  (assert (= 2 (s :episodes)))
  (assert (index-of :test/pool (s :checks)))
  (assert (= :process (s :mode))
          "one worker: this process is the one serving, so its loop is the one sampled")

  (def checks (plugin/extension boot :void.core/health))
  (def health-check (first (filter |(= :pressure/state ($ :name)) checks)))
  (assert health-check "void/pressure contributes a health check")
  (assert (= :up (((health-check :fn)) :status)))
  (state/observe! st @{:loop-lag 500})
  (def degraded ((health-check :fn)))
  (assert (= :degraded (degraded :status))
          "and it goes degraded while the process sheds")
  (assert (not (empty? (degraded :reasons))) "saying why")
  (state/observe! st @{:loop-lag 1})
  (state/observe! st @{:loop-lag 1}))

(print "http-test ok")
