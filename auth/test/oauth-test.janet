### void/auth-oauth: the resource-server half of OAuth, against an
### authorization server that is a real socket — discovery, JWKS,
### introspection and the refusals, which are the point.
###
### The tokens are signed here with the private keys of
### test-support/keys, so what the suite verifies is what a real issuer
### would have minted: same algorithms, same `kid`, same claims.

(import ../test-support/paths)
(import ../test-support/jwks :as fixture)
# the same throwaway pairs void/crypto's signature suite uses, and the
# JWKS fixture beside it publishes their public halves
(import ../../crypto/test-support/keys :as keys)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/server :as server)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import void/http/wire :as wire)
(import void/auth/jwt :as jwt)
(import void/auth/oauth :as oauth)
(import void/crypto :as crypto)
(import void/crypto/sign :as sign)
(require "void/http/init")
(require "void/auth/init")
(require "void/auth/http")
(require "void/auth/oauth")
(import spork/json)

(log/set-level! "void" :error)

(def jwks-document fixture/json-document)

# -- the authorization server, on a socket of its own --------------------

(def calls @{:metadata 0 :jwks 0 :introspect 0})
(var introspection-answer nil)

(defn- as-handler [req]
  (case (req :path)
    "/.well-known/oauth-authorization-server"
    (do (put calls :metadata (inc (calls :metadata)))
        (ring/response 200
                       (json/encode {:issuer (dyn :as-issuer)
                                     :jwks_uri (string (dyn :as-issuer) "/jwks")
                                     :introspection_endpoint (string (dyn :as-issuer) "/introspect")})
                       @{"content-type" "application/json"}))

    "/jwks"
    (do (put calls :jwks (inc (calls :jwks)))
        (ring/response 200 jwks-document @{"content-type" "application/json"}))

    "/introspect"
    (do (put calls :introspect (inc (calls :introspect)))
        # a form body's keys are strings, the way they arrived
        (def form (or (wire/parse-query (string (or (req :body) ""))) @{}))
        (ring/response 200
                       (json/encode (introspection-answer (get form "token" "")
                                                          (ring/request-header req "authorization")))
                       @{"content-type" "application/json"}))

    (ring/not-found)))

(def as (server/start {:handler as-handler :port "0" :idle-timeout 2}))
(def issuer (string "http://127.0.0.1:" (as :port)))
(setdyn :as-issuer issuer)

(def resource "https://api.example.test/mcp")

(set introspection-answer
     (fn [token _auth]
       (case token
         "opaque-good" {:active true :sub "user:7" :aud resource :iss issuer
                        :scope "mcp:tools mcp:resources" :exp (+ (os/time) 300)}
         "opaque-elsewhere" {:active true :sub "user:7" :aud "https://other.example/api"
                             :iss issuer :exp (+ (os/time) 300)}
         # RFC 7662 makes both claims optional, and a server that
         # omits them is the common case the refusals below exist for
         "opaque-no-aud" {:active true :sub "user:7" :iss issuer :exp (+ (os/time) 300)}
         "opaque-no-iss" {:active true :sub "user:7" :aud resource :exp (+ (os/time) 300)}
         {:active false})))

# -- tokens --------------------------------------------------------------

# the keys are opened before the composition starts, so libcrypto is
# opened by hand here — `void/crypto`'s component does it for the
# application
(crypto/load!)
(def rsa-key (sign/private-key keys/rsa-private))
(def ec-key (sign/private-key keys/ec-private))

(defn- token-for [&opt claims opts]
  (default claims {})
  (default opts {})
  (jwt/encode-token (merge {:scope "mcp:tools"} claims)
                    (merge {:alg :rs256 :key rsa-key :kid "rsa-1"
                            :subject "user:42"
                            :issuer issuer
                            :audience resource
                            :ttl 300}
                           opts)))

# -- the composition -----------------------------------------------------

(defn- oauth-config [extra]
  (merge {:issuer issuer :audience resource :timeout 2 :refresh-cooldown 0}
         extra))

