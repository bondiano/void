### void/oauth/provider — the configured issuers, their metadata and their
### keys.
###
### A provider is configuration, not a catalog entry: `[:oauth
### :providers]` names each one with its issuer, client credentials
### and scopes, and everything else — endpoints, keys — is discovered
### from the issuer's own metadata (RFC 8414 / OpenID Connect
### discovery) and cached, the way the resource server already reads the same
### documents for the resource-server half.
###
### **The two channels are not the same, and the boot check knows it**
### . The authorization endpoint is where the
### *browser* is redirected — the browser speaks TLS itself, so
### `https://` is always legal there. The token endpoint, the metadata,
### the JWKS and userinfo are called by `void/http/client`, which speaks
### TLS exactly when the composition holds `:void/tls`. With the plugin,
### an https back channel just works — a real IdP becomes reachable
### directly. Without it, `https://` in any of those is a **boot error**
### naming the three ways out: the plugin, an internal issuer reachable
### over http, or an egress relay beside the process (the same relay
### `void/mail` stands behind). An `https://` issuer then stays legal as
### the string `iss` is compared against — but the back-channel endpoints
### must be named explicitly, and discovery is off.
###
### The keys are the resource server's ring again, one per provider: fetched lazily
### (a process nobody signs into never calls its issuer), TTL'd, one
### refetch per unknown `kid` behind a cooldown, and freed when replaced
### or at :stop — the one place a key's lifetime ends.

(import spork/json)
(import void/core/config :as config)
(import void/core/log :as log)
(import void/crypto/sign :as sign)
(import void/http/client :as client)
(import void/auth/jwk :as jwk)
(import void/auth/jwt :as jwt)

(def log-ns "void.oauth")

(def default-algs
  "Algorithms accepted for an id_token unless configured otherwise.
  Asymmetric only: an id_token signed with the client secret (HS*) is
  a key that can *issue* tokens sitting in this process's config."
  [:rs256 :es256])

(def provider-defaults
  "What a provider entry says unless it says otherwise."
  {:scopes ["openid"]
   :auth :basic
   :params {}})

(def defaults
  "Defaults of the [:oauth] slice."
  {:mount "/oauth"
   :after-sign-in "/"
   :session-key :void.oauth/pending
   :max-age 600
   :leeway 30
   :cache-ttl 300
   :refresh-cooldown 30
   :timeout 5
   :algs default-algs
   :providers {}})

(def Config
  "Schema of the [:oauth] config slice. Providers are validated by
  hand in `build-settings`: the interesting failures there deserve
  sentences, not paths."
  {:mount [:optional [:union :string :boolean]]
   :base-url [:optional :string]
   :after-sign-in [:optional :string]
   :session-key [:optional :keyword]
   :max-age [:optional [:number {:min 1}]]
   :leeway [:optional [:number {:min 0}]]
   :cache-ttl [:optional [:number {:min 0}]]
   :refresh-cooldown [:optional [:number {:min 0}]]
   :timeout [:optional [:number {:min 0.1}]]
   :algs [:optional [:vector :keyword]]
   :providers [:optional :dictionary]})

(var settings
  "The [:oauth] slice, read at :before-start."
  defaults)

(defn secret-value
  "A config value that may be a secret box (`{:secret \"ENV\"}`)."
  [v]
  (when v (if (config/secret? v) (config/reveal v) v)))

(defn- https? [url]
  (and (bytes? url) (string/has-prefix? "https://" (string url))))

(def- back-channel-keys
  # everything void/http/client calls itself; :authorization-endpoint
  # is deliberately not here — the browser goes there, not us
  [:metadata-url :token-endpoint :jwks-uri :userinfo-endpoint])

(def- relay-text
  (string "This composition has no TLS, and the back channel is called by "
          "void/http/client. Add :void/tls to :plugins, or reach the "
          "issuer over http (an internal IdP), or put an egress relay beside this "
          "process and name its plaintext side."))

(defn openid?
  "Does this provider ask for an id_token?"
  [p]
  (truthy? (index-of "openid" (get p :scopes []))))

