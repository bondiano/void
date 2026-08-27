(import ../test-support/paths)
(import ../test-support/server)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/redis :as redis)
(import void/redis/http :as redis-http)
(import void/redis/state :as state)

(log/set-level! "void.redis" :error)
(log/set-level! "void.http" :error)

# -- the contribution is declared, server or not -------------------------

(def manifest (get plugin/manifest-registry :void/redis-http))
(def store-contribs (get-in manifest [:contributes :void.http/session-store] []))
(assert (= 1 (length store-contribs)) "one session store is contributed")
(assert (= :redis (get-in store-contribs [0 :name]))
        "under the name [:http :session :store] selects it by")
(assert (function? (get-in store-contribs [0 :make])) "as a factory, per the point's schema")

# -- the routes the request test drives ----------------------------------

(defn visit
  "Counts visits in the session, and answers with the count."
  [req]
  (def s (req :session))
  (put s :visits (inc (get s :visits 0)))
  (ring/text 200 (string (s :visits))))

(defn logout [_req]
  (put (ring/text 200 "bye") :session :delete))

(def app-routes
  (router/routes {}
    (router/GET "/visit" 'visit {:name :visit})
    (router/GET "/logout" 'logout {:name :logout})))

(def app-manifest
  (plugin/manifest 'test/session-app
    :version "0.1.0"
    :requires {:void/http ">=0.0.1"}
    :contributes {:void.http/route-source [{:name :test/session-app
                                            :routes app-routes
                                            :env (router/env-ref (curenv))}]}))

(if-not (server/available?)
  (server/skip "session-test")
  (do
    (def prefix (server/prefix "session"))
    (def boot
      (plugin/start!
        {:plugins ["void/http/init" "void/redis/init" "void/redis/http" app-manifest]
         :profile :test
         :config {:env @{}
                  :cli {:log {:level :error}
                        :redis {:url (server/url) :prefix prefix
                                :pubsub {:enabled false}}
                        :http {:port 0
                               :session {:enabled true :store :redis :ttl 60}}}}}))

    (defer (plugin/shutdown! boot 3)

      # -- the store, on its own -----------------------------------------

      (def store (redis-http/store))
      (assert (nil? ((store :load) "no-such-session")) "an unknown id loads as nil")
      ((store :save) "sid-1" @{:user 7 :roles [:admin]} 60)
      (def loaded ((store :load) "sid-1"))
      (assert (table? loaded)
              "a session loads as a *table* — the middleware mutates what it is given")
      (assert (= 7 (loaded :user)) "with its keyword keys intact")
      (assert (= :admin (get-in loaded [:roles 0])) "and its nested values")
      (assert (string/has-prefix? prefix (redis/redis-key "session:sid-1"))
              "under the client's key prefix")
      (assert (= 60 (redis/ttl "session:sid-1"))
              "and with the ttl as redis' own expiry — there is nothing to sweep")
      (assert (nil? ((store :sweep))) "which is what :sweep says by doing nothing")
      ((store :delete) "sid-1")
      (assert (nil? ((store :load) "sid-1")) "deleting a session deletes it")

      # -- the full stack ------------------------------------------------

      (def first-visit (http/with-request {:uri "/visit"}))
      (assert (= 200 (first-visit :status)))
      (assert (= "1" (string (first-visit :body))) "a fresh session starts at one")

      (def cookie (get-in first-visit [:headers "set-cookie"]))
      (assert cookie "and the response carries the session cookie")
      (def cookie-line (if (indexed? cookie) (first cookie) cookie))
      (def sid (last (string/split "=" (first (string/split ";" cookie-line)))))

      (def second-visit
        (http/with-request {:uri "/visit" :headers {"cookie" (string "void-session=" sid)}}))
      (assert (= "2" (string (second-visit :body)))
              "and the next request with that cookie finds it in redis")

      (assert ((store :load) sid) "which is where it is")

      (def farewell
        (http/with-request {:uri "/logout" :headers {"cookie" (string "void-session=" sid)}}))
      (assert (= 200 (farewell :status)))
      (assert (nil? ((store :load) sid)) "and {:session :delete} takes it out of redis")

      (def after
        (http/with-request {:uri "/visit" :headers {"cookie" (string "void-session=" sid)}}))
      (assert (= "1" (string (after :body)))
              "a cookie the store does not know is never adopted — the count starts again")

      (server/clean! redis/scan-each redis/del))

    (printf "session-test: ok")))
