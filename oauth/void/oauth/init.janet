### void/oauth — "sign in with a provider": the OAuth 2.1 / OIDC
### **client** (ADR-0034), the half ADR-0032 deliberately did not
### build.
###
### Two routes and one hook are the whole surface. `GET
### <mount>/:provider` writes a pending record into the session and
### redirects the browser: code + PKCE (S256, no knob), an exact
### registered redirect URI (never derived from a Host header — RFC
### 9700), a nonce when openid is asked for. `GET
### <mount>/:provider/callback` reads that record back *and deletes
### it* in one motion, demands the state it issued (constant-time),
### exchanges the code over `void/http/client`, verifies the id_token
### against the issuer's JWKS with the same rules ADR-0032 applies to
### access tokens — and then hands everything to the application's
### `:void.oauth/sign-in` contribution, because the framework does not
### know what a user is (ADR-0023). An identity comes back: it is
### signed in through `auth-http/login!` (session-id rotation
### included) and redirected. A response comes back: it goes out as
### is. nil comes back: 403 — the application said no.
###
### **Nothing is stored by this package.** The pending record lives in
### the session — under `[:deploy :shape] :fleet` the session store is
### already shared (ADR-0030), so the flow survives a load balancer by
### construction. Refresh tokens are handed to the hook as data; the
### application that wants them later keeps them in its own column and
### calls `oauth/refresh!`.
###
### **TLS comes with the composition, and the boot check knows it**
### (ADR-0010, ADR-0038): the authorization endpoint may always be
### https — the *browser* goes there — while the metadata, token,
### JWKS and userinfo endpoints are called by void's own client. With
### `:void/tls` composed they may be https too, which is what talking
### to a real IdP looks like; without it, https in any of them is a
### boot error naming the ways out (the plugin, an internal issuer
### over http, or an egress relay beside the process).

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/crypto :as crypto)
(import void/http :as http)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import void/auth/identity :as identity)
(import void/auth/http :as auth-http)
(import ./provider :as provider)
(import ./flow :as flow)

(def log-ns "void.oauth")

# -- the application's half ----------------------------------------------

(plugin/defextension-point :void.oauth/sign-in
  :doc "The application's half of the flow (ADR-0034): {:name :fn}, where :fn is (fn [{:provider :claims :tokens :req}] ...) — return an identity to sign it in (login! with session-id rotation, then a redirect), a response table to answer yourself (onboarding, account linking), or nil to refuse (403). One per composition; it receives the provider name first. Mind the user store: under the default [:auth-http :session :load] :store the subject is re-read from it on every request, so either upsert the user in this hook or set :load :session"
  :schema {:name :keyword
           :doc [:optional :string]
           :fn :function}
  :cardinality :single)

(var sign-in-hook
  "The resolved :void.oauth/sign-in contribution, captured at
  :before-start."
  nil)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :oauth/capture-config
   :doc "Read the [:oauth] slice, run ADR-0034's boot gates and capture the sign-in hook"
   :fn (fn capture [boot]
         (set provider/settings (provider/build-settings boot))
         (set sign-in-hook (get-in boot [:extensions :void.oauth/sign-in :resolved]))
         (when (and (get provider/settings :mount)
                    (not (empty? (get provider/settings :providers)))
                    (nil? sign-in-hook))
           (error (string "void/oauth mounts its routes but nothing contributes "
                          ":void.oauth/sign-in — the callback would verify a visitor "
                          "and have nobody to hand them to. Contribute {:name ... :fn "
                          "(fn [{:provider :claims :tokens :req}] ...)} from the "
                          "application, or set [:oauth :mount] false and drive the "
                          "flow from your own routes."))))})

# -- the component --------------------------------------------------------

(def providers-component
  (system/component :oauth/providers
    :doc "One ring per configured provider: the issuer's metadata and
    its opened keys, fetched lazily (a process nobody signs into never
    calls its issuer) and freed at :stop — the one place a key's
    lifetime ends (ADR-0022)."
    :deps [:crypto/lib]
    :start
    (fn start [_ _]
      (def rings @{})
      (eachp [name _] (get provider/settings :providers {})
        (put rings name (provider/make-ring)))
      (set provider/current-rings rings)
      rings)
    :stop
    (fn stop [rings]
      (each ring (values rings) (provider/free-keys! ring))
      (set provider/current-rings nil)
      rings)
    :health
    (fn health [rings]
      {:status :up
       :providers (sorted (keys rings))})))

