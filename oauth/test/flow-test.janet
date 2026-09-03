# void/oauth without a socket: PKCE against the RFC's own vector, the
# boot gates (the ones whose text is the point), and the
# three requests of the flow as data — what would go out, asserted
# before anything can go out.

(import ../test-support/paths)
(import void/crypto :as crypto)
(import void/http/wire :as wire)
(import void/http/client :as client)
(import void/oauth/pkce :as pkce)
(import void/oauth/provider :as provider)
(import void/oauth/flow :as flow)

(crypto/load!)

# -- PKCE (RFC 7636) -----------------------------------------------------

(assert (= "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
           (pkce/challenge "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"))
        "the S256 challenge matches RFC 7636 appendix B, byte for byte")
(assert (= 43 (length (pkce/verifier)))
        "a verifier is 43 characters — 32 bytes of randomness in the unreserved alphabet")
(assert (not= (pkce/verifier) (pkce/verifier)) "and fresh every time")

# -- boot gates ----------------------------------------------------------

(defn- build [spec]
  (provider/build-settings {:config {:values {:oauth spec}}}))

(defn- refused [spec & needles]
  (def [ok err] (protect (build spec)))
  (assert (not ok) (string/format "%j should not have built" spec))
  (each needle needles
    (assert (string/find needle err)
            (string/format "the error should mention %q, got: %s" needle err))))

(refused {:providers {:acme {:issuer "http://idp.test"}}}
         ":client-id")

(refused {:providers {:acme {:client-id "app"}}}
         "nowhere to send the browser")

(refused {:providers {:acme {:client-id "app"
                             :authorization-endpoint "http://idp.test/authorize"}}}
         "nowhere to exchange the code")

# the back channel is called by void/http/client, which speaks TLS only
# when :void/tls is composed — without it the refusal names the ways out
(refused {:providers {:acme {:client-id "app"
                             :issuer "http://idp.test"
                             :token-endpoint "https://idp.test/token"}}}
         "https" "relay" ":void/tls")

# with the seam closed (what :void/tls does on load) the same https
# back channel is a working configuration — talking to a real IdP
(set client/tls-connect (fn stub [&] (error "never dialed by a boot check")))
(assert (first (protect (build {:base-url "http://app.test"
                                :providers {:acme {:client-id "app"
                                                   :issuer "https://accounts.example"
                                                   :scopes ["openid"]}}})))
        "an https issuer with discovery builds once TLS is composed")
(set client/tls-connect nil)

# an https issuer stays legal as the `iss` string, but then discovery
# is off and the back channel must be named explicitly
(refused {:providers {:acme {:client-id "app"
                             :issuer "https://accounts.example"}}}
         ":token-endpoint")

(refused {:providers {:acme {:client-id "app"
                             :issuer "https://accounts.example"
                             :token-endpoint "http://relay.local/token"}}}
         ":jwks-uri" "openid")

# an id_token verified with HS* is signed with the client secret — a
# verifying key that can issue
(refused {:providers {:acme {:client-id "app"
                             :issuer "http://idp.test"
                             :algs [:hs256]}}}
         "HMAC")

# routes mounted and no way to build the exact redirect URI: deriving
# it from a Host header is RFC 9700's open door
(refused {:providers {:acme {:client-id "app" :issuer "http://idp.test"}}}
         "redirect URI" ":base-url")

# and the good one resolves
(def cfg
  (build {:base-url "http://app.test"
          :providers {:acme {:issuer "http://idp.test"
                             :client-id "app-1"
                             :client-secret "shh"
                             :scopes ["openid" "email"]
                             # the browser speaks TLS itself: https is
                             # legal exactly here
                             :authorization-endpoint "https://accounts.example/authorize"
                             :token-endpoint "http://idp.test/token"
                             :jwks-uri "http://idp.test/jwks"
                             :params {:access_type "offline"}}
                      :plain {:authorization-endpoint "http://idp.test/authorize?tenant=t1"
                              :token-endpoint "http://idp.test/token"
                              :client-id "app-2"
                              :scopes ["identify"]
                              :auth :post}}}))

(def acme (provider/provider :acme cfg))
(def plain (provider/provider :plain cfg))

(assert (= "http://app.test/oauth/acme/callback" (provider/redirect-uri acme cfg))
        "the redirect URI is base-url + mount + the provider's callback, literally")
(assert (provider/openid? acme))
(assert (not (provider/openid? plain)))

(def [ok err] (protect (provider/provider :nope cfg)))
(assert (and (not ok) (string/find "acme" err))
        "an unknown provider is named next to the known ones")

# -- the authorization request -------------------------------------------

(def ring (provider/make-ring))
(def pend (flow/pending acme))

(assert (pend :nonce) "openid asks for an id_token, so a nonce goes out")
(assert (nil? ((flow/pending plain) :nonce)) "a plain provider sends none")

(def url (flow/authorize-url acme pend cfg ring))
(def q (wire/parse-query (string/slice url (inc (string/find "?" url)))))

(assert (string/has-prefix? "https://accounts.example/authorize?" url))
(assert (= "code" (q "response_type")))
(assert (= "app-1" (q "client_id")))
(assert (= "http://app.test/oauth/acme/callback" (q "redirect_uri")))
(assert (= "openid email" (q "scope")))
(assert (= (pend :state) (q "state")))
(assert (= "S256" (q "code_challenge_method")))
(assert (= (pkce/challenge (pend :verifier)) (q "code_challenge"))
        "the challenge is S256 of the very verifier the exchange will present")
(assert (= (pend :nonce) (q "nonce")))
(assert (= "offline" (q "access_type"))
        "the provider's :params ride along — access_type=offline is configuration, not code")

# an endpoint that already carries a query gets & rather than a second ?
(def url2 (flow/authorize-url plain (flow/pending plain) cfg ring))
(assert (string/has-prefix? "http://idp.test/authorize?tenant=t1&" url2))

# -- the exchanges, as data ----------------------------------------------

(def treq (flow/token-request acme "code-123" pend cfg ring))
(assert (= :post (treq :method)))
(assert (= "http://idp.test/token" (treq :url)))
(assert (= "authorization_code" (get-in treq [:form :grant_type])))
(assert (= "code-123" (get-in treq [:form :code])))
(assert (= "http://app.test/oauth/acme/callback" (get-in treq [:form :redirect_uri]))
        "the exchange names the same redirect URI the authorization request did")
(assert (= (pend :verifier) (get-in treq [:form :code_verifier])))
(assert (= (string "Basic " (crypto/base64 "app-1:shh"))
           (get-in treq [:headers "authorization"]))
        "client credentials ride Basic by default (RFC 6749 §2.3.1)")
(assert (nil? (get-in treq [:form :client_secret]))
        "and never the form as well")

(def preq (flow/token-request plain "c" (flow/pending plain) cfg ring))
(assert (= "app-2" (get-in preq [:form :client_id]))
        ":auth :post puts the client id in the body instead")
(assert (nil? (get-in preq [:headers "authorization"])))

(def rreq (flow/refresh-request acme "refresh-9" cfg ring))
(assert (= "refresh_token" (get-in rreq [:form :grant_type])))
(assert (= "refresh-9" (get-in rreq [:form :refresh_token])))
(assert (= (treq :url) (rreq :url)) "the same endpoint, the other grant")

(print "flow-test ok")
