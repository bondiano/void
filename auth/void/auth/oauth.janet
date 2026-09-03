### void/auth-oauth — the application as an OAuth 2.1 **resource server**
### (RFC 6750/7662/8414/9728, MCP authorization).
###
### This is the half of OAuth an API needs and the half `void/oauth`
### (wave 5) will not have: not "log in with Google" — that is a
### client, and it redirects browsers — but "somebody handed me an
### access token; is it valid, was it issued *for me*, and what may it
### do". It is a separate plugin in the auth package, the void/cache —
### void/cache-http split, so an application with sessions and
### passwords composes none of it.
###
### **The audience check is the reason this exists.** MCP's
### authorization spec turns one sentence into a requirement: a
### resource server MUST reject a token that was not issued for it,
### and MUST NOT pass a token it received on to anybody else. Without
### that rule an access token minted for a chat app is a valid token
### for every other service that trusts the same issuer — the
### "confused deputy" of RFC 9700, and the reason RFC 8707 gave
### clients a `resource` parameter to ask for an audience with. So
### `[:auth-oauth :audience]` is **required**: it is this server's
### canonical URI, it is compared against `aud` on every token, and a
### composition that does not name it does not start.
###
### **Two ways to check a token, and the choice is the issuer's, not
### ours.** A JWT is verified locally against the issuer's published keys
### (JWKS, fetched lazily and cached; the key is opened once and held for
### the process, per the note on key lifetimes) — no network on the hot
### path. An opaque token has no structure to verify, so it goes to the
### issuer's introspection endpoint (RFC
### 7662) with the resource server's own client credentials. `:auto`
### tries the first and falls back to the second, which is what a
### deployment with both kinds of token needs.
###
### **`alg` still never comes from the token.** The accepted list is
### configuration (`[:auth-oauth :algs]`, RS256/ES256 by default), the
### JWKS says what each key is for, and `void/auth/jwt` refuses
### anything else before it looks at a signature. A JWKS that offers
### an HMAC key does not turn this into an HMAC verifier.
###
### **What a client is told, and what it is not.** A refusal carries
### `WWW-Authenticate` with the RFC 6750 error code and a pointer to
### this server's protected-resource metadata (RFC 9728) — that
### pointer is how an MCP client discovers which authorization server
### to go to, and it is the difference between "401" and "401, and
### here is how to fix it". Which *part* of a token failed goes to the
### log and never to the client.
###
### The metadata document itself is served at
### `/.well-known/oauth-protected-resource` — a fixed path, because it
### is fixed by the RFC, and one an application can turn off with
### `[:auth-oauth :endpoints] false` when it publishes its own.

(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/config :as config)
(import void/core/log :as log)
(import void/crypto/sign :as sign)
(import void/crypto/encode :as encode)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import void/http/client :as client)
(import ./identity :as identity)
(import ./jwt :as jwt)
(import ./jwk :as jwk)
(import ./state :as state)
(import ./token :as token)

(def log-ns "void.auth.oauth")

(def metadata-path
  ``Where the protected-resource metadata is served (RFC 9728 §3): a
  fixed path, because a client that has only this server's URL has to
  be able to find it without being told.``
  "/.well-known/oauth-protected-resource")

(def default-algs
  ``The algorithms accepted from a JWKS unless configured otherwise.
  Asymmetric only: a resource server that accepts HS256 has to hold
  the key that *mints* tokens, and then it is an authorization
  server.``
  [:rs256 :es256])

