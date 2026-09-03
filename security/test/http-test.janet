# void/security end to end over test/inject: headers on the responses no
# route produced, the CSRF rule that follows the credential rather than
# the method, a CORS preflight to a path with no route, and a rate limit
# that answers 429 with the headers a client can obey.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/security :as security)
(import void/security/csrf :as csrf)
(require "void/crypto/init")

(log/set-level! "void" :error)

# -- the application -----------------------------------------------------

(defn home [req] (ring/text 200 "home"))
(defn boom [req] (error "handler blew up"))

(defn form-page [req]
  # a real page has a session by the time it shows a form; CSRF only
  # applies to a credential that rode on a cookie, so a page with no
  # session at all is not the interesting case
  (put (req :session) :seen true)
  # the slot void/html renders through: bound only while this plugin is
  # in the composition
  (def slot (dyn :void.html/csrf))
  (ring/text 200 (if slot (string/format "%q" (slot)) "no slot")))

(defn accept [req] (ring/text 200 "accepted"))

(def app-routes
  (router/routes {}
    (router/GET "/" 'home {:name :home})
    (router/GET "/form" 'form-page {:name :form})
    (router/GET "/boom" 'boom {:name :boom})
    (router/POST "/submit" 'accept {:name :submit})
    (router/POST "/api/hook" 'accept {:name :hook})
    (router/POST "/api/always" 'accept {:name :always :void.security/csrf true})
    (router/POST "/login" 'accept {:name :login
                                   :void.security/rate {:limit 2 :window 60}})))

(def app
  (plugin/manifest 'test/security-app
    :version "0.1.0"
    :requires {:void/security ">=0.0.1"}
    :contributes {:void.http/route-source [{:name :test/security-app :routes app-routes
                                            :env (router/env-ref (curenv))}]}))

(def plugins ["void/http/init" "void/crypto/init" "void/security/init" app])

(defn- config [extra]
  {:env @{}
   :cli (merge-into
          @{:log {:level :error}
            :http {:port 0 :session {:enabled true} :access-log false}
            :security {:signing-key (string/repeat "k" 32)}}
          extra)})

# `with-http` starts the kernel and its dependencies; the crypto component
# is not one of them, and every CSRF token is signed — so the subset has
# to name it, the way a real boot starts everything
(def only [:http/kernel :crypto/lib])

# -- the composition -----------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok))
(assert (= 2 (get-in report [:extensions :void.http/edge :contributions]))
        "the headers and the CORS wrapper live at the edge, not in a route chain")

# a route may tighten CSRF and never loosen it (:restrict, true wins)
(def loosened
  (router/routes {:void.security/csrf true}
    (router/POST "/oops" 'accept {:name :oops :void.security/csrf false})))
(def loosen-app
  (plugin/manifest 'test/loosen :version "0.1.0" :requires {:void/security ">=0.0.1"}
    :contributes {:void.http/route-source [{:name :test/loosen :routes loosened
                                            :env (router/env-ref (curenv))}]}))
(def [ok] (protect (test/start! {:plugins ["void/http/init" "void/crypto/init"
                                           "void/security/init" loosen-app]
                                 :only only :profile :test :config (config {})})))
(assert (not ok) "a route inside a CSRF-protected group cannot switch the protection off")

# and a route may only lower the rate it inherits
(def raised
  (router/routes {:void.security/rate {:limit 10 :window 60}}
    (router/POST "/faster" 'accept {:name :faster :void.security/rate {:limit 1000 :window 60}})))
(def raise-app
  (plugin/manifest 'test/raise :version "0.1.0" :requires {:void/security ">=0.0.1"}
    :contributes {:void.http/route-source [{:name :test/raise :routes raised
                                            :env (router/env-ref (curenv))}]}))
(def [ok2] (protect (test/start! {:plugins ["void/http/init" "void/crypto/init"
                                            "void/security/init" raise-app]
                                  :only only :profile :test
                                  :config (config {:security {:signing-key (string/repeat "k" 32)
                                                              :rate {:enabled true}}})})))
(assert (not ok2) "and a route cannot raise a rate its group set")

# -- headers, everywhere -------------------------------------------------

(test/with-http [c {:plugins plugins :only only :config (config {})}]
  (def ok-resp (test/inject c {:uri "/"}))
  (assert (= "nosniff" (get-in ok-resp [:headers "x-content-type-options"])))
  (assert (string/find "default-src 'self'" (get-in ok-resp [:headers "content-security-policy"])))

  (def missing (test/inject c {:uri "/nowhere"}))
  (assert (= 404 (missing :status)))
  (assert (= "nosniff" (get-in missing [:headers "x-content-type-options"]))
          "a 404 is produced outside every route chain, and still carries the headers")

  (def blown (test/inject c {:uri "/boom"}))
  (assert (= 500 (blown :status)))
  (assert (= "DENY" (get-in blown [:headers "x-frame-options"]))
          "and so does a 500 the panic guard rendered")
  (assert (get-in blown [:headers "content-security-policy"])))

# report-only, and a nonce only when the policy asks for one
(test/with-http [c {:plugins plugins :only only
                    :config (config {:security {:signing-key (string/repeat "k" 32)
                                                :csp {:report-only true
                                                      :policy {:default-src [:self]
                                                               :script-src [:self :nonce]}}}})}]
  (def r (test/inject c {:uri "/"}))
  (assert (nil? (get-in r [:headers "content-security-policy"])))
  (def policy (get-in r [:headers "content-security-policy-report-only"]))
  (assert policy "report-only is how a CSP gets adopted without breaking the page")
  (assert (string/find "'nonce-" policy) "and the nonce reached the header")
  (def again (get-in (test/inject c {:uri "/"}) [:headers "content-security-policy-report-only"]))
  (assert (not= policy again) "a fresh nonce per request, or it is not a nonce"))

# -- CSRF ----------------------------------------------------------------

(test/with-http [c {:plugins plugins :only only :config (config {})}]

  # a page renders the hidden field through the slot void/html waits with
  (def page (test/inject c {:uri "/form"}))
  (def body (test/text page))
  (assert (string/find "_csrf" body) body)
  (assert (get-in page [:headers "set-cookie"])
          "and the browser is given something to bind the token to")

  (def token
    (let [m (peg/match '(* (thru `:value "`) (<- (to `"`))) body)]
      (first m)))
  (assert token body)

  # the jar now carries the CSRF cookie, so the request is cookie-borne
  (def without (test/inject c {:method :post :uri "/submit" :form {:x "1"}}))
  (assert (= 403 (without :status)) "a cookie-borne POST without a token is refused")

  (def with-field (test/inject c {:method :post :uri "/submit"
                                  :form {:x "1" :_csrf token}}))
  (assert (= 200 (with-field :status)) (test/text with-field))

  (def with-header (test/inject c {:method :post :uri "/submit"
                                   :form {:x "1"}
                                   :headers {"x-csrf-token" token}}))
  (assert (= 200 (with-header :status)) "the header is what htmx and fetch() send")

  (def forged (test/inject c {:method :post :uri "/submit"
                              :form {:x "1" :_csrf (string token "x")}}))
  (assert (= 403 (forged :status))))

# a client that carries no cookie at all is not subject to CSRF
(test/with-http [c {:plugins plugins :only only :config (config {})}]
  (assert (= 200 ((test/inject c {:method :post :uri "/api/hook" :json {:event "x"}}) :status))
          "an API call with no cookie cannot be forged by another origin — demanding a token there breaks every JSON client")
  (assert (= 403 ((test/inject c {:method :post :uri "/api/always" :json {:event "x"}}) :status))
          "unless the route says :void.security/csrf true, which is the tightening the frozen merge allows"))

# -- CORS ----------------------------------------------------------------

(test/with-http [c {:plugins plugins :only only
                    :config (config {:security {:signing-key (string/repeat "k" 32)
                                                :cors {:enabled true
                                                       :origins ["https://app.example"]}}})}]
  (def pre (test/inject c {:method :options :uri "/no-such-route"
                           :headers {"origin" "https://app.example"
                                     "access-control-request-method" "POST"}}))
  (assert (= 204 (pre :status))
          "a preflight is answered for a path that has no OPTIONS route — which is why this lives at the edge")
  (assert (= "https://app.example" (get-in pre [:headers "access-control-allow-origin"])))

  (def denied (test/inject c {:method :options :uri "/submit"
                              :headers {"origin" "https://evil.example"
                                        "access-control-request-method" "POST"}}))
  (assert (= 403 (denied :status)))

  (def normal (test/inject c {:uri "/" :headers {"origin" "https://app.example"}}))
  (assert (= 200 (normal :status)))
  (assert (= "https://app.example" (get-in normal [:headers "access-control-allow-origin"])))
  (assert (string/find "Origin" (get-in normal [:headers "vary"]))))

# -- rate limiting -------------------------------------------------------

(test/with-http [c {:plugins plugins :only only
                    :config (config {:security {:signing-key (string/repeat "k" 32)
                                                :rate {:enabled true :store :memory}}})}]
  (def first-try (test/inject c {:method :post :uri "/login" :json {}}))
  (assert (= 200 (first-try :status)))
  (assert (= "2" (get-in first-try [:headers "ratelimit-limit"]))
          "an allowed request is told what its budget is")
  (assert (= "1" (get-in first-try [:headers "ratelimit-remaining"])))

  (test/inject c {:method :post :uri "/login" :json {}})
  (def refused (test/inject c {:method :post :uri "/login" :json {}}))
  (assert (= 429 (refused :status)) "the third is over the route's limit of two")
  (assert (get-in refused [:headers "retry-after"])
          "and is told how long to wait, which is the only part of a 429 a client obeys")
  (assert (= "0" (get-in refused [:headers "ratelimit-remaining"])))

  (assert (= 200 ((test/inject c {:uri "/"}) :status))
          "while a route with no limit of its own is untouched — no global limit is configured"))

# -- one session-cookie name, not two ------------------------------------
#
# [:http :session :cookie] names the cookie; [:security :csrf
# :session-cookie] tells the CSRF rule what to look for. The boot hook
# keeps them one value: unset, the CSRF side follows http's; set to
# something else, the boot refuses — the disagreement's only observable
# effect would be CSRF silently not applying to session-bearing flows.

(test/with-http [c {:plugins plugins :only only
                    :config (config {:http {:port 0 :access-log false
                                            :session {:enabled true :cookie "acme-session"}}})}]
  (assert (= "acme-session" (get-in security/settings [:csrf :session-cookie]))
          "a renamed session cookie is followed by the CSRF rule without a second setting"))

(def [ok-mismatch err-mismatch]
  (protect (test/start! {:plugins plugins :profile :test :only only
                         :config (config {:security {:signing-key (string/repeat "k" 32)
                                                     :csrf {:session-cookie "legacy-name"}}})})))
(assert (not ok-mismatch) "a csrf session-cookie that disagrees with http's does not boot")
(assert (string/find "session-cookie" (string err-mismatch)) (string err-mismatch))

(print "http-test ok")
