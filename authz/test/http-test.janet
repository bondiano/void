# void/authz-http over test/inject (ADR-0017): group and route policies
# both enforced, the resource a route names, a 403 that says nothing,
# deny-by-default as a boot error, and the seam that lets authz read
# void/auth's identity without importing the package.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/authz :as authz)
(import void/authz/http :as authz-http)
(import void/authz/context :as context)
(import void/auth :as auth)
(import void/auth/http :as auth-http)
(import void/auth/hash :as hash)
(import void/crypto :as crypto)
(import void/crypto/kdf :as kdf)
(require "void/crypto/init")
(require "void/auth/init")
(require "void/authz/init")

(log/set-level! "void" :error)

# -- the policies --------------------------------------------------------

(def orders
  @{1 {:id 1 :brand-id 3 :owner "user:1"}
    2 {:id 2 :brand-id 9 :owner "user:2"}})

(authz/defpolicy :orders/read
  "An order is visible inside its own brand."
  [ctx]
  (or (= (authz/attr ctx :subject/brand-id) (authz/attr ctx :resource/brand-id))
      "brand mismatch"))

(authz/defpolicy :staff
  "Anybody with a role at all."
  [ctx]
  (or (authz/attr ctx :subject/role) "not staff"))

# -- the application -----------------------------------------------------

(defn who [req] (ring/text 200 (or (auth/subject) "nobody")))
(defn show-order [req]
  (ring/text 200 (string "order " (get-in req [:params :id]))))
(defn login [req]
  (def result (auth/check-password (auth/user-store) (req :form)))
  (if-let [id (result :identity)]
    (do (auth-http/login! req id) (ring/text 200 "in"))
    (ring/text 401 "no")))

(defn order-of [req]
  (get orders (scan-number (get-in req [:params :id] "0"))))

(def app-routes
  (router/routes {}
    (router/GET "/public" 'who {:name :public :void.authz/policy :public})
    (router/GET "/open" 'who {:name :open})
    (router/POST "/login" 'login {:name :login :void.authz/policy :public})
    (router/GET "/orders/:id" 'show-order
                {:name :orders/show
                 :void.auth/access :required
                 :void.authz/policy :orders/read
                 :void.authz/resource order-of})
    (router/GET "/staff" 'who {:name :staff
                               :void.auth/access :required
                               :void.authz/policy :staff})))

(def guarded
  (router/routes {:void.authz/policy :staff}
    (router/GET "/admin/reports" 'who {:name :admin/reports
                                       :void.auth/access :required
                                       :void.authz/policy :orders/read})))

(def app
  (plugin/manifest 'test/authz-app
    :version "0.1.0"
    :requires {:void/authz-http ">=0.0.1" :void/auth-http ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/authz-app :routes app-routes
                               :env (router/env-ref (curenv))}
                              {:name :test/guarded :routes guarded
                               :env (router/env-ref (curenv))}]}))

(def plugins ["void/http/init" "void/crypto/init" "void/auth/init" "void/auth/http"
              "void/authz/init" "void/authz/http" app])

(crypto/load!)
(set kdf/in-thread false)
(set hash/settings {:hasher :scrypt :scrypt {:ln 10 :r 8 :p 1 :length 32 :salt-bytes 16}})
(def pw (hash/hash "hunter2"))

(defn- config [extra]
  {:env @{}
   :cli (merge {:log {:level :error}
                :http {:port 0 :session {:enabled true} :access-log false}
                :crypto {:kdf {:in-thread false}}
                :auth {:scrypt {:ln 10}
                       :users {"user:1" {:email "one@b.c" :password-hash pw
                                         :claims {:brand-id 3 :role :manager}}
                               "user:2" {:email "two@b.c" :password-hash pw
                                         :claims {:brand-id 9}}}}}
               extra)})

(def only [:http/kernel :auth/registry :authz/registry])

# -- the composition -----------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok))
(assert (get-in report [:extensions :void.authz/provider]) "the provider point is owned by void/authz")

# -- enforcement ---------------------------------------------------------