(def Config
  "Schema of the [:auth-oauth] config slice."
  {:issuer [:optional :string]
   :audience [:optional :string]
   :jwks-uri [:optional :string]
   :metadata-url [:optional :string]
   :algs [:optional [:vector :keyword]]
   :mode [:optional [:enum :jwt :introspect :auto]]
   :introspection [:optional {:url [:optional :string]
                              :client-id [:optional :string]
                              :client-secret [:optional :any]
                              :auth [:optional [:enum :basic :post]]}]
   :required-scopes [:optional [:vector :string]]
   :scopes-supported [:optional [:vector :string]]
   :authorization-servers [:optional [:vector :string]]
   :resource-documentation [:optional :string]
   :endpoints [:optional :boolean]
   :realm [:optional :string]
   :leeway [:optional [:number {:min 0}]]
   :cache-ttl [:optional [:number {:min 0}]]
   :refresh-cooldown [:optional [:number {:min 0}]]
   :timeout [:optional [:number {:min 0.1}]]})

(def defaults
  {:algs default-algs
   :mode :auto
   :required-scopes []
   :scopes-supported []
   :endpoints true
   :realm "api"
   :leeway 30
   :cache-ttl 300
   :refresh-cooldown 30
   :timeout 5})

(var settings "The [:auth-oauth] slice, read at :before-start." defaults)

(defn- secret-value
  "A config value that may be a secret box (`{:secret \"ENV\"}`)."
  [v]
  (when v (if (config/secret? v) (config/reveal v) v)))

# -- the key ring --------------------------------------------------------

(var current-ring
  "The running :auth.oauth/keys component — one per process."
  nil)

(defn ring-state
  "The running key ring, or a readable error."
  []
  (or current-ring
      (error "void/auth-oauth is not started — add :void/auth-oauth to :plugins (the :auth.oauth/keys component holds the issuer's keys)")))

(defn- free-keys! [ring]
  (each entry (values (ring :keys))
    (protect (sign/free-key (entry :key))))
  (put ring :keys @{}))

(defn- fetch-json
  "GET a URL and decode JSON, or throw with the status in the text."
  [url timeout]
  (def resp (client/get url {:timeout timeout
                             :headers {"accept" "application/json"}}))
  (unless (and (>= (resp :status) 200) (< (resp :status) 300))
    (errorf "%s answered %d" url (resp :status)))
  (json/decode (string (or (resp :body) "")) true))

(defn discover
  ``The authorization server's metadata (RFC 8414). Tried in the order
  the specifications prescribe: the OAuth document first, then the
  OpenID Connect one, because an issuer that publishes only the latter
  is common and its `jwks_uri` means the same thing.

  Cached on the ring: an issuer's endpoints do not move, and a
  discovery request per token would put the authorization server on
  this server's hot path.``
  [ring &opt cfg]
  (default cfg settings)
  (or (ring :metadata)
      (let [issuer (or (cfg :issuer)
                       (error "[:auth-oauth :issuer] is not set — there is nothing to discover"))
            base (if (string/has-suffix? "/" issuer)
                   (string/slice issuer 0 -2)
                   issuer)
            urls (if-let [u (cfg :metadata-url)]
                   [u]
                   [(string base "/.well-known/oauth-authorization-server")
                    (string base "/.well-known/openid-configuration")])]
        (var found nil)
        (var last-err nil)
        (each url urls
          (unless found
            (def [ok doc] (protect (fetch-json url (cfg :timeout))))
            (if ok
              (set found doc)
              (set last-err doc))))
        (unless found
          (errorf "cannot read the authorization server metadata of %s: %s"
                  issuer (if (string? last-err) last-err (describe last-err))))
        # an issuer that names itself something else is either
        # misconfigured or somebody else's (RFC 8414 §3.3)
        (when-let [named (get found :issuer)]
          (unless (= (string named) (string issuer))
            (errorf "metadata at %s says issuer %q, configured issuer is %q"
                    (first urls) named issuer)))
        (put ring :metadata found)
        found)))

(defn- jwks-uri [ring cfg]
  (or (cfg :jwks-uri)
      (get (discover ring cfg) :jwks_uri)
      (error "no JWKS: set [:auth-oauth :jwks-uri], or an issuer whose metadata publishes jwks_uri")))