(defn- check-provider
  "One provider entry, validated into its resolved form — or a boot
  error whose text names the provider and the way out."
  [name p top]
  (unless (dictionary? p)
    (errorf "[:oauth :providers %q] must be a dictionary, got %q" name p))
  (def resolved
    (merge provider-defaults
           {:algs (top :algs) :name name}
           p))
  (unless (resolved :client-id)
    (errorf "[:oauth :providers %q] has no :client-id — the id this application registered at the authorization server" name))
  (unless (or (resolved :issuer) (resolved :authorization-endpoint))
    (errorf "[:oauth :providers %q] has nowhere to send the browser: set :issuer (its metadata names the authorization endpoint) or :authorization-endpoint directly" name))
  (unless (or (resolved :issuer) (resolved :token-endpoint))
    (errorf "[:oauth :providers %q] has nowhere to exchange the code: set :issuer or :token-endpoint" name))
  # with :void/tls composed the back channel speaks https itself and these
  # gates have nothing to refuse
  (unless (client/tls-available?)
    (each key back-channel-keys
      (when (https? (resolved key))
        (errorf "[:oauth :providers %q %q] is an https URL. %s" name key relay-text)))
    (when (https? (resolved :issuer))
      # the issuer string stays what `iss` is compared against; only
      # the calls move
      (unless (resolved :token-endpoint)
        (errorf "[:oauth :providers %q] names an https issuer, so discovery cannot be called — set :token-endpoint explicitly (over http, through a relay). %s" name relay-text))
      (when (and (openid? resolved) (nil? (resolved :jwks-uri)))
        (errorf "[:oauth :providers %q] asks for openid under an https issuer — set :jwks-uri explicitly (over http, through a relay), or drop \"openid\" from :scopes. %s" name relay-text))))
  (each a (resolved :algs)
    (unless (get jwt/algorithms a)
      (errorf "[:oauth :providers %q :algs] names %q, which is not a JWS algorithm this build has (%s)"
              name a (string/join (map string (sorted (keys jwt/algorithms))) " "))))
  (when (find |(string/has-prefix? "hs" (string $)) (resolved :algs))
    (errorf "[:oauth :providers %q :algs] names an HMAC algorithm. An id_token verified with HS* is signed with the client secret, and a key that verifies is then a key that can issue — use RS256/ES256 with the issuer's published keys" name))
  (freeze resolved))

(defn redirect-uri
  ``The exact redirect URI this provider was registered with: the
  provider's own `:redirect-uri`, or `[:oauth :base-url]` + mount +
  the provider's callback path. Never derived from a Host header —
  that would hand the parameter the authorization server compares
  byte-for-byte to whoever writes the request (RFC 9700).``
  [p &opt cfg]
  (default cfg settings)
  (or (p :redirect-uri)
      (when-let [base (cfg :base-url)]
        (string (if (string/has-suffix? "/" base) (string/slice base 0 -2) base)
                (cfg :mount) "/" (p :name) "/callback"))))

(defn build-settings
  "The [:oauth] slice over the defaults, with every gate the design
  names run before a single browser is redirected."
  [boot]
  (def raw (or (get-in boot [:config :values :oauth]) {}))
  (def top (merge defaults raw))
  (def providers @{})
  (eachp [name p] (get top :providers {})
    (put providers name (check-provider name p top)))
  (put top :providers (freeze providers))
  (def mounted? (truthy? (top :mount)))
  (when mounted?
    (eachp [name p] (top :providers)
      (unless (redirect-uri p top)
        (errorf "[:oauth :providers %q] has no redirect URI: set [:oauth :base-url] (this application's canonical external URL) or the provider's :redirect-uri. It must be the exact URI registered at the authorization server — deriving it from the Host header is how a request smuggles its own (RFC 9700)" name))))
  top)

(defn provider
  "The resolved provider `name`, or a readable error listing the ones
  this composition has."
  [name &opt cfg]
  (default cfg settings)
  (or (get-in cfg [:providers (keyword name)])
      (errorf "unknown OAuth provider %q (configured: %s)"
              name
              (let [known (sorted (keys (get cfg :providers {})))]
                (if (empty? known) "none" (string/join (map string known) " "))))))

# -- the rings -----------------------------------------------------------

(var current-rings
  "The running :oauth/providers component — one ring per provider."
  nil)

(defn make-ring
  "A fresh ring — what the component builds per provider, and what a
  test hands in directly."
  []
  @{:metadata nil :keys @{} :fetched 0 :last-attempt -1000 :error nil})

