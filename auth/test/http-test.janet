# void/auth-http end to end over test/inject (ADR-0017): the session
# flow with its cookie rotation, bearer tokens, JWT, :void.auth/access
# enforcement and the strategy narrowing a route can ask for.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/auth :as auth)
(import void/auth/http :as auth-http)
(import void/auth/state :as state)
(import void/auth/hash :as hash)
(import void/crypto :as crypto)
(import void/crypto/kdf :as kdf)
(require "void/crypto/init")
(require "void/auth/init")

(log/set-level! "void" :error)

# -- the application -----------------------------------------------------

(defn who [req]
  (ring/text 200 (or (auth/subject) "nobody")))

(defn login [req]
  (def result (auth/check-password (state/users) (req :form)))
  (if-let [id (result :identity)]
    (do (auth-http/login! req id)
        (ring/text 200 (string "welcome " (id :subject))))
    (ring/text 401 (string "no: " (result :reason)))))

(defn logout [req]
  (auth-http/logout! req)
  (ring/text 200 "bye"))

(def app-routes
  (router/routes {}
    (router/GET "/public" 'who {:name :public})
    (router/GET "/me" 'who {:name :me :void.auth/access :required})
    (router/POST "/login" 'login {:name :login})
    (router/POST "/logout" 'logout {:name :logout})
    (router/GET "/api/me" 'who {:name :api-me
                                :void.auth/access :required
                                :void.auth/strategies [:bearer]})))

(def app
  (plugin/manifest 'test/auth-app
    :version "0.1.0"
    :requires {:void/auth-http ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/auth-app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]}))

(def plugins ["void/http/init" "void/crypto/init" "void/auth/init" "void/auth/http" app])

(defn- config [extra]
  {:env @{}
   :cli (merge {:log {:level :error}
                :http {:port 0 :session {:enabled true} :access-log false}
                # the suite hashes a lot and measures nothing: the cost
                # that matters is pinned in void/crypto's own tests
                :crypto {:kdf {:in-thread false}}
                :auth {:scrypt {:ln 10}}}
               extra)})

# -- the composition -----------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "void/auth + void/auth-http compose over void/http")
(assert (get-in report [:extensions :void.auth/strategy])
        "and the strategy point is owned by void/auth")
(assert (= 3 (get-in report [:extensions :void.auth/strategy :contributions]))
        "session, bearer and jwt are contributed by void/auth-http")

# a route may tighten access, never loosen it (:restrict)
(def loosened
  (router/routes {:void.auth/access :required}
    (router/GET "/oops" 'who {:name :oops :void.auth/access :public})))
(def loosen-app
  (plugin/manifest 'test/loosen
    :version "0.1.0"
    :requires {:void/auth-http ">=0.0.1"}
    :contributes {:void.http/route-source [{:name :test/loosen
                                            :routes loosened
                                            :env (router/env-ref (curenv))}]}))
(def [ok] (protect (plugin/start! {:plugins ["void/http/init" "void/crypto/init" "void/auth/init"
                                             "void/auth/http" loosen-app]
                                   :profile :test :config (config {})
                                   :only [:http/kernel]})))
(assert (not ok)
        "a route inside a :required group cannot declare itself :public — :restrict is what makes that a boot error rather than a hole")

# `with-http` starts the kernel and what it depends on (ADR-0017); the
# auth registry is not one of the kernel's dependencies — it is a
# component the middleware reaches through state — so the subset has to
# name it, or the handlers find no user store.
(def only [:http/kernel :auth/registry])

# -- the session flow ----------------------------------------------------

# the fixture hash is computed before any plugin starts, so the library
# is opened by hand here — this is exactly what `(crypto/load!)` is for
(crypto/load!)
(set kdf/in-thread false)
(set hash/settings {:hasher :scrypt :scrypt {:ln 10 :r 8 :p 1 :length 32 :salt-bytes 16}})
(def pw-hash (hash/hash "hunter2"))

(test/with-http [c {:plugins plugins :only only
                    :config (config {:auth {:scrypt {:ln 10}
                                            :users {"user:1" {:email "a@b.c"
                                                              :password-hash pw-hash
                                                              :claims {:role :admin}}}}})}]

  (assert (index-of :void.auth/identity ((http/explain-route "/me") :middleware))
          "the identity middleware is in the chain")

  # anonymous
  (assert (= "nobody" (test/text (test/inject c {:uri "/public"}))))
  (def denied (test/inject c {:uri "/me"}))
  (assert (= 401 (denied :status)) "a :required route without an identity is 401")

  # a wrong password says nothing about whether the account exists
  (def bad (test/inject c {:method :post :uri "/login"
                           :form {:email "a@b.c" :password "nope"}}))
  (assert (= 401 (bad :status)))
  (assert (string/find "bad-password" (test/text bad)))
  (def unknown (test/inject c {:method :post :uri "/login"
                               :form {:email "z@z.z" :password "nope"}}))
  (assert (= 401 (unknown :status)))

  # login
  (def anon-cookie (get (c :cookies) "void-session"))
  (def in (test/inject c {:method :post :uri "/login"
                          :form {:email "a@b.c" :password "hunter2"}}))
  (assert (= 200 (in :status)) (test/text in))
  (assert (= "welcome user:1" (test/text in)))
  (def logged-cookie (get (c :cookies) "void-session"))
  (assert logged-cookie "the login issued a session cookie")
  (assert (not= anon-cookie logged-cookie)
          "and it is a new session id — an id that survives a login is session fixation (ADR-0023 §8)")

  # the session is what carries it now
  (assert (= "user:1" (test/text (test/inject c {:uri "/me"}))))
  (assert (= "user:1" (test/text (test/inject c {:uri "/public"})))
          "a public route sees the identity too — that is how a page says who is signed in")

  # logout
  (def out (test/inject c {:method :post :uri "/logout"}))
  (assert (= 200 (out :status)))
  (assert (not= logged-cookie (get (c :cookies) "void-session"))
          "logout rotates the id as well: the next visitor on this machine must not inherit it")
  (assert (= 401 ((test/inject c {:uri "/me"}) :status)) "and the identity is gone"))

# -- bearer tokens -------------------------------------------------------

(test/with-http [c {:plugins plugins :only only :config (config {})}]
  (def value (state/active))
  (def issued (auth/issue-token (value :tokens) "service:billing" {:name "ci" :scopes [:read]}))

  (def with-token (test/inject c {:uri "/api/me"
                                  :headers {"authorization" (string "Bearer " (issued :token))}}))
  (assert (= 200 (with-token :status)))
  (assert (= "service:billing" (test/text with-token)))

  (def wrong (test/inject c {:uri "/api/me"
                             :headers {"authorization" "Bearer vt_0000000000000000.nope"}}))
  (assert (= 401 (wrong :status)))
  (assert (string/find "Bearer" (or (get-in wrong [:headers "www-authenticate"]) ""))
          "and the refusal says how to authenticate — that is what a 401 is for")

  # the route names its strategies, so a session cookie cannot open it
  (def value2 (state/active))
  (assert (deep= [:bearer]
                 (get (http/explain-route "/api/me") :void.auth/strategies
                      (get-in (http/explain-route "/api/me") [:meta :void.auth/strategies])))
          "the route's strategy list is in its metadata")

  (auth/revoke-token (value :tokens) (get-in issued [:record :id]))
  (assert (= 401 ((test/inject c {:uri "/api/me"
                                  :headers {"authorization" (string "Bearer " (issued :token))}})
                  :status))
          "a revoked token stops working immediately — it is a store lookup, not a signature"))

# -- JWT -----------------------------------------------------------------

(test/with-http [c {:plugins plugins :only only
                    :config (config {:auth-http {:jwt {:key "test-secret"
                                                       :issuer "void-test"}}})}]
  (def good (auth/encode-jwt {:sub "user:7"} {:key "test-secret" :ttl 60 :issuer "void-test"}))
  (assert (= "user:7" (test/text (test/inject c {:uri "/me"
                                                 :headers {"authorization" (string "Bearer " good)}}))))

  (def wrong-issuer (auth/encode-jwt {:sub "user:7"} {:key "test-secret" :ttl 60 :issuer "elsewhere"}))
  (assert (= 401 ((test/inject c {:uri "/me" :headers {"authorization" (string "Bearer " wrong-issuer)}}) :status)))

  (def expired (auth/encode-jwt {:sub "user:7"} {:key "test-secret" :ttl 60
                                                 :now (- (os/time) 600)}))
  (assert (= 401 ((test/inject c {:uri "/me" :headers {"authorization" (string "Bearer " expired)}}) :status)))

  (def other-key (auth/encode-jwt {:sub "user:7"} {:key "not-the-secret" :ttl 60 :issuer "void-test"}))
  (assert (= 401 ((test/inject c {:uri "/me" :headers {"authorization" (string "Bearer " other-key)}}) :status))))

# -- redirect instead of 401 --------------------------------------------

(test/with-http [c {:plugins plugins :only only
                    :config (config {:auth-http {:unauthenticated :redirect
                                                 :login-path "/sign-in"}})}]
  (def r (test/inject c {:uri "/me"}))
  (assert (= 302 (r :status)) "a browser application redirects instead of answering 401")
  (def location (get-in r [:headers "location"]))
  (assert (string/has-prefix? "/sign-in?next=" location) location)
  (assert (string/find "%2Fme" location)
          "and the redirect carries where the visitor was going, url-encoded"))

(print "http-test ok")