(defn refresh-keys!
  ``Fetch the issuer's JWKS and open every usable key. Replaced keys
  are freed here — this is the one place a key's lifetime ends, and
  the reason the ring is a component rather than a module variable.

  Returns the number of keys held.``
  [ring &opt cfg]
  (default cfg settings)
  (def now (os/clock :monotonic))
  (put ring :last-attempt now)
  (def doc (fetch-json (jwks-uri ring cfg) (cfg :timeout)))
  (def accepted (get cfg :algs default-algs))
  (def opened @{})
  (var index 0)
  (each k (jwk/signing-keys doc)
    (when (index-of (k :alg) accepted)
      (def [ok key] (protect (sign/public-key (k :pem))))
      (if ok
        (put opened (or (k :kid) (string "#" (++ index)))
             {:alg (k :alg) :key key :kid (k :kid)})
        (log/warn "a JWKS key would not open" :ns log-ns
                  :kid (k :kid) :alg (k :alg)
                  :err (if (string? key) key (describe key))))))
  (free-keys! ring)
  (put ring :keys opened)
  (put ring :fetched now)
  (put ring :error nil)
  (log/debug "JWKS fetched" :ns log-ns :keys (length opened))
  (length opened))

(defn- ensure-keys!
  ``The keys, fetched if they are missing or stale. A fetch that fails
  is logged and remembered, never raised: an authorization server that
  is down must make tokens fail to verify, not make the process throw
  500s at everybody.``
  [ring cfg]
  (def now (os/clock :monotonic))
  (def ttl (cfg :cache-ttl))
  (when (or (empty? (ring :keys))
            (> (- now (get ring :fetched 0)) ttl))
    (when (> (- now (get ring :last-attempt -1000)) (cfg :refresh-cooldown))
      (def [ok err] (protect (refresh-keys! ring cfg)))
      (unless ok
        (put ring :error (if (string? err) err (describe err)))
        (log/warn "JWKS refresh failed" :ns log-ns :err (ring :error)))))
  (ring :keys))

(defn- key-for
  ``The key a token's `kid` names. An unknown kid is the signal that
  the issuer rotated, so it is worth exactly one refetch — behind the
  cooldown, because an attacker who can invent a `kid` must not be
  able to make this process call its issuer once per request.``
  [ring cfg kid]
  (def keys (ensure-keys! ring cfg))
  (or (when kid (get keys kid))
      (when (and kid (> (- (os/clock :monotonic) (get ring :last-attempt -1000))
                        (cfg :refresh-cooldown)))
        (def [ok] (protect (refresh-keys! ring cfg)))
        (when ok (get (ring :keys) kid)))
      # a JWKS with one key does not have to name it, and a token
      # signed by it does not have to carry a kid
      (when (and (nil? kid) (= 1 (length keys)))
        (first (values keys)))))

# -- verifying -----------------------------------------------------------

(defn- no [reason] {:ok false :reason reason})

(defn verify-jwt
  ``Verify an access token as a JWS against the issuer's keys.
  Returns `{:ok true :claims}` or `{:ok false :reason}` — the reason
  is for the log (see the header).``
  [tok &opt cfg ring]
  (default cfg settings)
  (default ring (ring-state))
  (def peeked (jwt/peek tok))
  (cond
    (nil? peeked) (no "not a JWS")
    (let [kid (get-in peeked [:header :kid])
          entry (key-for ring cfg (when kid (string kid)))]
      (cond
        (nil? entry) (no (string/format "no key for kid %q" kid))

        # **The key's own algorithm is the only one accepted for it.**
        # The JWKS says what each key is for, and the token gets no
        # vote: an RS256 key handed to an ES256 verifier is not a
        # failed signature, it is a type error inside libcrypto — and
        # the header that would cause it is written by whoever sent
        # the token
        (not (index-of (entry :alg) (get cfg :algs default-algs)))
        (no (string/format "key %q signs %q, which is not accepted here"
                           kid (entry :alg)))

        (let [[ok out] (protect (jwt/decode-token tok
                                                  {:alg [(entry :alg)]
                                                   :key (entry :key)
                                                   :issuer (cfg :issuer)
                                                   :audience (cfg :audience)
                                                   :leeway (cfg :leeway)}))]
          (cond
            # a token is attacker-controlled input, and nothing about
            # it may reach a caller as an exception: that would be a
            # 500 anybody could ask for
            (not ok)
            (do (log/warn "verifying a token raised" :ns log-ns
                          :err (if (string? out) out (describe out)))
                (no "the token could not be verified"))
            (out :ok) {:ok true :claims (out :claims)}
            out))))))

