(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/rest :as rest)
(import void/pressure :as pressure)
(import void/pressure/state :as state)
(require "void/pressure/http")
(import spork/json)

(log/set-level! "void" :error)

# The claim ADR-0019 makes about the refusal — "503 through the
# standard error path: problem+json with void/rest, the ordinary
# rendering without it" — is a claim about a plugin this package does
# not depend on, so it is only true if something loads both and looks.

(defn orders [req] (rest/json {:orders []}))

(def app-routes
  (router/routes {}
    (router/GET "/orders" 'orders {:name :orders :void.rest/problems true})))

(def app-manifest
  (plugin/manifest 'test/api
    :version "0.1.0"
    :requires {:void/pressure-http ">=0.0.1" :void/rest ">=0.0.1"}
    :contributes {:void.http/route-source [{:name :test/api
                                            :routes app-routes
                                            :env (router/env-ref (curenv))}]}))

(def boot
  (plugin/start!
    {:plugins [:void/http :void/rest :void/pressure :void/pressure-http app-manifest]
     :profile :test
     :config {:env @{}
              :cli {:log {:level :error}
                    :http {:port 0 :strict-meta true}
                    :pressure {:sample-interval 600 :max-loop-lag 100}
                    :pressure-http {:retry-after 7}}}}))

(defer (plugin/shutdown! boot 3)
  (def st (get-in boot [:system :instances :pressure/sampler]))

  (assert (= 200 ((http/with-request {:uri "/orders"}) :status)))

  (state/observe! st @{:loop-lag 500})
  (def refused (http/with-request {:uri "/orders"}))
  (assert (= 503 (refused :status)))
  (assert (= "application/problem+json" (get-in refused [:headers "content-type"]))
          "an API client gets the media type every other void/rest failure uses")
  (assert (= "7" (get-in refused [:headers "retry-after"]))
          "and Retry-After survives the renderer that produced the body")
  (def problem (json/decode (refused :body)))
  (assert (= 503 (problem "status")))
  (assert (= "Service Unavailable" (problem "title")))
  (assert (index-of "loop-lag" (problem "signals"))
          "with what is saturated, so a caller's dashboard can tell this 503 from a dependency's")
  (assert (nil? (problem "detail"))
          "and without the message: void/rest hides the detail of every 5xx outside dev, and a shed is not the exception that changes that rule"))

(print "rest-test ok")
