### void/security — CSRF, headers, CORS and rate limiting
### (SPEC.md §5.16, ADR-0025).
###
### Four things that are on by default in Rails, Laravel and Spring and
### without which a server-rendered framework cannot be released. Each
### of them has exactly one decision that decides whether it works in a
### real application, and ADR-0025 is about those four decisions:
###
###   **CSRF** applies to requests whose credential rode on a **cookie**
###   — not to every unsafe method, which would break every JSON API
###   and could never be switched off again given the frozen
###   `:restrict` merge on `:void.security/csrf` (true wins).
###
###   **Headers and CORS** are applied at the **edge**
###   (`:void.http/edge`), because middleware wraps a route's chain and
###   a 404, a static file, a rendered 500 and a preflight to a path
###   with no route are all outside every chain there is.
###
###   **Rate limiting** stands on the `:void/cache-store` contract
###   rather than a new one: memory and redis implementations already
###   exist, and a shared counter across a fleet is then a matter of
###   composing `void/cache-redis`.
###
###   **The client IP** is computed from trusted proxies rather than
###   read from a header anybody can send.
###
### What an application composes:
###
###     (void/run! {:plugins [:void/crypto :void/security ...]})
###     # config/prod.janet
###     {:security {:secret {:secret "VOID_SECRET"}
###                 :trusted-proxies ["10.0.0.0/8"]
###                 :hsts {:max-age 31536000 :include-subdomains true}
###                 :rate {:store :cache :global {:limit 300 :window 60}}}}
###
### and marks what needs more:
###
###     (defroutes api {}
###       [:post "/login" login {:void.security/rate {:limit 5 :window 60}}]
###       [:post "/webhook" hook {:void.security/csrf false}])   ; ← refused
###
### — the last line is a boot error, and deliberately: `:restrict` means
### a route may only tighten, so there is no way to open a hole in a
### group's protection from inside it.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/core/system :as system)
(import void/http :as http)
(import void/http/ring :as ring)
(import void/crypto :as crypto)
(import ./secret :as secret)
(import ./csrf :as csrf)
(import ./csp :as csp)
(import ./headers :as headers)
(import ./cors :as cors)
(import ./limit :as limit)
(import ./ip :as ip)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.security")

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:security] config slice."
  {:signing-key [:optional :any]
   :previous-keys [:optional [:vector :any]]
   :trusted-proxies [:optional [:vector :string]]
   :forwarded-header [:optional :string]
   :csrf [:optional :dictionary]
   :headers [:optional :dictionary]
   :csp [:optional :dictionary]
   :cors [:optional :dictionary]
   :rate [:optional :dictionary]})

(def defaults
  ``Defaults of the [:security] slice.

  CSRF and the headers are **on**; CORS and the rate limiter are
  **off** until configured. The asymmetry is not an accident: the
  first two are safe for every application and cost nothing to leave
  on, while a CORS allowlist and a rate limit are numbers only the
  deployment knows, and a guessed default would be either useless or
  an outage.``
  {:signing-key nil
   :previous-keys []
   :trusted-proxies []
   :forwarded-header "x-forwarded-for"
   :csrf csrf/defaults
   :headers headers/defaults
   :csp {:enabled true :report-only false :policy csp/defaults}
   :cors cors/defaults
   :rate (merge limit/defaults {:enabled false :global nil})})

(var settings
  "The [:security] slice, resolved at :before-start — the wrappers run
  on the hot path and have no business reaching into the boot value
  there."
  defaults)

(var computed-headers
  "The static header table, built once at boot."
  @{})

(var limiter-store
  "The store the rate limiter counts in."
  nil)

(defn- merge-slice [cfg]
  (def c (merge defaults (or cfg {})))
  (each key [:csrf :headers :cors]
    (put c key (merge (defaults key) (get cfg key {}))))
  (put c :rate (merge (defaults :rate) (get cfg :rate {})))
  (put c :csp (merge (defaults :csp) (get cfg :csp {})))
  (when-let [policy (get-in cfg [:csp :policy])]
    (put c :csp (merge (c :csp) {:policy policy})))
  c)

(defn- ip-config [cfg]
  {:trusted-proxies (get cfg :trusted-proxies [])
   :forwarded-header (get cfg :forwarded-header "x-forwarded-for")})

# -- public surface ------------------------------------------------------

(def nonce-dyn
  "Dyn the per-request CSP nonce is bound to."
  :void.security/nonce)

(defn nonce
  ``This request's CSP nonce, or nil when the policy does not use one.
  A template puts it on an inline script: `[:script {:nonce
  (security/nonce)} ...]`.``
  []
  (dyn nonce-dyn))

(defn csrf-token
  "The CSRF token for this request — what a form field or a fetch()
  header carries."
  [req]
  (csrf/token-for req (settings :csrf)))