(defn introspection-request
  "The introspection call as data — the request table, so the suite
  can assert on what would go out without a socket."
  [tok cfg url]
  (def intro (get cfg :introspection {}))
  (def id (intro :client-id))
  (def secret (secret-value (intro :client-secret)))
  (def form @{:token tok :token_type_hint "access_token"})
  (def headers @{"accept" "application/json"})
  (case (get intro :auth :basic)
    :post (do (when id (put form :client_id id))
              (when secret (put form :client_secret secret)))
    (when id
      # RFC 7662 §2.1: the resource server authenticates to the
      # introspection endpoint, and Basic is the form every server has
      (put headers "authorization"
           (string "Basic " (encode/base64 (string id ":" (or secret "")))))))
  {:method :post :url url :form form :headers headers :timeout (cfg :timeout)})

(defn introspect
  ``Ask the authorization server about an opaque token (RFC 7662).
  Returns the same shape as `verify-jwt`.

  `active` false is a refusal, not an error; a *failed call* is also a
  refusal, because a resource server that cannot reach its issuer
  cannot honour a token — but it says so distinctly in the log, since
  the two have different fixes.``
  [tok &opt cfg ring]
  (default cfg settings)
  (def intro (get cfg :introspection {}))
  (def url (or (intro :url)
               (when ring (get (or (ring :metadata) {}) :introspection_endpoint))))
  (cond
    (nil? url) (no "no introspection endpoint configured")
    (let [req (introspection-request tok cfg url)
          [ok resp] (protect (client/request req))]
      (cond
        (not ok)
        (do (log/warn "introspection call failed" :ns log-ns
                      :err (if (string? resp) resp (describe resp)))
            (no "the introspection endpoint could not be reached"))

        (not= 200 (resp :status))
        (no (string/format "introspection answered %d" (resp :status)))

        (let [[ok-body body] (protect (json/decode (string (or (resp :body) "")) true))]
          (cond
            (not ok-body) (no "introspection did not answer JSON")
            (not (truthy? (get body :active))) (no "token is not active")

            # an introspection response is claims, and the same three
            # claims decide as they do for a JWT — the endpoint told us
            # the token is alive, not that it is ours. RFC 7662 makes
            # both fields optional, so a *missing* claim is a refusal
            # exactly like a wrong one: a server that does not echo
            # `aud` would otherwise turn every active token of the
            # issuer into a token for this resource — the confused
            # deputy the audience gate exists to prevent
            (and (cfg :issuer)
                 (let [iss (get body :iss)]
                   (or (nil? iss) (not= (string iss) (cfg :issuer)))))
            (no "wrong issuer")

            (and (cfg :audience)
                 (let [aud (get body :aud)]
                   (or (nil? aud)
                       (not (if (indexed? aud)
                              (index-of (cfg :audience) (map string aud))
                              (= (string aud) (cfg :audience)))))))
            (no "wrong audience")

            (and (get body :exp) (< (+ (get body :exp) (cfg :leeway)) (os/time)))
            (no "expired")

            {:ok true :claims body}))))))

(defn- signature-refusal?
  ``Did a JWS fail on its *signature* (or on the segment carrying it)?
  That failure is final: the token is a forged or corrupted JWT, never
  an opaque token, and asking the issuer about it would let anybody
  who can mint garbage JWSs spend one introspection call — and one
  parked fiber — per request against the authorization server.``
  [reason]
  (truthy? (and (bytes? reason) (string/find "signature" (string reason)))))

