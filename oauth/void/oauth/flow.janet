### void/oauth/flow — the authorization-code flow as data.
###
### Three requests make up the flow, and each is built here as a value
### before anything touches a socket: the authorization URL the
### browser is redirected to, the token exchange `void/http/client`
### POSTs, and the refresh that repeats it later. The suite asserts on
### all three without a network — the `introspection-request` form of
### void/auth's resource server.
###
### **The pending record is the flow's memory**, and it lives in the
### session: `{:provider :state :verifier :nonce :next :at}`, written by
### the start route, read *and deleted* by the callback in one motion — a
### code is good for one exchange, and so is the record that vouches for
### it. Under `[:deploy :shape] :fleet` the session store is already
### shared, so the flow survives a load balancer without this package
### storing anything anywhere.

(import spork/json)
(import void/core/log :as log)
(import void/crypto :as crypto)
(import void/http/client :as client)
(import void/http/wire :as wire)
(import ./pkce :as pkce)
(import ./provider :as provider)

(def log-ns "void.oauth")

(defn pending
  ``A fresh pending record for a provider: the state the callback will
  demand back, the PKCE verifier the exchange will present, a nonce
  when an id_token is expected, and where to land afterwards.``
  [p &opt next at]
  (default at (os/time))
  {:provider (p :name)
   :state (crypto/token 32)
   :verifier (pkce/verifier)
   :nonce (when (provider/openid? p) (crypto/token 16))
   :next next
   :at at})

(defn authorize-url
  ``The URL the browser is redirected to: `response_type=code`, the
  exact registered redirect URI, the scopes, the state, the S256
  challenge for the pending verifier, the nonce when openid is asked
  for — and the provider's `:params` on top (`access_type=offline`
  and its relatives live there, not in this package).``
  [p pend &opt cfg ring]
  (default cfg provider/settings)
  (default ring (provider/ring-for (p :name)))
  (def endpoint (provider/authorization-endpoint ring p cfg))
  (def query @{:response_type "code"
               :client_id (p :client-id)
               :redirect_uri (or (provider/redirect-uri p cfg)
                                 (errorf "provider %q has no redirect URI — set [:oauth :base-url] or the provider's :redirect-uri" (p :name)))
               :scope (string/join (get p :scopes []) " ")
               :state (pend :state)
               :code_challenge (pkce/challenge (pend :verifier))
               :code_challenge_method pkce/method})
  (when (pend :nonce) (put query :nonce (pend :nonce)))
  (eachp [k v] (get p :params {}) (put query k v))
  (string endpoint
          (if (string/find "?" endpoint) "&" "?")
          (wire/encode-query query)))

# -- the exchanges, as data ----------------------------------------------

(defn- client-auth
  "Put the client credentials on a token-endpoint request: Basic by
  default (RFC 6749 §2.3.1 — the form every server has), or in the
  form body for an issuer that insists."
  [p form headers]
  (def id (p :client-id))
  (def secret (provider/secret-value (p :client-secret)))
  (case (get p :auth :basic)
    :post (do (put form :client_id id)
              (when secret (put form :client_secret secret)))
    (put headers "authorization"
         (string "Basic " (crypto/base64 (string id ":" (or secret "")))))))

(defn token-request
  "The code exchange as a request table — grant, code, the same
  redirect URI the authorization request named, and the PKCE verifier
  whose challenge went out with it."
  [p code pend &opt cfg ring]
  (default cfg provider/settings)
  (default ring (provider/ring-for (p :name)))
  (def form @{:grant_type "authorization_code"
              :code code
              :redirect_uri (provider/redirect-uri p cfg)
              :code_verifier (pend :verifier)})
  (def headers @{"accept" "application/json"})
  (client-auth p form headers)
  {:method :post
   :url (provider/token-endpoint ring p cfg)
   :form form
   :headers headers
   :timeout (cfg :timeout)})

(defn refresh-request
  "A refresh as a request table — the same endpoint, the other grant."
  [p refresh-token &opt cfg ring]
  (default cfg provider/settings)
  (default ring (provider/ring-for (p :name)))
  (def form @{:grant_type "refresh_token"
              :refresh_token refresh-token})
  (def headers @{"accept" "application/json"})
  (client-auth p form headers)
  {:method :post
   :url (provider/token-endpoint ring p cfg)
   :form form
   :headers headers
   :timeout (cfg :timeout)})

# -- running them --------------------------------------------------------

(defn- no [reason] {:ok false :reason reason})

(defn- token-response
  ``A token endpoint's answer, normalized: keyword keys, the raw body
  kept for whatever a provider added. A refusal is a value with the
  issuer's error code in it — for the log, never for the visitor.``
  [resp]
  (cond
    (not= 200 (resp :status))
    (let [[ok body] (protect (json/decode (string (or (resp :body) "")) true))]
      (no (string/format "the token endpoint answered %d%s"
                         (resp :status)
                         (if (and ok (get body :error))
                           (string/format " (%s)" (body :error))
                           ""))))

    (let [[ok body] (protect (json/decode (string (or (resp :body) "")) true))]
      (cond
        (not ok) (no "the token endpoint did not answer JSON")
        (nil? (get body :access_token)) (no "the token response has no access_token")
        {:ok true
         :tokens {:access-token (get body :access_token)
                  :token-type (get body :token_type)
                  :expires-in (get body :expires_in)
                  :refresh-token (get body :refresh_token)
                  :id-token (get body :id_token)
                  :scope (get body :scope)
                  :raw body}}))))

(defn- run-exchange [req p what]
  (def [ok resp] (protect (client/request req)))
  (if ok
    (token-response resp)
    (do (log/warn "the token endpoint could not be reached" :ns log-ns
                  :provider (p :name) :for what
                  :err (if (string? resp) resp (describe resp)))
        (no "the token endpoint could not be reached"))))

(defn exchange!
  "Exchange an authorization code. Returns `{:ok true :tokens ...}` or
  `{:ok false :reason}`."
  [p code pend &opt cfg ring]
  (run-exchange (token-request p code pend cfg ring) p :code))

(defn refresh!
  ``Exchange a refresh token for fresh tokens — the half an
  application that stored one (its own column; this package stores nothing) calls later. The same shape as `exchange!`.``
  [p refresh-token &opt cfg ring]
  (run-exchange (refresh-request p refresh-token cfg ring) p :refresh))

(defn userinfo!
  ``The provider's userinfo document for an access token, or nil —
  when there is no endpoint, and when the call fails (logged): a
  sign-in hook that needs more than nil fetches the profile itself
  with the tokens it was handed.``
  [p access-token &opt cfg ring]
  (default cfg provider/settings)
  (default ring (provider/ring-for (p :name)))
  (when-let [url (provider/userinfo-endpoint ring p cfg)]
    (def [ok out]
      (protect
        (let [resp (client/get url {:timeout (cfg :timeout)
                                    :headers {"accept" "application/json"
                                              "authorization" (string "Bearer " access-token)}})]
          (when (= 200 (resp :status))
            (json/decode (string (or (resp :body) "")) true)))))
    (if ok
      out
      (do (log/warn "userinfo call failed" :ns log-ns
                    :provider (p :name)
                    :err (if (string? out) out (describe out)))
          nil))))