(defn- options [&opt oauth-extra routes]
  {:plugins (filter identity
              [:void/http :void/crypto :void/auth :void/auth-http :void/auth-oauth routes])
   :config {:env @{}
            :cli {:log {:level :error}
                  :http {:port 0}
                  :auth-oauth (oauth-config (or oauth-extra {}))}}})

(def boot
  (test/start! (merge (options) {:only [:auth.oauth/keys]})))
(def ring-state (get-in boot [:system :instances :auth.oauth/keys]))

# -- discovery and keys --------------------------------------------------

(def metadata (oauth/discover ring-state))
(assert (= (string issuer "/jwks") (metadata :jwks_uri))
        "the issuer's metadata is discovered (RFC 8414)")
(assert (= 1 (calls :metadata)) "and fetched once")
(oauth/discover ring-state)
(assert (= 1 (calls :metadata)) "— an issuer's endpoints do not move, so it is cached")

# -- a token that is ours ------------------------------------------------

(def ok (oauth/verify (token-for)))
(assert (ok :ok) "a token from the configured issuer, for this resource, verifies")
(assert (= "user:42" (get-in ok [:claims :sub])) "and carries its subject")
(assert (>= (calls :jwks) 1) "the keys were fetched on the way")

(def before (calls :jwks))
(assert ((oauth/verify (token-for)) :ok) "a second token verifies")
(assert (= before (calls :jwks)) "off the cached keys — no network on the hot path")

(assert ((oauth/verify (token-for {} {:alg :es256 :key ec-key :kid "ec-1"})) :ok)
        "the set's other key works too, on its own algorithm")

# -- the refusals that matter --------------------------------------------
#
# The first one is the reason this plugin exists: a token minted by the
# same issuer, for somebody else, must not open this door (RFC 8707,
# RFC 9700 — the confused deputy MCP's authorization spec calls out).

(def elsewhere (oauth/verify (token-for {} {:audience "https://other.example/api"})))
(assert (not (elsewhere :ok)) "a token issued for another resource is refused")
(assert (string/find "audience" (elsewhere :reason)) "for being for somebody else")

(each [tok why]
  [[(token-for {} {:issuer "https://evil.example"}) "another issuer"]
   [(token-for {} {:ttl -60}) "an expired token"]
   [(token-for {} {:alg :hs256 :key "the-public-key-as-a-secret" :kid "rsa-1"})
    "an HS256 token signed with a shared secret (the classic algorithm substitution)"]
   [(token-for {} {:kid "not-a-key-we-have"}) "a kid nobody published"]
   # the header is written by whoever sent the token: naming the RSA
   # key and an EC algorithm must be a refusal, not a type error
   # inside libcrypto that a 500 comes out of
   [(token-for {} {:alg :es256 :key ec-key :kid "rsa-1"})
    "an EC token pointing at the RSA key"]
   [(token-for {} {:alg :rs256 :key rsa-key :kid "ec-1"})
    "and an RSA token pointing at the EC one"]
   ["ceci.nest.pas" "a token that is not a JWS"]]
  (def out (oauth/verify tok))
  (assert (not (out :ok)) (string why " is refused"))
  (assert (string? (out :reason)) (string why " is refused with a reason for the log")))

# -- from a token to an identity -----------------------------------------

(defn- authenticate [tok]
  ((oauth/strategy :authenticate) @{:headers @{"authorization" (string "Bearer " tok)}}))

(def person (authenticate (token-for)))
(assert (= "user:42" (person :subject)) "a verified token becomes an identity")
(assert (= :oauth (person :via)) "that says how it was established")
(assert (not (person :cookie))
        "and that it was not cookie-borne — void/security asks that before it demands a CSRF token")
(assert (deep= ["mcp:tools"] (oauth/scopes person)) "carrying the scopes of the token")

# a machine-to-machine token has no `sub`: the client *is* the subject,
# which is what client_id is for
(def m2m (jwt/encode-token {:client_id "svc-reports" :scope "mcp:tools"}
                           {:alg :rs256 :key rsa-key :kid "rsa-1"
                            :issuer issuer :audience resource :ttl 300}))
(assert (= "svc-reports" ((authenticate m2m) :subject))
        "a token with no sub is the client that was issued it")