(defn verify
  ``Check an access token and return `{:ok true :claims}` or
  `{:ok false :reason}`. `[:auth-oauth :mode]` picks the method:
  `:jwt`, `:introspect`, or `:auto` — which verifies a JWS locally and
  falls back to introspection for a token that is not one.``
  [tok &opt cfg ring]
  (default cfg settings)
  (default ring (ring-state))
  (case (get cfg :mode :auto)
    :jwt (verify-jwt tok cfg ring)
    :introspect (introspect tok cfg ring)
    (if (jwt/peek tok)
      (let [out (verify-jwt tok cfg ring)]
        (if (out :ok)
          out
          # a JWS this server cannot verify is not automatically an
          # opaque token: introspection is tried only when it is
          # configured — and never for a signature that failed, which
          # is a final answer (the fallback is for "no key for this
          # kid", where the issuer genuinely may know better). The JWT
          # reason is what the log keeps
          (if (and (get-in cfg [:introspection :url])
                   (not (signature-refusal? (out :reason))))
            (introspect tok cfg ring)
            out)))
      (introspect tok cfg ring))))

# -- scopes --------------------------------------------------------------

(defn claim-scopes
  ``The scopes of a token's claims, as a tuple of strings. `scope` is
  the space-delimited string RFC 6749 defines; `scp` is the array some
  issuers send instead, and reading both is cheaper than telling
  operators their issuer is wrong.``
  [claims]
  (def raw (or (get claims :scope) (get claims :scp)))
  (cond
    (nil? raw) []
    (bytes? raw) (tuple ;(filter |(not (empty? $)) (string/split " " (string raw))))
    (indexed? raw) (tuple ;(map string raw))
    []))

(defn scopes
  "The scopes of an identity (the current one by default) — what a
  route's `:void.auth/scopes` is checked against."
  [&opt id]
  (default id (identity/current))
  (if id (claim-scopes (get id :claims {})) []))

(defn has-scopes?
  "Does this identity carry every one of `wanted`?"
  [wanted &opt id]
  (def have (scopes id))
  (all |(truthy? (index-of $ have)) (or wanted [])))

# -- the strategy --------------------------------------------------------

(defn- bearer-token [req]
  (when-let [header (ring/request-header req "authorization")]
    (when (string/has-prefix? "Bearer " header)
      (string/trim (string/slice header 7)))))

(defn- oauth-identity [req]
  (when-let [presented (bearer-token req)]
    # a void API token belongs to the :bearer strategy, and handing it
    # to an authorization server would put a credential of ours in
    # somebody else's log
    (when (nil? (token/parse presented (get (state/settings) :token {})))
      (def out (verify presented))
      (if (out :ok)
        (let [claims (out :claims)
              sub (or (get claims :sub) (get claims :client_id))]
          (if sub
            (identity/make (string sub)
                           {:via :oauth
                            :cookie false
                            :claims claims
                            :expires (get claims :exp)})
            (do (log/debug "access token has no sub or client_id" :ns log-ns) nil)))
        (do
          (log/debug "access token rejected" :ns log-ns :reason (out :reason))
          nil)))))

(defn resource-metadata-url
  ``The absolute URL of this server's protected-resource metadata —
  the pointer a refusal carries. Derived from `[:auth-oauth
  :audience]`, which is this server's canonical URI, so it is right by
  construction rather than by a second setting somebody has to keep in
  step.``
  [&opt cfg]
  (default cfg settings)
  (when-let [resource (cfg :audience)]
    (def [scheme rest] (if-let [i (string/find "://" resource)]
                         [(string/slice resource 0 (+ i 3)) (string/slice resource (+ i 3))]
                         ["" resource]))
    (def slash (string/find "/" rest))
    (def host (if slash (string/slice rest 0 slash) rest))
    (def path (if slash (string/slice rest slash) ""))
    # RFC 9728 §3.1: a resource with a path keeps it *after* the
    # well-known segment, so two resources on one host have two
    # documents
    (string scheme host metadata-path (if (= "/" path) "" path))))