(defn ring-for
  "The running ring of a provider, or a readable error."
  [name]
  (unless current-rings
    (error "void/oauth is not started — add :void/oauth to :plugins (the :oauth/providers component holds the issuers' metadata and keys)"))
  (or (get current-rings name)
      (errorf "no ring for provider %q — is it in [:oauth :providers]?" name)))

(defn free-keys!
  "Free every opened key of a ring — replacement and :stop, the two
  ends of a key's lifetime."
  [ring]
  (each entry (values (ring :keys))
    (protect (sign/free-key (entry :key))))
  (put ring :keys @{}))

(defn fetch-json
  "GET a URL and decode JSON, or throw with the status in the text."
  [url timeout]
  (def resp (client/get url {:timeout timeout
                             :headers {"accept" "application/json"}}))
  (unless (and (>= (resp :status) 200) (< (resp :status) 300))
    (errorf "%s answered %d" url (resp :status)))
  (json/decode (string (or (resp :body) "")) true))

(defn discover
  ``The issuer's metadata for a provider (RFC 8414 first, the OpenID
  Connect document second — an issuer that publishes only the latter
  is common and means the same thing). Cached on the ring: endpoints
  do not move, and a discovery call per login would put the issuer on
  this application's login path.``
  [ring p &opt cfg]
  (default cfg settings)
  (or (ring :metadata)
      (let [issuer (or (p :issuer)
                       (errorf "provider %q has no :issuer — there is nothing to discover" (p :name)))
            base (if (string/has-suffix? "/" issuer) (string/slice issuer 0 -2) issuer)
            urls (if-let [u (p :metadata-url)]
                   [u]
                   [(string base "/.well-known/oauth-authorization-server")
                    (string base "/.well-known/openid-configuration")])]
        (var found nil)
        (var last-err nil)
        (each url urls
          (unless found
            (def [ok doc] (protect (fetch-json url (cfg :timeout))))
            (if ok (set found doc) (set last-err doc))))
        (unless found
          (errorf "cannot read the metadata of %q: %s"
                  issuer (if (string? last-err) last-err (describe last-err))))
        # RFC 8414 §3.3: a document that names another issuer is either
        # misconfigured or somebody else's
        (when-let [named (get found :issuer)]
          (unless (= (string named) (string issuer))
            (errorf "metadata for %q says issuer %q" issuer named)))
        (put ring :metadata found)
        found)))

(defn- need [p value what config-key]
  (or value
      (errorf "provider %q has no %s: set %q, or an :issuer whose metadata publishes it"
              (p :name) what config-key)))

(defn authorization-endpoint
  "Where the browser is sent — the one endpoint that may be https."
  [ring p &opt cfg]
  (need p (or (p :authorization-endpoint)
              (get (discover ring p cfg) :authorization_endpoint))
        "authorization endpoint" :authorization-endpoint))

(defn token-endpoint
  "Where the code (and later a refresh token) is exchanged."
  [ring p &opt cfg]
  (need p (or (p :token-endpoint)
              (get (discover ring p cfg) :token_endpoint))
        "token endpoint" :token-endpoint))

(defn jwks-uri
  "Where the issuer's signing keys are published."
  [ring p &opt cfg]
  (need p (or (p :jwks-uri)
              (get (discover ring p cfg) :jwks_uri))
        "JWKS" :jwks-uri))

(defn userinfo-endpoint
  "The userinfo endpoint, or nil — a plain OAuth2 provider has none,
  and the sign-in hook then reads the profile itself."
  [ring p &opt cfg]
  (or (p :userinfo-endpoint)
      (when (p :issuer)
        # best-effort: a provider whose metadata is unreachable simply
        # has no userinfo, and the hook reads the profile itself
        (protect (discover ring p cfg))
        (get (or (ring :metadata) {}) :userinfo_endpoint))))

# -- keys ----------------------------------------------------------------