(defn csrf-field
  "The hidden input, as hiccup. void/html splices it into every non-GET
  form on its own; this is for a form built by hand."
  [req]
  (csrf/field-markup req (settings :csrf)))

(defn htmx-meta
  ``The `<meta>` tags htmx (and any fetch()) reads the token from:

      (html/page {:head (security/htmx-meta req)} ...)``
  [req]
  (csrf/meta-markup req (settings :csrf)))

(defn htmx-attrs
  "The `hx-headers` attribute for `<body>`, so every htmx request
  carries the token."
  [req]
  (csrf/hx-headers req (settings :csrf)))

(defn client-ip
  "The address this request is attributed to (ADR-0025 §6)."
  [req]
  (ip/client-ip req (ip-config settings)))

(def sign "See secret/sign." secret/sign)
(def valid-signature? "See secret/valid?." secret/valid?)
(def rate-check! "See limit/check! — count one request against a key." limit/check!)
(def memory-rate-store "See limit/memory-store." limit/memory-store)
(def render-csp "See csp/render." csp/render)
(def compute-headers "See headers/compute." headers/compute)

# -- boot ----------------------------------------------------------------

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 400
   :name :security/configure
   :doc "Resolve the [:security] slice, install the signing keys and build the static header table"
   :fn (fn configure [boot]
         (def cfg (merge-slice (get-in boot [:config :values :security])))
         (secret/configure! cfg (get boot :profile :dev))
         (csp/validate (get-in cfg [:csp :policy] {}))
         (cors/validate (cfg :cors))
         (set settings cfg)
         (set computed-headers (headers/compute (cfg :headers)))
         (log/info "security ready" :ns log-ns
                   :csrf (get-in cfg [:csrf :enabled])
                   :headers (not (empty? computed-headers))
                   :csp (get-in cfg [:csp :enabled])
                   :cors (get-in cfg [:cors :enabled])
                   :rate (get-in cfg [:rate :enabled])
                   :trusted-proxies (length (cfg :trusted-proxies))))})

(defn- cache-store [boot]
  (def [ok inst] (protect (system/instance (boot :system) :void/cache-store)))
  (when ok inst))

(defn- resolve-limiter-store
  "The store [:security :rate :store] names, resolved against a
  running system. Called at :after-start for the wrappers, and again
  by the deployment survey — `void deploy check` starts the components
  a store declaration needs without running the start hooks."
  [boot cfg]
  (case (get cfg :store :memory)
    :cache (or (cache-store boot)
               (error (string "[:security :rate :store] is :cache, but this "
                              "composition has no :void/cache-store — add "
                              ":void/cache (and :void/cache-redis for a counter "
                              "several replicas share)")))
    :memory (limit/memory-store)
    (errorf "[:security :rate :store] must be :memory or :cache, got %q"
            (get cfg :store))))

(plugin/contribute! :void.core/hooks
  {:hook :after-start
   :phase 200
   :name :security/limiter-store
   :doc "Resolve the rate limiter's store once the components are up"
   # nothing here looks at [:http :workers] any more: "the effective
   # limit is the configured one times the number of counters" is true
   # of a second machine exactly as it is of a second worker, and the
   # deployment shape asks that once, for everybody, through the
   # :void.core/store declaration below (ADR-0030)
   :fn (fn limiter [boot]
         (def cfg (settings :rate))
         (when (get cfg :enabled)
           (set limiter-store (resolve-limiter-store boot cfg))))})

(plugin/contribute! :void.core/store
  {:name :void.security/rate
   :what "the rate limiter's counters"
   :doc "Where the rate limiter counts — one counter for the deployment, or one per process"
   :ask (fn ask-limiter [boot]
          (def cfg (settings :rate))
          (when (get cfg :enabled)
            (def st (or limiter-store (resolve-limiter-store boot cfg)))
            {:store (get st :name :anonymous)
             :shared? (truthy? (get st :shared?))
             # the arithmetic, not the mechanism: an operator reading
             # this has to be told that the number in their config is
             # not the number they get
             :replacement "set [:security :rate :store] :cache and compose void/cache-redis — with a counter per process the effective limit is the configured one times the number of replicas"}))})

# -- route metadata ------------------------------------------------------

(plugin/contribute! :void.http/route-meta-key
  {:key :void.security/csrf
   :schema :boolean
   :doc "Demand a CSRF token on this route even when the credential did not ride on a cookie (SPEC part II §2.5). :restrict, true wins — protection can be tightened by a more specific layer and never loosened, so there is no key that switches it off"
   :merge :restrict
   :allow? (fn [outer inner] (or inner (not outer)))})