(defn challenge-header
  ``A `WWW-Authenticate` value (RFC 6750 §3, RFC 9728 §5.1). `error`
  is nil for "no credentials at all", `\"invalid_token\"` for one that
  did not verify, `\"insufficient_scope\"` for one that did and may
  not.``
  [&opt error description wanted cfg]
  (default cfg settings)
  (def parts @[(string/format "Bearer realm=%q" (get cfg :realm "api"))])
  (when error (array/push parts (string/format "error=%q" error)))
  (when description (array/push parts (string/format "error_description=%q" description)))
  (when (and wanted (not (empty? wanted)))
    (array/push parts (string/format "scope=%q" (string/join wanted " "))))
  (when-let [url (resource-metadata-url cfg)]
    (array/push parts (string/format "resource_metadata=%q" url)))
  (string/join parts ", "))

(def strategy
  ``The `:oauth` strategy: `Authorization: Bearer <access token>`,
  verified against the issuer this server trusts and required to name
  this server in `aud`.``
  {:name :oauth
   :doc "Authorization: Bearer <access token> — an OAuth 2.1 access token verified against the issuer's JWKS or its introspection endpoint, and required to carry this server's audience"
   :cookie false
   # ahead of :bearer (20), and the reason is the *challenge* rather
   # than the credential: both read `Authorization: Bearer`, this one
   # skips a void API token on sight, and when a request has no
   # credential at all the refusal worth sending is the one that says
   # which authorization server to go to. A route that wants the other
   # order says so with :void.auth/strategies
   :priority 15
   :authenticate oauth-identity
   :challenge (fn oauth-challenge [_]
                (ring/header (ring/text 401 "unauthorized")
                             "www-authenticate" (challenge-header)))})

# -- route metadata: scopes ----------------------------------------------

(plugin/contribute! :void.http/route-meta-key
  {:key :void.auth/scopes
   :schema [:vector :string]
   :doc "OAuth scopes an access token must carry for this route (RFC 6750): a request without them is a 403 with insufficient_scope, not a 401 — the credential was fine, the grant was not"
   # a group's scopes and a route's add up: a route inside an
   # authenticated group needs everything the group needs
   :merge :concat})

(defn required-scopes
  "The scopes a route needs: the ones it declares plus
  `[:auth-oauth :required-scopes]`, which every route needs."
  [rmeta &opt cfg]
  (default cfg settings)
  (distinct (array ;(get cfg :required-scopes [])
                   ;(get rmeta :void.auth/scopes []))))

(defn forbidden
  "The 403 for a valid token that may not do this."
  [wanted]
  (ring/header (ring/text 403 "insufficient scope")
               "www-authenticate"
               (challenge-header "insufficient_scope"
                                 "the access token is missing a required scope"
                                 wanted)))

(plugin/contribute! :void.http/middleware
  {:name :void.auth/scopes
   # between authentication (4000, which bound the identity) and
   # authorization (5000): a scope is what the token was issued for,
   # which is a fact about the credential rather than a decision about
   # the actor
   :phase 4500
   :doc "Enforce :void.auth/scopes — a 403 with insufficient_scope for a token that is valid and insufficient"
   # in the chain for a route that names scopes, and for every route
   # when [:auth-oauth :required-scopes] says every route needs one —
   # evaluated once, at table-build time, against the slice the hook
   # above has already read
   :when (fn [rmeta] (or (not (empty? (get settings :required-scopes [])))
                         (not (empty? (get rmeta :void.auth/scopes [])))))
   :wrap (fn [handler]
           (fn scopes-mw [req]
             (def rmeta (get-in req [:void/route :meta] {}))
             (def wanted (required-scopes rmeta))
             (def id (identity/current))
             (cond
               (empty? wanted) (handler req)
               (nil? id)
               (ring/header (ring/text 401 "unauthorized")
                            "www-authenticate"
                            (challenge-header "invalid_token" "no access token" wanted))
               (not (has-scopes? wanted id))
               (do (log/debug "insufficient scope" :ns log-ns
                              :route (get rmeta :name)
                              :wanted wanted :have (scopes id))
                   (forbidden wanted))
               (handler req))))})