(assert (nil? (authenticate (token-for {} {:audience "https://other.example/api"})))
        "and a token that does not verify is nobody — never an exception on a public endpoint")

(assert (deep= ["a" "b"] (oauth/claim-scopes {:scope "a b"}))
        "scopes are the space-delimited string RFC 6749 defines")
(assert (deep= ["a"] (oauth/claim-scopes {:scp ["a"]}))
        "or the array some issuers send instead")
(assert (deep= [] (oauth/claim-scopes {})) "and a token without any has none")

# -- introspection -------------------------------------------------------

(def opaque (oauth/verify "opaque-good"))
(assert (opaque :ok) "an opaque token is checked with the issuer (RFC 7662)")
(assert (= "user:7" (get-in opaque [:claims :sub])) "and its claims come back")
(assert (pos? (calls :introspect)) "over the introspection endpoint")

(assert (not ((oauth/verify "nope") :ok)) "an inactive token is refused")
(assert (not ((oauth/verify "opaque-elsewhere") :ok))
        "and so is an active one issued for another resource — `active` is not `mine`")

# a server that does not echo the claim does not get a pass: with
# [:auth-oauth :audience] set, an answer without `aud` would make every
# active token of the issuer a token for this resource (the confused
# deputy), and an answer without `iss` the same for a foreign issuer
(def no-aud (oauth/verify "opaque-no-aud"))
(assert (not (no-aud :ok)) "an active token whose introspection carries no aud is refused")
(assert (string/find "audience" (no-aud :reason)))
(def no-iss (oauth/verify "opaque-no-iss"))
(assert (not (no-iss :ok)) "and one whose introspection carries no iss is refused too")
(assert (string/find "issuer" (no-iss :reason)))

# the request that goes out carries the resource server's own
# credentials, and never the user's token in a header somebody else
# might log
(def req (oauth/introspection-request "abc"
                                      (oauth/build-settings
                                        {:config {:values {:auth-oauth
                                                           (oauth-config {:introspection
                                                                          {:client-id "rs"
                                                                           :client-secret "shh"}})}}})
                                      (string issuer "/introspect")))
(assert (= "abc" (get-in req [:form :token])) "the token goes in the form, per RFC 7662")
(assert (string/has-prefix? "Basic " (get-in req [:headers "authorization"]))
        "and the resource server authenticates itself with its own credentials")

# in :jwt mode nothing is asked of the issuer about an opaque token
(def strict (oauth/build-settings
              {:config {:values {:auth-oauth (oauth-config {:mode :jwt})}}}))
(def calls-before (calls :introspect))
(assert (not ((oauth/verify "opaque-good" strict ring-state) :ok))
        "[:auth-oauth :mode] :jwt refuses an opaque token")
(assert (= calls-before (calls :introspect)) "without calling the issuer about it")

# -- what :auto does and does not send to the issuer ---------------------
#
# A JWS whose signature failed is a final answer, and forging one costs
# an attacker nothing — so it must not become an introspection call
# (one outgoing request and one parked fiber per forged token would be
# a DoS lever against the authorization server). A kid this process
# does not know is different: there the issuer genuinely may know
# better, and the fallback stays.

(def auto-cfg (oauth/build-settings
                {:config {:values {:auth-oauth
                                   (oauth-config {:introspection
                                                  {:url (string issuer "/introspect")}})}}}))

(def genuine (token-for))
(def forged-sig (let [parts (string/split "." genuine)]
                  (string (parts 0) "." (parts 1) "." "AAAA")))
(def before-forged (calls :introspect))
(assert (not ((oauth/verify forged-sig auto-cfg ring-state) :ok))
        "a JWS with a broken signature is refused")
(assert (= before-forged (calls :introspect))
        "without asking the issuer about it — a forged JWT is not an opaque token")

(def before-kid (calls :introspect))
(assert (not ((oauth/verify (token-for {} {:kid "rotated-away"}) auto-cfg ring-state) :ok))
        "a kid nobody published is still refused in the end")
(assert (= (inc before-kid) (calls :introspect))
        "but that one *is* worth one introspection call: the issuer may have rotated")

(test/stop! boot)