(test/with-http [c {:plugins plugins :only only :config (config {})}]

  (assert (index-of :void.authz/enforce ((http/explain-route "/orders/1") :middleware))
          "a route with a policy has the enforcer in its chain")
  (assert (index-of :void.authz/enforce ((http/explain-route "/public") :middleware))
          ":public is a policy like any other, so it is evaluated like one")
  (assert (not (index-of :void.authz/enforce ((http/explain-route "/open") :middleware)))
          "a route with no policy has no wrapper at all — the :when predicate runs once, at table-build time, so an unguarded route costs nothing on the hot path")

  # anonymous: auth refuses before authz is reached
  (assert (= 401 ((test/inject c {:uri "/orders/1"}) :status)))
  (assert (= 200 ((test/inject c {:uri "/public"}) :status)))

  # user:1 is in brand 3
  (assert (= 200 ((test/inject c {:method :post :uri "/login"
                                  :form {:email "one@b.c" :password "hunter2"}})
                  :status)))
  (assert (= "user:1" (test/text (test/inject c {:uri "/public"}))))

  (def mine (test/inject c {:uri "/orders/1"}))
  (assert (= 200 (mine :status)) "an order of the subject's own brand is visible")
  (assert (= "order 1" (test/text mine)))

  (def theirs (test/inject c {:uri "/orders/2"}))
  (assert (= 403 (theirs :status)) "an order of another brand is not")
  (assert (not (string/find "brand mismatch" (string (theirs :body))))
          "and the body does not say why — the reason is a description of internal state (ADR-0024 §3)")

  # group AND route: :staff from the group, :orders/read from the route
  (def group-route (http/explain-route "/admin/reports"))
  (assert (deep= [:staff :orders/read]
                 (tuple ;(get-in group-route [:meta :void.authz/policy])))
          "the group's policy and the route's are concatenated, not replaced")
  (assert (= 403 ((test/inject c {:uri "/admin/reports"}) :status))
          "and both must allow: user:1 is staff, but the report has no brand to match")

  (assert (= 200 ((test/inject c {:uri "/staff"}) :status)))

  # the decision log sees what enforcement decided
  (def decisions @[])
  (authz/listen! :test/spy (fn [d] (array/push decisions d)))
  (test/inject c {:uri "/orders/2"})
  (authz/unlisten! :test/spy)
  (assert (= 1 (length decisions)))
  (assert (not ((decisions 0) :allow)))
  (assert (= "user:1" ((decisions 0) :subject)))
  (assert (= :orders/read ((decisions 0) :policy)))
  (assert (= :orders/show ((decisions 0) :action)) "the route name is the action")

  # user:2 sees the other order and not the first
  (test/inject c {:method :post :uri "/login" :form {:email "two@b.c" :password "hunter2"}})
  (assert (= 200 ((test/inject c {:uri "/orders/2"}) :status)))
  (assert (= 403 ((test/inject c {:uri "/orders/1"}) :status)))
  (assert (= 403 ((test/inject c {:uri "/staff"}) :status))
          "user:2 has no role at all, so :staff refuses — with a reason nobody outside sees")

  # `void authz routes`
  (def printed @"")
  (with-dyns [*out* printed] (authz-http/print-routes))
  (def text (string printed))
  (assert (string/find "orders/show" text))
  (assert (string/find "orders/read" text))
  (assert (string/find "staff orders/read" text) "a route shows every policy that guards it"))

# -- authz without void/auth ---------------------------------------------
#
# The identity is a dyn key, not an import (ADR-0024): an application
# with its own authentication binds :void.auth/identity and gets the
# same authorization. Here nothing from void/auth is in the composition
# at all.

(def own-auth
  (plugin/manifest 'test/own-auth
    :version "0.1.0"
    :requires {:void/http ">=0.0.1"}
    :contributes
    {:void.http/middleware
     [{:name :test/own-identity
       :phase 4000
       :wrap (fn [handler]
               (fn [req]
                 (with-dyns [context/identity-dyn
                             {:subject "svc:reporting" :claims {:role :manager :brand-id 3}}]
                   (handler req))))}]}))

(def bare-routes
  (router/routes {}
    (router/GET "/report" 'who {:name :report :void.authz/policy :orders/read})))

(def bare-app
  (plugin/manifest 'test/bare
    :version "0.1.0"
    :requires {:void/authz-http ">=0.0.1"}
    :contributes {:void.http/route-source [{:name :test/bare :routes bare-routes
                                            :env (router/env-ref (curenv))}]}))

(test/with-http [c {:plugins ["void/http/init" "void/authz/init" "void/authz/http"
                              own-auth bare-app]
                    :only [:http/kernel :authz/registry]
                    :config {:env @{} :cli {:log {:level :error}
                                            :http {:port 0 :access-log false}}}}]
  (def seen @[])
  (authz/listen! :test/foreign (fn [d] (array/push seen d)))
  # the resource has no brand, so :orders/read compares 3 with nil
  (assert (= 403 ((test/inject c {:uri "/report"}) :status)))
  (authz/unlisten! :test/foreign)
  (assert (= 1 (length seen)))
  (assert (= "svc:reporting" ((seen 0) :subject))
          "and the subject authz decided about came from the dyn a foreign middleware bound — no void/auth anywhere in this composition"))

# -- deny by default -----------------------------------------------------

(def unguarded-routes
  (router/routes {}
    (router/GET "/guarded" 'who {:name :guarded :void.authz/policy :public})
    (router/GET "/forgotten" 'who {:name :forgotten})))

(def forgetful
  (plugin/manifest 'test/forgetful
    :version "0.1.0"
    :requires {:void/authz-http ">=0.0.1"}
    :contributes {:void.http/route-source [{:name :test/forgetful :routes unguarded-routes
                                            :env (router/env-ref (curenv))}]}))

(def [ok err]
  # test/start! rather than plugin/start!: the subset is what keeps this
  # from opening a socket, and :only is its option, not the kernel's
  (protect (test/start! {:plugins ["void/http/init" "void/authz/init" "void/authz/http" forgetful]
                         :only [:http/kernel :authz/registry]
                         :profile :test
                         :config {:env @{} :cli {:log {:level :error}
                                                 :http {:port 0 :access-log false}
                                                 :authz {:default :deny}}}})))
(assert (not ok) "under :default :deny a route without a policy stops the boot")
(assert (string/find "forgotten" (string err)) "and the error names it")
(assert (not (string/find "guarded" (string err))) "while a route that says {:void.authz/policy :public} is fine")

(print "http-test ok")