# -- the metadata document -----------------------------------------------

(defn metadata-document
  ``This server's protected-resource metadata (RFC 9728 §2), as data.
  `authorization_servers` defaults to the one issuer configured: a
  resource server that trusts one issuer should not have to say so
  twice.``
  [&opt cfg]
  (default cfg settings)
  # keyword keys: json/encode writes them as the RFC's names, and a
  # janet caller (the suite, `void auth oauth-check`) reads the
  # document back without quoting every field
  (def doc @{:resource (cfg :audience)
             :bearer_methods_supported ["header"]})
  (def servers (or (when-let [s (cfg :authorization-servers)]
                     (unless (empty? s) s))
                   (when-let [i (cfg :issuer)] [i])))
  (when servers (put doc :authorization_servers servers))
  (def scopes-supported
    (or (when-let [s (cfg :scopes-supported)] (unless (empty? s) s))
        (when-let [s (cfg :required-scopes)] (unless (empty? s) s))))
  (when scopes-supported (put doc :scopes_supported scopes-supported))
  (when-let [d (cfg :resource-documentation)] (put doc :resource_documentation d))
  doc)

(defn metadata-handler
  "GET /.well-known/oauth-protected-resource — the document a client
  reads to find out where to get a token. Public by definition: it is
  what an unauthenticated client is sent to."
  [req]
  (if (settings :endpoints)
    (ring/response 200 (json/encode (metadata-document))
                   @{"content-type" "application/json"
                     # the document changes when the deployment does,
                     # and a client that cached it for a day would keep
                     # going to an issuer that is gone
                     "cache-control" "max-age=300, public"})
    (ring/not-found)))

(def- own-routes
  (router/routes {}
    (router/GET metadata-path 'metadata-handler
                {:name :void.auth/resource-metadata
                 :void.auth/access :public})))

# -- config, boot gates, component ---------------------------------------

(defn build-settings
  ``The [:auth-oauth] slice over the defaults, with the two things
  that must be true before a token is ever checked:

  the **audience** is this server's canonical URI and there is no
  sensible default for it — a resource server that accepts any
  audience is the confused deputy RFC 9700 describes, so its absence
  is a boot error rather than a permissive default;

  and there has to be *some* way to check a token: an issuer to
  discover keys from, an explicit JWKS URI, or an introspection
  endpoint.``
  [boot]
  (def cfg (merge defaults (or (get-in boot [:config :values :auth-oauth]) {})))
  (unless (cfg :audience)
    (error (string "[:auth-oauth :audience] is not set. It is this server's canonical "
                   "URI (https://api.example.com/mcp), it is what an access token must "
                   "carry in `aud`, and without it this server would accept tokens "
                   "issued for somebody else — which is the confused-deputy problem MCP's "
                   "authorization spec exists to prevent (RFC 8707, RFC 9700).")))
  (when (and (nil? (cfg :issuer))
             (nil? (cfg :jwks-uri))
             (nil? (get-in cfg [:introspection :url])))
    (error (string "[:auth-oauth] has no way to check a token: set :issuer (its metadata "
                   "publishes jwks_uri), or :jwks-uri directly, or :introspection {:url ...} "
                   "for opaque tokens.")))
  (each a (get cfg :algs default-algs)
    (unless (get jwt/algorithms a)
      (errorf "[:auth-oauth :algs] names %q, which is not a JWS algorithm this build has (%s)"
              a (string/join (map string (sorted (keys jwt/algorithms))) " "))))
  (when (find |(string/has-prefix? "hs" (string $)) (get cfg :algs default-algs))
    (error (string "[:auth-oauth :algs] names an HMAC algorithm. A resource server that "
                   "verifies HS256 holds the key that mints tokens, and a key that can "
                   "verify is then a key that can issue — use RS256/ES256 with the "
                   "issuer's public keys.")))
  cfg)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :auth-oauth/capture-config
   :doc "Read the [:auth-oauth] slice and refuse a resource server with no audience"
   :fn (fn capture [boot] (set settings (build-settings boot)))})