(plugin/contribute! :void.http/route-meta-key
  {:key :void.security/rate
   :schema {:limit [:int {:min 1}]
            :window [:number {:min 1}]
            :key [:optional [:or :keyword :function]]}
   :doc "Rate limit for this route: {:limit 5 :window 60 :key :ip|:subject|(fn [req])}. :restrict — a route may only lower the rate it inherits, never raise it"
   :merge :restrict
   :allow? (fn [outer inner]
             # tightening means a lower rate: requests per second may go
             # down, never up
             (<= (/ (inner :limit) (inner :window))
                 (/ (outer :limit) (outer :window))))})

# -- the edge: headers, CSP, CORS ---------------------------------------

(plugin/contribute! :void.http/edge
  {:name :void.security/cors
   :phase 100
   :doc "Answer CORS preflights before routing (a path usually has no OPTIONS route) and add the response headers to everything else"
   :wrap
   (fn [handler]
     (fn security-cors [req]
       (def cfg (settings :cors))
       (if (and (get cfg :enabled) (cors/preflight? req))
         (cors/preflight-response req cfg)
         (cors/decorate! req (handler req) cfg))))})

(plugin/contribute! :void.http/edge
  {:name :void.security/headers
   :phase 200
   :doc "Stamp the security headers and the CSP on every response — including the 404s, static files and rendered 500s that no route produced"
   :wrap
   (fn [handler]
     (fn security-headers [req]
       (def csp-cfg (settings :csp))
       (def policy (get csp-cfg :policy {}))
       (def wants-nonce (and (get csp-cfg :enabled) (csp/needs-nonce? policy)))
       # a nonce is 16 bytes of randomness per request: generated only
       # when the policy actually mentions one
       (def n (when wants-nonce (crypto/token 16)))
       (def resp (if n
                   (with-dyns [nonce-dyn n] (handler req))
                   (handler req)))
       (headers/apply! resp computed-headers)
       (when (and (get csp-cfg :enabled) (dictionary? resp) (not (empty? policy)))
         (def name (csp/header-name (get csp-cfg :report-only)))
         (unless (get-in resp [:headers name])
           (ring/header resp name (csp/render policy n))))
       resp))})

# -- CSRF ----------------------------------------------------------------

(defn- csrf-cookie! [req resp cfg]
  ``Make sure the browser has something to bind a token to. Only when
  the request had no session and no CSRF cookie — a session-bearing
  request binds to the session and needs no cookie of ours.``
  (when (and (dictionary? resp) (nil? (csrf/binding-of req cfg)))
    (when-let [fresh (get req :void.security/fresh-binding)]
      (ring/set-cookie resp (get cfg :cookie "void-csrf") fresh
                       (get cfg :cookie-opts {:path "/" :same-site :lax}))))
  resp)

(defn refused
  "The 403 for a request whose CSRF token was missing or wrong — through
  the error renderers, like every other refusal in void."
  [req]
  (http/render-error {:http/status 403 :message "invalid CSRF token"} req 403))

(plugin/contribute! :void.http/middleware
  {:name :void.security/csrf
   # after auth (4000): whether the credential rode on a cookie is
   # something only the identity knows
   :phase 4500
   :doc "Verify the CSRF token on unsafe requests whose credential rode on a cookie; bind the token for the form slot and the meta tag"
   :wrap
   (fn [handler]
     (fn security-csrf [req]
       (def cfg (settings :csrf))
       (if-not (get cfg :enabled true)
         (handler req)
         (let [rmeta (get-in req [:void/route :meta] {})]
           # a request with neither a session nor a cookie of ours gets
           # a binding now, so that the token this page carries can be
           # verified when it comes back
           (unless (csrf/binding-of req cfg)
             (put req :void.security/fresh-binding (crypto/token 16)))
           (if (and (csrf/applies? req rmeta cfg)
                    (not (csrf/verify (csrf/presented req cfg)
                                      (or (csrf/binding-of req cfg)
                                          (get req :void.security/fresh-binding))
                                      cfg)))
             (do
               (log/info "CSRF token missing or invalid" :ns log-ns
                         :route (get rmeta :name) :method (get req :method))
               (csrf-cookie! req (refused req) cfg))
             # the slot void/html has been waiting with since wave 1:
             # every non-GET form renders the hidden field, and nothing
             # renders when this plugin is absent
             (let [resp (with-dyns [:void.html/csrf (fn [] (csrf/field-markup req cfg))]
                          (handler req))]
               (csrf-cookie! req resp cfg)))))))})

# -- rate limiting -------------------------------------------------------

(defn- rate-config [rmeta]
  (def cfg (settings :rate))
  (def route (get rmeta :void.security/rate))
  (when (get cfg :enabled)
    (when-let [spec (or route (get cfg :global))]
      (merge cfg spec))))