# -- scopes, challenges and the metadata document ------------------------

(defn tools [req] (ring/text 200 "tools"))
(defn open-page [req] (ring/text 200 "open"))

(def app
  (plugin/manifest 'oauth/app
    :version "0.1.0"
    :requires {:void/auth-oauth ">=0.0.1"}
    :contributes
    {:void.http/route-source
     [{:name :oauth/app
       :routes (router/routes {}
                 (router/GET "/mcp" 'tools
                             {:name :app/tools
                              :void.auth/access :required
                              :void.auth/scopes ["mcp:tools"]})
                 (router/GET "/" 'open-page {:name :app/open}))
       :env (router/env-ref (curenv))}]}))

(test/with-http [c (merge (options {} app)
                          {:only [:http/kernel :crypto/lib :auth/registry :auth.oauth/keys]})]

  # no credential at all: a 401 that says where to get one. That
  # pointer is what an MCP client follows — without it the client knows
  # only that it was refused
  (def anon (test/inject c {:uri "/mcp"}))
  (assert (= 401 (anon :status)) "a protected route without a token is a 401")
  (def challenge (get-in anon [:headers "www-authenticate"]))
  (assert (string/find "Bearer" challenge) "with a Bearer challenge")
  (assert (string/find "resource_metadata=" challenge)
          "carrying the protected-resource metadata URL (RFC 9728 §5.1)")
  (assert (string/find "/.well-known/oauth-protected-resource" challenge)
          "which is the well-known document of this resource")

  # a valid token, and the route opens
  (def in (test/inject c {:uri "/mcp"
                          :headers @{"authorization" (string "Bearer " (token-for))}}))
  (assert (= 200 (in :status)) "a token with the scope gets in")

  # a valid token that may not do this: 403, not 401 — the credential
  # was fine, the grant was not, and a client that retries with the
  # same token learns nothing
  (def narrow (test/inject c {:uri "/mcp"
                              :headers @{"authorization"
                                         (string "Bearer " (token-for {:scope "profile"}))}}))
  (assert (= 403 (narrow :status)) "a token without the scope is forbidden")
  (assert (string/find "insufficient_scope" (get-in narrow [:headers "www-authenticate"]))
          "with the RFC 6750 error code")
  (assert (string/find "mcp:tools" (get-in narrow [:headers "www-authenticate"]))
          "and the scope it was missing")

  # the route that asks for nothing is unaffected: a resource server is
  # not an authentication requirement on everything it serves
  (assert (= 200 ((test/inject c {:uri "/"}) :status)) "an open route stays open")

  # the document itself
  (def doc-resp (test/inject c {:uri "/.well-known/oauth-protected-resource"}))
  (assert (= 200 (doc-resp :status)) "the metadata document is public")
  # not `doc`: that is a core macro, and (doc :resource) would be a
  # documentation lookup rather than a table read
  (def published (test/json doc-resp))
  (assert (= resource (published :resource)) "it names this resource")
  (assert (index-of issuer (published :authorization_servers))
          "and the authorization server to go to")
  (assert (index-of "header" (published :bearer_methods_supported))
          "and how to present the token"))

# -- the boot gates ------------------------------------------------------

(each [slice why]
  [[{:issuer issuer}
    "a resource server with no audience — it would accept a token issued for anybody"]
   [{:audience resource}
    "a resource server with no issuer, no JWKS and no introspection — nothing to check a token with"]
   [{:issuer issuer :audience resource :algs [:hs256]}
    "a resource server that would verify HS256 — a key that verifies is then a key that issues"]
   [{:issuer issuer :audience resource :algs [:nonsense]}
    "an algorithm that is not one"]]
  (def [ok] (protect
              (test/start! {:plugins [:void/http :void/crypto :void/auth
                                      :void/auth-http :void/auth-oauth]
                            :only [:auth.oauth/keys]
                            :config {:env @{}
                                     :cli {:log {:level :error}
                                           :http {:port 0}
                                           :auth-oauth slice}}})))
  (assert (not ok) (string why " does not start")))

(server/stop as)
(sign/free-key rsa-key)
(sign/free-key ec-key)

(print "oauth-test ok")