(def keys-component
  (system/component :auth.oauth/keys
    :doc "The issuer's public keys, opened once and held for the
    process (documents the lifetime). Fetched lazily on the first token
    rather than at :start: an authorization server that is down must not
    stop this application from starting, and a process that never sees a
    token never calls it at all."
    :deps [:crypto/lib]
    :start
    (fn start [_ _]
      (def ring @{:keys @{} :metadata nil :fetched 0 :last-attempt -1000 :error nil})
      (set current-ring ring)
      ring)
    :stop
    (fn stop [ring]
      (free-keys! ring)
      (set current-ring nil)
      ring)
    :health
    (fn health [ring]
      {:status (if (ring :error) :degraded :up)
       :keys (length (ring :keys))
       :issuer (settings :issuer)
       :audience (settings :audience)
       :last-error (ring :error)})))

(plugin/contribute! :void.core/cli
  {:name :auth/oauth-check
   :doc "Fetch the issuer's metadata and keys and report what this resource server would accept: void auth oauth-check"
   :read-only? true
   :needs [:auth.oauth/keys]
   :fn (fn cli-check [ring & _]
         (printf "resource:  %s" (or (settings :audience) "(unset)"))
         (printf "issuer:    %s" (or (settings :issuer) "(none — jwks-uri or introspection only)"))
         (printf "mode:      %q" (settings :mode))
         (printf "algorithms: %s"
                 (string/join (map string (get settings :algs default-algs)) " "))
         (when (settings :issuer)
           (def [ok doc] (protect (discover ring)))
           (if ok
             (do (printf "metadata:  %s" (get doc :issuer "(no issuer field)"))
                 (printf "jwks_uri:  %s" (get doc :jwks_uri "(none)"))
                 (printf "introspection_endpoint: %s"
                         (get doc :introspection_endpoint "(none)")))
             (printf "metadata:  UNREACHABLE — %s"
                     (if (string? doc) doc (describe doc)))))
         (def [ok n] (protect (refresh-keys! ring)))
         (if ok
           (do (printf "keys:      %d" n)
               (each [kid entry] (pairs (ring :keys))
                 (printf "  %-24s %s" kid (string (entry :alg)))))
           (printf "keys:      UNAVAILABLE — %s" (if (string? n) n (describe n))))
         (printf "metadata document: %s" (or (resource-metadata-url) "(no audience)"))
         (print (json/encode (metadata-document))))})

(plugin/defplugin void/auth-oauth
  :doc "The application as an OAuth 2.1 resource server: access tokens verified against the issuer's JWKS (or its introspection endpoint), required to carry this server's audience, with scopes as route metadata and RFC 9728 protected-resource metadata for the client that has to go get a token."
  :version "0.0.1"
  # void/auth-http and not just void/http: the strategy this plugin
  # contributes is called from *its* phase-4000 middleware, and the
  # route metadata a scope sits next to (:void.auth/access) is its key
  :requires {:void/core ">=0.0.1" :void/auth ">=0.0.1" :void/auth-http ">=0.0.1"
             :void/crypto ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :auth-oauth
  :config-schema Config
  :config-defaults defaults
  :components [keys-component]
  :contributes {:void.auth/strategy [strategy]
                :void.http/route-source [{:name :void.auth/oauth-metadata
                                          :routes own-routes
                                          :env (router/env-ref (curenv))}]})