(defn refresh-keys!
  "Fetch a provider's JWKS and open every usable key; replaced keys
  are freed here. Returns the number held."
  [ring p &opt cfg]
  (default cfg settings)
  (def now (os/clock :monotonic))
  (put ring :last-attempt now)
  (def doc (fetch-json (jwks-uri ring p cfg) (cfg :timeout)))
  (def accepted (get p :algs default-algs))
  (def opened @{})
  (var index 0)
  (each k (jwk/signing-keys doc)
    (when (index-of (k :alg) accepted)
      (def [ok key] (protect (sign/public-key (k :pem))))
      (if ok
        (put opened (or (k :kid) (string "#" (++ index)))
             {:alg (k :alg) :key key :kid (k :kid)})
        (log/warn "a JWKS key would not open" :ns log-ns
                  :provider (p :name) :kid (k :kid) :alg (k :alg)
                  :err (if (string? key) key (describe key))))))
  (free-keys! ring)
  (put ring :keys opened)
  (put ring :fetched now)
  (put ring :error nil)
  (log/debug "JWKS fetched" :ns log-ns :provider (p :name) :keys (length opened))
  (length opened))

(defn- ensure-keys! [ring p cfg]
  (def now (os/clock :monotonic))
  (when (or (empty? (ring :keys))
            (> (- now (get ring :fetched 0)) (cfg :cache-ttl)))
    (when (> (- now (get ring :last-attempt -1000)) (cfg :refresh-cooldown))
      (def [ok err] (protect (refresh-keys! ring p cfg)))
      (unless ok
        (put ring :error (if (string? err) err (describe err)))
        (log/warn "JWKS refresh failed" :ns log-ns
                  :provider (p :name) :err (ring :error)))))
  (ring :keys))

(defn- key-for
  # an unknown kid is the rotation signal and worth exactly one
  # refetch, behind the cooldown — an id_token is attacker-visible
  # input, and inventing kids must not dial this process's issuer
  [ring p cfg kid]
  (def keys (ensure-keys! ring p cfg))
  (or (when kid (get keys kid))
      (when (and kid (> (- (os/clock :monotonic) (get ring :last-attempt -1000))
                        (cfg :refresh-cooldown)))
        (def [ok] (protect (refresh-keys! ring p cfg)))
        (when ok (get (ring :keys) kid)))
      (when (and (nil? kid) (= 1 (length keys)))
        (first (values keys)))))

# -- the id_token --------------------------------------------------------

(defn- no [reason] {:ok false :reason reason})

(defn verify-id-token
  ``Verify an id_token against the provider's keys and this flow's
  facts. `nonce` is what the authorization request sent; a token that
  does not echo it is a replay. Returns `{:ok true :claims}` or
  `{:ok false :reason}` — the reason is for the log, never for the
  visitor.``
  [tok p nonce &opt cfg ring]
  (default cfg settings)
  (default ring (ring-for (p :name)))
  (def peeked (jwt/peek tok))
  (cond
    (nil? peeked) (no "not a JWS")
    (let [kid (get-in peeked [:header :kid])
          entry (key-for ring p cfg (when kid (string kid)))]
      (cond
        (nil? entry) (no (string/format "no key for kid %q" kid))

        # the key's own algorithm is the only one accepted for it —
        # the same rule the resource server states for access tokens, for the
        # same reason: the header naming the algorithm is written by
        # whoever handed us the token
        (not (index-of (entry :alg) (get p :algs default-algs)))
        (no (string/format "key %q signs %q, which is not accepted here" kid (entry :alg)))

        (let [[ok out] (protect (jwt/decode-token tok
                                                  {:alg [(entry :alg)]
                                                   :key (entry :key)
                                                   :issuer (p :issuer)
                                                   # the client's audience is
                                                   # itself: its client id
                                                   :audience (p :client-id)
                                                   :leeway (cfg :leeway)}))]
          (cond
            (not ok)
            (do (log/warn "verifying an id_token raised" :ns log-ns
                          :provider (p :name)
                          :err (if (string? out) out (describe out)))
                (no "the id_token could not be verified"))

            (not (out :ok)) out

            (let [claims (out :claims)]
              (cond
                # the nonce ties the token to the request this process
                # made seconds ago; without the check any captured
                # id_token for this client replays forever
                (and nonce (not= (string (get claims :nonce ""))
                                 (string nonce)))
                (no "nonce does not match this flow")

                # with several audiences OIDC says azp names the party
                # the token was issued to — and it had better be us
                (and (get claims :azp)
                     (not= (string (claims :azp)) (string (p :client-id))))
                (no "azp names another client")

                {:ok true :claims claims}))))))))