# -- the routes -----------------------------------------------------------

(def- local-path?
  # the only :next accepted: a path on this application. The check
  # lives in void/auth/http, next to the ?next= it validates — it
  # refuses "//evil.example" *and* "/\evil.example", which browsers
  # read as the same scheme-relative URL
  auth-http/local-path?)

(defn- refuse
  "A refusal through the error renderers — HTML for a browser,
  problem+json for an API — with the detail in the log, never in the
  body."
  [req status message]
  (http/render-error {:http/status status :message message} req status))

(defn start-handler
  "GET <mount>/:provider — write the pending record and send the
  browser to the authorization server."
  [req]
  (def cfg provider/settings)
  (def name (keyword (get-in req [:params :provider] "")))
  (def p (get-in cfg [:providers name]))
  (cond
    (nil? p) (ring/not-found)
    (not (dictionary? (req :session)))
    (error "void/oauth needs a session — is :void/http's session middleware enabled?")

    (let [next (let [n (get (or (req :query) {}) "next")]
                 (when (local-path? n) (string n)))
          pend (flow/pending p next)]
      (put (req :session) (cfg :session-key) pend)
      (log/debug "sign-in started" :ns log-ns :provider name)
      (ring/redirect (flow/authorize-url p pend cfg)))))

(defn- finish
  "What the sign-in hook decided, turned into a response."
  [req pend out]
  (def cfg provider/settings)
  (cond
    (identity/identity? out)
    (do (auth-http/login! req out)
        (ring/redirect (or (pend :next) (cfg :after-sign-in))))

    (and (dictionary? out) (out :status)) out

    (nil? out)
    (do (log/info "sign-in refused by the application" :ns log-ns)
        (refuse req 403 "sign-in refused"))

    (errorf ":void.oauth/sign-in returned %q — an identity, a response table or nil" out)))

(defn callback-handler
  "GET <mount>/:provider/callback — the flow's second half: the
  pending record is consumed first, every check failure is a refusal
  with its reason in the log, and the visitor's claims end up in front
  of the application's hook."
  [req]
  (def cfg provider/settings)
  (def name (keyword (get-in req [:params :provider] "")))
  (def p (get-in cfg [:providers name]))
  (def sess (req :session))
  (def pend (when (dictionary? sess) (get sess (cfg :session-key))))
  # one shot: a code is good for one exchange, and so is the record
  # that vouches for it — it is gone before anything is checked
  (when (dictionary? sess) (put sess (cfg :session-key) nil))
  (def q (or (req :query) {}))
  (defn fail [status message & detail]
    (log/info "sign-in failed" :ns log-ns :provider name ;detail)
    (refuse req status message))
  (cond
    (nil? p) (ring/not-found)

    (nil? pend)
    (fail 400 "no sign-in in progress" :reason "no pending record in the session")

    (not= (pend :provider) name)
    (fail 400 "no sign-in in progress" :reason "pending record is another provider's"
          :pending (pend :provider))

    (> (- (os/time) (get pend :at 0)) (cfg :max-age))
    (fail 400 "the sign-in took too long — try again" :reason "pending record expired")

    (get q "error")
    # the issuer's code goes to the log; the visitor gets a sentence
    (fail 502 "the authorization server refused"
          :reason "issuer error" :error (get q "error"))

    (not (and (bytes? (get q "state"))
              (crypto/equal? (get q "state") (pend :state))))
    (fail 400 "the sign-in could not be verified — try again" :reason "state mismatch")

    (nil? (get q "code"))
    (fail 400 "the sign-in could not be verified — try again" :reason "no code")

    (let [out (flow/exchange! p (get q "code") pend cfg)]
      (if (not (out :ok))
        (fail 502 "the sign-in could not be completed" :reason (out :reason))
        (let [tokens (out :tokens)
              id-token (tokens :id-token)]
          (cond
            # openid was asked for: an answer without an id_token is
            # not a shrug, it is a refusal
            (and (provider/openid? p) (nil? id-token))
            (fail 502 "the sign-in could not be completed"
                  :reason "openid scope and no id_token in the response")

            (let [verified (when id-token
                             (provider/verify-id-token id-token p (pend :nonce) cfg))]
              (if (and verified (not (verified :ok)))
                (fail 502 "the sign-in could not be completed"
                      :reason (verified :reason))
                (let [claims (or (when verified (verified :claims))
                                 (flow/userinfo! p (tokens :access-token) cfg)
                                 {})]
                  (log/info "sign-in verified" :ns log-ns :provider name
                            :subject (get claims :sub))
                  (finish req pend
                          ((sign-in-hook :fn) {:provider name
                                               :claims claims
                                               :tokens tokens
                                               :req req})))))))))))

