# void/oauth end to end: a fake authorization server on a socket of
# its own (the auth suite's arrangement), the composition booted the
# way an application boots it, and the flow driven through test/inject
# — the browser's two requests, with the browser's leg (the redirect
# to the issuer) simulated by handing the fake AS what the Location
# header carries.
#
# The id_token is signed with the throwaway keys of
# crypto/test-support, whose public halves the fake issuer publishes as
# its JWKS — same algorithms, same kid, same claims a real issuer would
# mint.

(import ../test-support/paths)
(import ../../crypto/test-support/keys :as keys)
(import ../../auth/test-support/jwks :as fixture)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/server :as server)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import void/http/wire :as wire)
(import void/auth :as auth)
(import void/auth/identity :as identity)
(import void/auth/jwt :as jwt)
(import void/crypto :as crypto)
(import void/crypto/sign :as sign)
(import void/oauth :as oauth)
(import void/oauth/pkce :as pkce)
(import spork/json)
(require "void/http/init")
(require "void/crypto/init")
(require "void/auth/init")
(require "void/auth/http")
(require "void/oauth/init")

(log/set-level! "void" :error)

(crypto/load!)
(def rsa-key (sign/private-key keys/rsa-private))

# -- the authorization server, on a socket of its own --------------------

(def codes
  "What the fake issuer has authorized: code -> what the exchange must
  present and what the id_token will say."
  @{})

(defn- mint-code!
  "Authorize a code the way the real issuer's /authorize would — the
  leg the browser walks, taken from the parsed Location query."
  [name q &opt opts]
  (default opts {})
  (def code (string "code-" (inc (length codes))))
  (put codes code (merge {:challenge (q "code_challenge")
                          :redirect-uri (q "redirect_uri")
                          :client (q "client_id")
                          :nonce (q "nonce")}
                         opts))
  code)

(defn- id-token-for [grant issuer]
  (jwt/encode-token (merge {:sub "idp-user:7" :email "person@idp.test"}
                           (if-let [n (get grant :nonce)]
                             {:nonce (if (grant :wrong-nonce) "somebody-elses" n)}
                             {})
                           (get grant :claims {}))
                    {:alg :rs256 :key rsa-key :kid "rsa-1"
                     :issuer issuer :audience (grant :client) :ttl 300}))

(defn- token-answer [req issuer]
  (def form (or (wire/parse-query (string (or (req :body) ""))) @{}))
  (case (get form "grant_type")
    "refresh_token"
    (if (= "refresh-1" (get form "refresh_token"))
      (ring/response 200 (json/encode {:access_token "at-refreshed"
                                       :token_type "Bearer" :expires_in 3600
                                       :refresh_token "refresh-2"})
                     @{"content-type" "application/json"})
      (ring/response 400 (json/encode {:error "invalid_grant"})
                     @{"content-type" "application/json"}))

    "authorization_code"
    (let [grant (get codes (get form "code"))]
      (cond
        (nil? grant)
        (ring/response 400 (json/encode {:error "invalid_grant"})
                       @{"content-type" "application/json"})

        # the issuer's own PKCE check: S256 of the presented verifier
        # must be the challenge the authorization request carried
        (not (and (= (grant :challenge) (pkce/challenge (get form "code_verifier" "")))
                  (= (grant :redirect-uri) (get form "redirect_uri"))))
        (ring/response 400 (json/encode {:error "invalid_grant"})
                       @{"content-type" "application/json"})

        (ring/response 200
                       (json/encode
                         (merge {:access_token "at-1" :token_type "Bearer"
                                 :expires_in 3600 :refresh_token "refresh-1"}
                                (if (grant :omit-id-token)
                                  {}
                                  (if (grant :nonce)
                                    {:id_token (id-token-for grant issuer)}
                                    {}))))
                       @{"content-type" "application/json"})))

    (ring/response 400 (json/encode {:error "unsupported_grant_type"})
                   @{"content-type" "application/json"})))

(defn- as-handler [req]
  (def issuer (dyn :as-issuer))
  (case (req :path)
    # only the OIDC document: the OAuth one 404s, and discovery's
    # documented fallback is what finds this
    "/.well-known/openid-configuration"
    (ring/response 200
                   (json/encode {:issuer issuer
                                 :authorization_endpoint (string issuer "/authorize")
                                 :token_endpoint (string issuer "/token")
                                 :jwks_uri (string issuer "/jwks")
                                 :userinfo_endpoint (string issuer "/userinfo")})
                   @{"content-type" "application/json"})

    "/jwks"
    (ring/response 200 fixture/json-document @{"content-type" "application/json"})

    "/token" (token-answer req issuer)

    "/userinfo"
    (if (= "Bearer at-1" (ring/request-header req "authorization"))
      (ring/response 200 (json/encode {:sub "plain-user:9" :login "octocat"})
                     @{"content-type" "application/json"})
      (ring/response 401 "no"))

    (ring/not-found)))

