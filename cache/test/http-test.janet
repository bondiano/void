(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/init :as http)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import void/cache :as cache)
(require "void/cache/http")

(log/set-level! "void" :error)

# -- an application with one cached route and one plain one --------------

(var computed 0)

(defn rates [req]
  (++ computed)
  (ring/text 200 (string "rates " computed)))

(defn greet [req]
  (++ computed)
  (ring/text 200 (string "hello " (get-in req [:headers "accept-language"] "?"))))

(defn with-cookie [req]
  (++ computed)
  (ring/set-cookie (ring/text 200 "personal") "sid" "abc123"))

(defn private [req]
  (++ computed)
  (ring/header (ring/text 200 "mine") "cache-control" "private, max-age=0"))

(defn streamed [req]
  (++ computed)
  (ring/response 200 (coro (yield "chunk"))))

(defn plain [req]
  (++ computed)
  (ring/text 200 "uncached"))

(def app-routes
  (router/routes {}
    (router/GET "/rates" 'rates {:name :rates :void.cache/response {:ttl 60}})
    (router/GET "/greet" 'greet {:name :greet
                                 :void.cache/response {:ttl 60 :vary ["accept-language"]}})
    (router/GET "/cookie" 'with-cookie {:name :cookie :void.cache/response {:ttl 60}})
    (router/GET "/private" 'private {:name :private :void.cache/response {:ttl 60}})
    (router/GET "/stream" 'streamed {:name :stream :void.cache/response {:ttl 60}})
    (router/GET "/brief" 'rates {:name :brief :void.cache/response {:ttl 0.05}})
    (router/GET "/opted-out" 'rates {:name :opted-out :void.cache/response {:ttl 0}})
    (router/GET "/plain" 'plain {:name :plain})))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/cache-http ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]}))

(def plugins [:void/http :void/cache :void/cache-http app-manifest])

(defn- config [extra]
  {:env @{} :cli (merge {:log {:level :error} :http {:port 0 :strict-meta true}} extra)})

# -- the declaration -----------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "the composition validates")

(def [bad err]
  (protect (plugin/dry-run
             {:plugins plugins :profile :test
              :config (config {:cache-http {:ttl "soon"}})})))
(assert (not bad) "a bad [:cache-http] slice fails the boot")

(def boot (plugin/start! {:plugins plugins :profile :test
                          :config (config {:cache {:prefix "c:" :memory {:sweep-interval 0}}})}))

(defer (plugin/shutdown! boot 3)

  # -- what a route that never asked for caching pays --------------------

  (def marked (http/explain-route "/rates"))
  (def unmarked (http/explain-route "/plain"))
  (assert (index-of :void.cache/response (marked :middleware))
          "a marked route has the cache in its chain")
  (assert (not (index-of :void.cache/response (unmarked :middleware)))
          "and an unmarked one does not have it at all — which is why there is no B1 line to report")

  # -- a hit is a hit ----------------------------------------------------

  (set computed 0)
  (def first- (http/with-request {:uri "/rates"}))
  (def second- (http/with-request {:uri "/rates"}))
  (assert (= "MISS" (get-in first- [:headers "x-cache"])))
  (assert (= "HIT" (get-in second- [:headers "x-cache"])))
  (assert (= (first- :body) (second- :body)) "the same bytes come back")
  (assert (= 1 computed) "and the handler ran once")
  (assert (get-in second- [:headers "age"]) "a replayed response says how old it is")
  (assert (= "text/plain; charset=utf-8" (get-in second- [:headers "content-type"]))
          "with the headers the handler set")

  # -- the key ------------------------------------------------------------

  (assert (= "MISS" (get-in (http/with-request {:uri "/rates?a=1&b=2"}) [:headers "x-cache"])))
  (assert (= "HIT" (get-in (http/with-request {:uri "/rates?b=2&a=1"}) [:headers "x-cache"]))
          "a query is a set of parameters, not the order they were written in")
  (assert (= "MISS" (get-in (http/with-request {:uri "/rates?a=2"}) [:headers "x-cache"]))
          "a different query is a different entry")

  (set computed 0)
  (def en (http/with-request {:uri "/greet" :headers {"accept-language" "en"}}))
  (def en2 (http/with-request {:uri "/greet" :headers {"accept-language" "en"}}))
  (def de (http/with-request {:uri "/greet" :headers {"accept-language" "de"}}))
  (assert (= "MISS" (get-in en [:headers "x-cache"])))
  (assert (= "HIT" (get-in en2 [:headers "x-cache"])))
  (assert (= "MISS" (get-in de [:headers "x-cache"])) ":vary is part of the key")
  (assert (= "hello de" (string (de :body))) "and each variant is its own answer")
  (assert (= 2 computed))

  # -- what a shared cache refuses ---------------------------------------

  (set computed 0)
  (http/with-request {:uri "/cookie"})
  (def again (http/with-request {:uri "/cookie"}))
  (assert (= "MISS" (get-in again [:headers "x-cache"]))
          "a response carrying a Set-Cookie is never stored — it belongs to one visitor")
  (assert (= 2 computed))

  (http/with-request {:uri "/private"})
  (assert (= "MISS" (get-in (http/with-request {:uri "/private"}) [:headers "x-cache"]))
          "and neither is one the handler marked private")

  (http/with-request {:uri "/stream"})
  (assert (= "MISS" (get-in (http/with-request {:uri "/stream"}) [:headers "x-cache"]))
          "nor a streaming body, which can be read once and a cache exists to replay")

  (http/with-request {:uri "/rates"})
  (def authed (http/with-request {:uri "/rates" :headers {"authorization" "Bearer t"}}))
  (assert (= "BYPASS" (get-in authed [:headers "x-cache"]))
          "a request carrying Authorization goes around the cache entirely (RFC 9111 §3.5)")

  # -- ttl ---------------------------------------------------------------

  (set computed 0)
  (http/with-request {:uri "/brief"})
  (assert (= "HIT" (get-in (http/with-request {:uri "/brief"}) [:headers "x-cache"])))
  (ev/sleep 0.08)
  (assert (= "MISS" (get-in (http/with-request {:uri "/brief"}) [:headers "x-cache"]))
          "an expired entry is a miss like any other")

  (http/with-request {:uri "/opted-out"})
  (assert (= "MISS" (get-in (http/with-request {:uri "/opted-out"}) [:headers "x-cache"]))
          ":ttl 0 is how a route opts out of what its group set")

  # -- invalidation from the application ---------------------------------

  (set computed 0)
  (http/with-request {:uri "/rates"})
  (cache/clear!)
  (def cold (http/with-request {:uri "/rates"}))
  (assert (= "MISS" (get-in cold [:headers "x-cache"]))
          "clearing the cache clears the pages in it — it is one cache")

  # -- the unmarked route is untouched ------------------------------------

  (def p (http/with-request {:uri "/plain"}))
  (assert (nil? (get-in p [:headers "x-cache"])) "no header, no wrapper, no cost"))

(printf "http-test: ok")