(defn- rate-key [req spec]
  (def key (get spec :key :ip))
  (cond
    (function? key) (key req)
    (= :subject key) (or (get-in req [:void.auth/identity :subject])
                         # an anonymous request under a subject limit
                         # falls back to the address, or one visitor
                         # would spend everybody's budget
                         (client-ip req))
    (client-ip req)))

(defn- limited [req spec result]
  (def resp (http/render-error {:http/status (get spec :status 429)
                                :message (get spec :message "too many requests")}
                               req (get spec :status 429)))
  (eachp [name value] (limit/headers-for result)
    (ring/header resp name value))
  resp)

(defn- rate-wrapper [phase name subject?]
  {:name name
   :phase phase
   :doc (if subject?
          "Rate limit keyed by the authenticated subject — after auth, because there is no subject before it"
          "Rate limit keyed by the client address, in phase 200: before parsing, sessions or a pooled connection, because a refusal should not be paid for")
   :when (fn [rmeta]
           (def spec (rate-config rmeta))
           (and spec
                (let [key (get spec :key :ip)]
                  (if subject? (not= :ip key) (= :ip key)))))
   :wrap
   (fn [handler]
     (fn security-rate [req]
       (def spec (rate-config (get-in req [:void/route :meta] {})))
       (if-not (and spec limiter-store)
         (handler req)
         (let [key (rate-key req spec)
               result (limit/check! limiter-store (string key) spec)]
           (when (result :error)
             (log/warn "rate limiter store failed" :ns log-ns
                       :err (result :error) :on-error (get spec :on-error)))
           (if (result :allowed)
             (let [resp (handler req)]
               (when (dictionary? resp)
                 (eachp [n v] (limit/headers-for result) (ring/header resp n v)))
               resp)
             (do
               (log/info "rate limited" :ns log-ns
                         :route (get-in req [:void/route :meta :name])
                         :key key :limit (spec :limit) :window (spec :window))
               (limited req spec result)))))))})

(plugin/contribute! :void.http/middleware
  (rate-wrapper 200 :void.security/rate-ip false))

(plugin/contribute! :void.http/middleware
  (rate-wrapper 4400 :void.security/rate-subject true))

# -- CLI -----------------------------------------------------------------

(defn print-status
  "Print what this process will send — the body of `void security
  headers`."
  []
  (print "response headers")
  (if (empty? computed-headers)
    (print "  (none — [:security :headers :enabled] is false)")
    (each [name value] (sorted (pairs computed-headers))
      (printf "  %-32s %s" name value)))
  (def csp-cfg (settings :csp))
  (printf "content-security-policy  %s"
          (if (get csp-cfg :enabled)
            (if (get csp-cfg :report-only) "(report-only)" "(enforcing)")
            "(off)"))
  (when (get csp-cfg :enabled)
    (printf "  %s" (csp/render (get csp-cfg :policy {}) "<per-request>")))
  (printf "csrf     %s (field %q, header %q)"
          (if (get-in settings [:csrf :enabled]) "on" "off")
          (get-in settings [:csrf :field])
          (get-in settings [:csrf :header]))
  (printf "cors     %s%s"
          (if (get-in settings [:cors :enabled]) "on" "off")
          (if (get-in settings [:cors :enabled])
            (string " — origins: " (string/join (map string (get-in settings [:cors :origins])) " "))
            ""))
  (printf "rate     %s%s"
          (if (get-in settings [:rate :enabled]) "on" "off")
          (if (get-in settings [:rate :enabled])
            (string/format " — store %q, global %q" (get-in settings [:rate :store])
                           (get-in settings [:rate :global]))
            ""))
  (printf "proxies  %s"
          (if (empty? (settings :trusted-proxies))
            "none trusted — the client address is the socket peer"
            (string/join (settings :trusted-proxies) " ")))
  (printf "keys     %d%s" (length secret/keys)
          (if (secret/rotated?) " (rotation in progress)" "")))

(plugin/contribute! :void.core/cli
  {:name :security/headers
   :doc "Show the security headers, the CSP and what is enabled: void security headers"
   :fn (fn cli-headers [& args]
         (unless (empty? args)
           (errorf "void security headers takes no arguments (got %q)"
                   (string/join args " ")))
         (print-status))})

(plugin/contribute! :void.core/health
  {:name :security/config
   :fn (fn security-health []
         {:status :up
          :csrf (get-in settings [:csrf :enabled])
          :csp (get-in settings [:csp :enabled])
          :cors (get-in settings [:cors :enabled])
          :rate (get-in settings [:rate :enabled])
          :keys (length secret/keys)})})

(plugin/defplugin void/security
  :doc "CSRF bound to whatever carried the credential and always signed, security headers and a CSP built from data, CORS answered at the edge where a preflight to an unrouted path can still be seen, rate limiting over the :void/cache-store contract, and a client IP computed from trusted proxies rather than read from a header."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/crypto ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :security
  :config-schema Config
  :config-defaults defaults)