(def as (server/start {:handler as-handler :port "0" :idle-timeout 2}))
(def issuer (string "http://127.0.0.1:" (as :port)))
(setdyn :as-issuer issuer)

# -- the application ------------------------------------------------------

(var last-sign-in nil)

(defn- on-sign-in [ctx]
  (set last-sign-in ctx)
  (def claims (ctx :claims))
  (cond
    (= "blocked@idp.test" (get claims :email)) nil
    (identity/make (string (ctx :provider) ":" (get claims :sub))
                   {:via :oauth :cookie true :claims claims})))

(defn whoami [req]
  (ring/text 200 (or (auth/subject) "nobody")))

(def app-routes
  (router/routes {}
    (router/GET "/whoami" 'whoami {:name :whoami})))

(def app
  (plugin/manifest 'test/oauth-app
    :version "0.1.0"
    :requires {:void/oauth ">=0.0.1"}
    :contributes
    {:void.oauth/sign-in [{:name :test/sign-in :fn on-sign-in}]
     :void.http/route-source [{:name :test/oauth-app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]}))

(def modules ["void/http/init" "void/crypto/init" "void/auth/init" "void/auth/http"
              "void/oauth/init"])

(defn- config [oauth-extra]
  {:env @{}
   :cli {:log {:level :error}
         :http {:port 0 :session {:enabled true} :access-log false}
         # the hook signs in a subject the user store never heard of —
         # which is exactly what an OAuth-only application looks like —
         # so the session carries the claims instead of re-reading them
         :auth-http {:session {:load :session}}
         :oauth (merge {:base-url "http://app.test"
                        :timeout 2
                        :refresh-cooldown 0
                        :providers {:acme {:issuer issuer
                                           :client-id "app-1"
                                           :client-secret "shh"
                                           :scopes ["openid" "email"]}
                                    :plain {:authorization-endpoint (string issuer "/authorize")
                                            :token-endpoint (string issuer "/token")
                                            :userinfo-endpoint (string issuer "/userinfo")
                                            :client-id "app-2"
                                            :scopes ["identify"]
                                            :auth :post}}}
                       oauth-extra)}})

# -- the composition, and the gate before it ------------------------------

(def report (plugin/dry-run {:plugins [;modules app] :profile :test :config (config {})}))
(assert (report :ok) "void/oauth composes over http + crypto + auth")
(assert (get-in report [:extensions :void.oauth/sign-in])
        "and owns the sign-in point")

# routes mounted, providers configured, nobody to hand a visitor to —
# a boot error naming the point, not a 500 on the first callback
(def [gate-ok gate-err]
  (protect (test/start! {:plugins modules :profile :test :config (config {})
                         :only [:http/kernel]})))
(assert (not gate-ok) "mounted routes with no :void.oauth/sign-in do not boot")
(assert (string/find ":void.oauth/sign-in" (describe gate-err))
        "and the error names the missing contribution")

(def only [:http/kernel :auth/registry :oauth/providers])

(defn- start-flow
  "GET the start route and hand back the query the browser would carry
  to the issuer."
  [c path]
  (def resp (test/inject c {:uri path}))
  (assert (= 302 (resp :status)) (string path " redirects, got " (resp :status)))
  (def loc (get-in resp [:headers "location"]))
  (wire/parse-query (string/slice loc (inc (string/find "?" loc)))))

(test/with-http [c {:plugins [;modules app] :only only :config (config {})}]

  # -- the routes are ordinary routes -------------------------------------

  (assert (= 404 ((test/inject c {:uri "/oauth/nope"}) :status))
          "an unconfigured provider is a 404, not a stack trace")

  # -- the authorization request ------------------------------------------

  (def q (start-flow c "/oauth/acme?next=/dash"))
  (assert (= "code" (q "response_type")))
  (assert (= "app-1" (q "client_id")))
  (assert (= "http://app.test/oauth/acme/callback" (q "redirect_uri")))
  (assert (= "S256" (q "code_challenge_method")))
  (assert (q "nonce") "openid scope sends a nonce")

  # -- the refusals -------------------------------------------------------

  # a state the pending record never issued
  (def forged (test/inject c {:uri (string "/oauth/acme/callback?code=x&state=forged")}))
  (assert (= 400 (forged :status)) "a forged state is refused")

  # and the record was consumed by that attempt: the *right* state is
  # now worthless too — one shot means one shot
  (def replay (test/inject c {:uri (string "/oauth/acme/callback?code=x&state="
                                           (wire/url-encode (q "state")))}))
  (assert (= 400 (replay :status)) "the pending record is gone after one attempt")

  # the issuer said no
  (def q2 (start-flow c "/oauth/acme"))
  (def denied (test/inject c {:uri (string "/oauth/acme/callback?error=access_denied&state="
                                           (wire/url-encode (q2 "state")))}))
  (assert (= 502 (denied :status)) "the issuer's refusal is a refusal, with its code in the log")

  # a code the issuer never authorized
  (def q3 (start-flow c "/oauth/acme"))
  (def bad-code (test/inject c {:uri (string "/oauth/acme/callback?code=never&state="
                                             (wire/url-encode (q3 "state")))}))
  (assert (= 502 (bad-code :status)) "a failed exchange is a 502, not a sign-in")

  # openid was asked for and no id_token came back
  (def q4 (start-flow c "/oauth/acme"))
  (def no-idt (test/inject c {:uri (string "/oauth/acme/callback?state="
                                           (wire/url-encode (q4 "state"))
                                           "&code=" (mint-code! :acme q4 {:omit-id-token true}))}))
  (assert (= 502 (no-idt :status)) "openid scope and no id_token is a refusal, not a shrug")

  # an id_token echoing somebody else's nonce — a replay
  (def q5 (start-flow c "/oauth/acme"))
  (def replayed (test/inject c {:uri (string "/oauth/acme/callback?state="
                                             (wire/url-encode (q5 "state"))
                                             "&code=" (mint-code! :acme q5 {:wrong-nonce true}))}))
  (assert (= 502 (replayed :status)) "an id_token that does not echo this flow's nonce is refused")

  # the application said no
  (def q6 (start-flow c "/oauth/acme"))
  (def blocked (test/inject c {:uri (string "/oauth/acme/callback?state="
                                            (wire/url-encode (q6 "state"))
                                            "&code=" (mint-code! :acme q6
                                                                 {:claims {:email "blocked@idp.test"}}))}))
  (assert (= 403 (blocked :status)) "nil from the sign-in hook is a 403 — the application decides")
  (assert (= "nobody" (test/text (test/inject c {:uri "/whoami"})))
          "and nobody was signed in")

  # -- the flow that works ------------------------------------------------

  (def q7 (start-flow c "/oauth/acme?next=/dash"))
  (def anon-cookie (get (c :cookies) "void-session"))
  (def done (test/inject c {:uri (string "/oauth/acme/callback?state="
                                         (wire/url-encode (q7 "state"))
                                         "&code=" (mint-code! :acme q7))}))
  (assert (= 302 (done :status)) (test/text done))
  (assert (= "/dash" (get-in done [:headers "location"]))
          "a local ?next= is honoured after the sign-in")
  (assert (not= anon-cookie (get (c :cookies) "void-session"))
          "and the session id was rotated by login! — fixation has no other fix")

  (assert (= "acme:idp-user:7" (test/text (test/inject c {:uri "/whoami"})))
          "the identity the hook returned is signed into the session")

  (assert (= "acme" (string (last-sign-in :provider))))
  (assert (= "person@idp.test" (get-in last-sign-in [:claims :email]))
          "the hook saw the id_token's claims")
  (assert (= "refresh-1" (get-in last-sign-in [:tokens :refresh-token]))
          "and the tokens — storing a refresh token is the application's column, not this package's")

  # a ?next= that leaves the application is not honoured
  (def q8 (start-flow c "/oauth/acme?next=//evil.example/phish"))
  (def landed (test/inject c {:uri (string "/oauth/acme/callback?state="
                                           (wire/url-encode (q8 "state"))
                                           "&code=" (mint-code! :acme q8))}))
  (assert (= "/" (get-in landed [:headers "location"]))
          "a scheme-relative ?next= falls back to [:oauth :after-sign-in]")

  # -- a provider without OIDC --------------------------------------------

  (def q9 (start-flow c "/oauth/plain"))
  (assert (nil? (q9 "nonce")) "no openid, no nonce")
  (assert (= "identify" (q9 "scope")))
  (def plain-done (test/inject c {:uri (string "/oauth/plain/callback?state="
                                               (wire/url-encode (q9 "state"))
                                               "&code=" (mint-code! :plain q9))}))
  (assert (= 302 (plain-done :status)) (test/text plain-done))
  (assert (= "plain:plain-user:9" (test/text (test/inject c {:uri "/whoami"})))
          "no id_token: the claims came from userinfo, and the hook never knew the difference")

  # -- the refresh the application runs later -----------------------------

  (def p (oauth/resolve-provider :acme))
  (def refreshed (oauth/refresh! p "refresh-1"))
  (assert (refreshed :ok) (string (refreshed :reason)))
  (assert (= "at-refreshed" (get-in refreshed [:tokens :access-token])))
  (assert (= "refresh-2" (get-in refreshed [:tokens :refresh-token]))
          "a rotated refresh token comes back as data — keeping it is the caller's business")

  (def stale (oauth/refresh! p "refresh-0"))
  (assert (not (stale :ok)) "a revoked refresh token is a refusal")
  (assert (string/find "invalid_grant" (stale :reason))
          "with the issuer's code in the reason, for the log"))

(server/stop as)
(print "plugin-test ok")