(defn- own-routes
  # a function of boot, not a value: the mount point is configuration,
  # which is not known when this manifest freezes (the ADR-0029 §12
  # form)
  [_boot]
  (def cfg provider/settings)
  (if (cfg :mount)
    (router/routes {:void.auth/access :public}
      (router/GET (string (cfg :mount) "/:provider") 'start-handler
                  {:name :void.oauth/start})
      (router/GET (string (cfg :mount) "/:provider/callback") 'callback-handler
                  {:name :void.oauth/callback}))
    (router/routes {})))

# -- CLI ------------------------------------------------------------------

(plugin/contribute! :void.core/cli
  {:name :oauth/check
   :doc "Resolve every configured provider — endpoints, redirect URI, scopes, algorithms — from this side of the config: void oauth check"
   :read-only? true
   :needs [:oauth/providers]
   :fn (fn cli-check [rings & _]
         (def cfg provider/settings)
         (if (empty? (cfg :providers))
           (print "no [:oauth :providers] configured")
           (eachp [name p] (cfg :providers)
             (printf "%s:" (string name))
             (printf "  issuer:        %s" (or (p :issuer) "(none)"))
             (printf "  redirect-uri:  %s" (or (provider/redirect-uri p cfg) "(UNRESOLVED — set [:oauth :base-url] or :redirect-uri)"))
             (printf "  scopes:        %s" (string/join (get p :scopes []) " "))
             (printf "  algorithms:    %s" (string/join (map string (p :algs)) " "))
             (def ring (get rings name (provider/make-ring)))
             (each [label f]
               [["authorization" provider/authorization-endpoint]
                ["token" provider/token-endpoint]
                ["userinfo" provider/userinfo-endpoint]]
               (def [ok out] (protect (f ring p cfg)))
               (printf "  %-14s %s" (string label ":")
                       (cond (and ok out) (string out)
                             ok "(none)"
                             (string "UNREACHABLE — " (if (string? out) out (describe out))))))
             (when (provider/openid? p)
               (def [ok n] (protect (provider/refresh-keys! ring p cfg)))
               (if ok
                 (printf "  keys:          %d" n)
                 (printf "  keys:          UNAVAILABLE — %s" (if (string? n) n (describe n))))))))})

# -- public surface -------------------------------------------------------

(def resolve-provider "See provider/provider — one resolved provider by name." provider/provider)
(def redirect-uri "See provider/redirect-uri." provider/redirect-uri)
(def verify-id-token "See provider/verify-id-token." provider/verify-id-token)
(def pending "See flow/pending." flow/pending)
(def authorize-url "See flow/authorize-url." flow/authorize-url)
(def token-request "See flow/token-request — the exchange as data." flow/token-request)
(def refresh-request "See flow/refresh-request." flow/refresh-request)
(def exchange! "See flow/exchange!." flow/exchange!)
(def refresh! "See flow/refresh! — for the refresh token the application kept." flow/refresh!)
(def userinfo! "See flow/userinfo!." flow/userinfo!)

(plugin/defplugin void/oauth
  :doc "\"Sign in with a provider\": the OAuth 2.1 / OIDC client — authorization code + PKCE (S256, always), the pending flow in the session (shared under :fleet by ADR-0030), the code exchanged over void/http/client, the id_token verified against the issuer's JWKS with ADR-0032's rules, and the verified visitor handed to the application's :void.oauth/sign-in — which alone decides who may become an identity."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/crypto ">=0.0.1" :void/http ">=0.0.1"
             :void/auth ">=0.0.1" :void/auth-http ">=0.0.1"}
  :config-key :oauth
  :config-schema provider/Config
  :config-defaults provider/defaults
  :components [providers-component]
  :contributes {:void.http/route-source
                [{:name :void/oauth
                  :routes own-routes
                  :env (router/env-ref (curenv))}]})
