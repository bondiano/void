### void/auth-http — the strategies that read a request, and the
### enforcement.
###
### The half of void/auth that needs the HTTP kernel, kept a separate
### plugin so a jobs worker never drags it in — what `void/cache-http`
### is to `void/cache`. Three things live here:
###
### **The request strategies.** `:session` reads the identity a login
### put in the session; `:bearer` reads an API token from the
### Authorization header; `:jwt` reads a JWS from the same header. The
### last two coexist without ambiguity because a void token carries a
### prefix (`vt_`) and `token/parse` declines anything else, so the
### bearer strategy passes and the JWT one picks it up.
###
### **Login and logout.** `login!` puts the subject in the session and
### **rotates the session id** (`session/rotate!`): an id
### that survives a change of privilege is session fixation, and the
### only moment it can be changed is this one.
###
### **Enforcement**, in the reserved phase 4000 — after the session
### (3000), before authz (5000). Every route gets the identity bound in
### a dyn, because a public page still wants to say "signed in as…";
### routes marked `:void.auth/access :required` get a 401 or a redirect
### when there is nobody. That answer goes out **through the error
### renderers** rather than by raising: a stack trace per unauthorized
### request is a bill that arrives exactly when somebody is trying
### passwords, which is the same argument `void/pressure-http` makes
### about its 503.
###
### What the session holds is the **subject**, not the user: claims are
### re-read from the user store on each request (`[:auth-http :session
### :load] :store`), so a revoked role stops applying at the next
### request rather than at the next login. An application that would
### rather trade freshness for a store read sets `:session`, and the
### claims then come from what the login put there.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/core/config :as config)
(import void/http :as http)
(import void/http/ring :as ring)
(import void/http/session :as http-session)
(import void/http/wire :as wire)
(import ./identity :as identity)
(import ./strategy :as strategy)
(import ./state :as state)
(import ./token :as token)
(import ./jwt :as jwt)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.auth.http")

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:auth-http] config slice."
  {:default [:optional [:enum :public :required]]
   :unauthenticated [:optional [:enum :status :redirect]]
   :login-path [:optional :string]
   :status [:optional [:int {:min 400 :max 499}]]
   :realm [:optional :string]
   :session [:optional :dictionary]
   :jwt [:optional :dictionary]})

(def defaults
  ``Defaults of the [:auth-http] slice.

  `:default :public` — a route that says nothing about access is not
  protected, so composing this plugin does not lock an existing
  application out of itself. `:required` flips it, and then a public
  route says so; that is the deny-by-default posture, and it belongs
  to an application that has decided to take it.

  `:unauthenticated :status` answers 401. An application with login
  forms sets `:redirect` and gets a 302 to `:login-path` with `?next=`
  — which is wrong for an API and right for a browser, and void
  cannot tell which one an application is from here.

  `[:session :load] :store` re-reads the user on every request, so a
  claim revoked in the database applies at the next request. `:session`
  trusts what the login stored: one store read cheaper, and stale
  until the next login.

  `[:jwt :key]` is the HMAC secret or the PEM of a verifying key. It
  is **not** spelled `:secret`, because `{:secret "NAME"}` is how
  void/core/config references an environment variable — which is exactly
  how this key should be supplied in production:

      {:auth-http {:jwt {:key {:secret "JWT_SIGNING_KEY"}}}}

  and a resolved secret box is unwrapped here.``
  {:default :public
   :unauthenticated :status
   :login-path "/login"
   :status 401
   :realm "void"
   :session {:key :void.auth/session
             :load :store
             :idle-timeout 0
             :absolute-timeout 0}
   :jwt {:alg :hs256
         :key nil
         :issuer nil
         :audience nil
         :leeway jwt/default-leeway
         :header "authorization"
         :scheme "Bearer"}})

(var settings
  "The [:auth-http] slice, read at :before-start — the middleware runs
  on the hot path and has no business reaching into the boot value
  there."
  defaults)

(defn- slice [cfg]
  (def c (merge defaults (or cfg {})))
  (each key [:session :jwt]
    (put c key (merge (defaults key) (get cfg key {}))))
  c)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :auth-http/capture-config
   :doc "Read the [:auth-http] slice once, before the route table is built"
   :fn (fn capture [boot]
         (set settings (slice (get-in boot [:config :values :auth-http]))))})

# -- the session strategy ------------------------------------------------

(defn session-record
  "What a login stores in the session: the subject and how it was
  established, never the user."
  [id &opt now]
  (default now (os/time))
  {:subject (id :subject)
   :via (id :via)
   :at (get id :at now)
   :seen now})

(defn- session-identity [req]
  (def cfg (settings :session))
  (def key (cfg :key))
  (def sess (get req :session))
  (when-let [record (and (dictionary? sess) (get sess key))]
    (def now (os/time))
    (def idle (get cfg :idle-timeout 0))
    (def absolute (get cfg :absolute-timeout 0))
    (cond
      (and (pos? idle) (> (- now (get record :seen (record :at))) idle))
      (do (put sess key nil)
          (log/debug "session idled out" :ns log-ns :subject (record :subject))
          nil)

      (and (pos? absolute) (> (- now (record :at)) absolute))
      (do (put sess key nil)
          (log/debug "session reached its absolute timeout" :ns log-ns
                     :subject (record :subject))
          nil)

      (do
        # the session is alive: mark it seen, which the session
        # middleware writes back because the session was loaded
        (put sess key (merge record {:seen now}))
        (if (= :session (get cfg :load :store))
          (identity/make (record :subject)
                         {:via (get record :via :session)
                          :cookie true
                          :claims (get record :claims {})
                          :at (record :at)})
          (let [store (state/users)
                user ((store :find) {:by :subject :value (record :subject)})]
            (if user
              (identity/make ((store :subject) user)
                             {:via (get record :via :session)
                              :cookie true
                              :claims ((store :claims) user)
                              :at (record :at)})
              (do
                # the subject is gone from the store — a deleted user
                # holding a valid cookie. The session goes with them.
                (put sess key nil)
                (log/info "session subject no longer exists" :ns log-ns
                          :subject (record :subject))
                nil))))))))

(def session-strategy
  ``Identity from the session a login put it in. `:cookie true` is the
  fact `void/security` needs: this credential rides on a cookie, so
  the request is subject to CSRF.``
  {:name :session
   :doc "The identity a login stored in the session; the subject is re-read from the user store unless [:auth-http :session :load] says otherwise"
   :cookie true
   :priority 10
   :authenticate session-identity})

# -- login and logout ----------------------------------------------------

(defn login!
  ``Sign `id` into this request's session and rotate the session id.
  Binds the identity for the rest of the request as well, so a
  handler that logs somebody in and renders a page sees them.

  The rotation is not optional: keeping the id across a login is
  session fixation.``
  [req id &opt opts]
  (default opts {})
  (unless (identity/identity? id)
    (errorf "auth/login! needs an identity, got %q" id))
  (def sess (get req :session))
  (unless (dictionary? sess)
    (error "auth/login! needs a session — is :void/http's session middleware enabled?"))
  (def record (merge (session-record id)
                     (if (get opts :claims) {:claims (get opts :claims)} {})))
  (put sess (get-in settings [:session :key]) record)
  (http-session/rotate! req)
  (setdyn identity/dyn-key id)
  (log/info "login" :ns log-ns :subject (id :subject) :via (id :via))
  id)

(defn logout!
  ``Sign the current session out: drop the identity, rotate the id
  (the same fixation argument applies in reverse — the next visitor
  on this machine must not inherit the id), and unbind the dyn. The
  rest of the session survives; return `{:session :delete ...}` from
  the handler to destroy it entirely.``
  [req]
  (def sess (get req :session))
  (when (dictionary? sess)
    (def key (get-in settings [:session :key]))
    (when-let [record (get sess key)]
      (log/info "logout" :ns log-ns :subject (record :subject)))
    (put sess key nil))
  (http-session/rotate! req)
  (setdyn identity/dyn-key nil)
  nil)

# -- bearer tokens and JWT -----------------------------------------------

(defn- authorization [req scheme]
  (def header (ring/request-header req (get-in settings [:jwt :header] "authorization")))
  (when (and header (string/has-prefix? (string scheme " ") header))
    (string/trim (string/slice header (inc (length scheme))))))

(defn- bearer-identity [req]
  (when-let [presented (authorization req (get-in settings [:jwt :scheme] "Bearer"))]
    (def opts (get (state/settings) :token {}))
    # not a void token (no prefix) — leave it for the JWT strategy
    (when (token/parse presented opts)
      (token/verify (state/tokens) presented opts))))

(def bearer-strategy
  "API tokens from the Authorization header, checked against the token
  store as digests."
  {:name :bearer
   :doc "Authorization: Bearer vt_<id>.<secret> — an API token, looked up by id and compared as a digest"
   :cookie false
   :priority 20
   :authenticate bearer-identity
   :challenge (fn bearer-challenge [_]
                (ring/header (ring/text 401 "unauthorized")
                             "www-authenticate"
                             (string/format "Bearer realm=%q" (settings :realm))))})

(defn jwt-key
  ``The configured JWT key, with a config secret box unwrapped
  (`{:secret "JWT_SIGNING_KEY"}` is the production spelling). nil when
  no key is configured, which is what turns the strategy off.``
  []
  (when-let [k (get-in settings [:jwt :key])]
    (if (config/secret? k) (config/reveal k) k)))

(defn- jwt-identity [req]
  (def cfg (settings :jwt))
  (when-let [secret (jwt-key)
             presented (authorization req (get cfg :scheme "Bearer"))]
    # a void API token is not a JWT: let the bearer strategy have it
    (when (nil? (token/parse presented (get (state/settings) :token {})))
      (def out (jwt/decode-token presented
                                 {:alg (cfg :alg)
                                  :key secret
                                  :issuer (cfg :issuer)
                                  :audience (cfg :audience)
                                  :leeway (cfg :leeway)}))
      (if (out :ok)
        (let [claims (out :claims)]
          (if-let [sub (get claims :sub)]
            (identity/make sub
                           {:via :jwt
                            :cookie false
                            :claims claims
                            :expires (get claims :exp)})
            (do (log/debug "JWT has no sub claim" :ns log-ns) nil)))
        (do
          # the reason goes to the log and never to the client: which
          # part of a token failed is information an attacker is
          # actively looking for
          (log/debug "JWT rejected" :ns log-ns :reason (out :reason))
          nil)))))

(def jwt-strategy
  "JWS bearer tokens, with the algorithm fixed by [:auth-http :jwt
  :alg] rather than by the token."
  {:name :jwt
   :doc "Authorization: Bearer <JWS> — verified with the configured algorithm and key; the token's own alg header only ever has to match"
   :cookie false
   :priority 30
   :authenticate jwt-identity})

# -- route metadata ------------------------------------------------------

(plugin/contribute! :void.http/route-meta-key
  {:key :void.auth/access
   :schema [:enum :public :required]
   :doc "Whether this route needs an authenticated identity. :restrict — a group that requires authentication cannot be loosened by a route inside it"
   :merge :restrict
   :allow? (fn [outer inner]
             # tightening is public -> required; the other direction is
             # a route quietly opening a hole in its own group
             (or (= outer inner) (and (= outer :public) (= inner :required))))})

(plugin/contribute! :void.http/route-meta-key
  {:key :void.auth/strategies
   :schema [:vector :keyword]
   :doc "Which authentication strategies may answer for this route, in order — a login form that must not accept an API token, an API that must not accept a session cookie"
   :merge :replace})

# -- enforcement ---------------------------------------------------------

(defn- access-of [rmeta]
  (get rmeta :void.auth/access (settings :default)))

(defn local-path?
  ``Is `s` a path on this application — the only kind of value a
  `?next=` redirect may follow? `//evil.example` is a scheme-relative
  URL, and `/\evil.example` is the *same* URL to a browser, which
  normalizes the backslash in a Location header — so any second
  character from the `/ \` set is refused with it.

  This is the validator for both halves of the flow: `unauthorized`
  below mints `?next=` from the request URI, and whoever consumes the
  parameter (a login handler, void/oauth's start route) must pass it
  through here before redirecting — an unvalidated `?next=` is an
  open redirect wearing a convenience feature.``
  [s]
  (and (bytes? s)
       (string/has-prefix? "/" s)
       (or (= 1 (length s))
           (let [second (in s 1)]
             (and (not= second (chr "/"))
                  (not= second (chr "\\")))))))

(defn unauthorized
  ``The response for a request that needed somebody and had nobody:
  a redirect to the login page, or the configured status through the
  error renderers — never a raise, because a stack trace per
  unauthorized request is a bill that comes due exactly when
  somebody is trying passwords.

  The `?next=` it mints is the request's own URI; the login handler
  that honours it must check it with `local-path?` first — the value
  round-trips through the visitor's browser and comes back as input.``
  [req &opt names]
  (if (= :redirect (settings :unauthenticated))
    (let [target (get req :uri (get req :path "/"))]
      (ring/redirect (string (settings :login-path) "?next=" (wire/url-encode target))))
    (let [challenge (strategy/challenge req names)
          resp (http/render-error {:http/status (settings :status)
                                   :message "authentication required"}
                                  req (settings :status))]
      (when challenge
        (when-let [header (get-in challenge [:headers "www-authenticate"])]
          (ring/header resp "www-authenticate" header)))
      resp)))

(plugin/contribute! :void.http/middleware
  {:name :void.auth/identity
   # the reserved phase 4000: after the session (3000), before authz
   # (5000) — void/authz reads the dyn this wrapper binds
   :phase 4000
   :doc "Resolve the identity through the strategy chain, bind it for the request, and enforce :void.auth/access :required (401 or a redirect)"
   :wrap
   (fn [handler]
     (fn auth-identity [req]
       (def rmeta (get-in req [:void/route :meta] {}))
       (def names (get rmeta :void.auth/strategies))
       (def id (strategy/authenticate req names))
       (put req :void.auth/identity id)
       (if (and (nil? id) (= :required (access-of rmeta)))
         (do
           (log/debug "unauthenticated request to a protected route" :ns log-ns
                      :route (get rmeta :name) :path (get req :path))
           (unauthorized req names))
         (with-dyns [identity/dyn-key id]
           (handler req)))))})

# -- public surface ------------------------------------------------------

(def session-key
  "Where the session record lives inside the session table."
  (get-in defaults [:session :key]))

(plugin/defplugin void/auth-http
  :doc "Authentication for void/http: the session, bearer-token and JWT strategies, login!/logout! with session-id rotation, and :void.auth/access enforcement in phase 4000 — answered through the error renderers as a 401 or a redirect."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/auth ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :auth-http
  :config-schema Config
  :config-defaults defaults
  :contributes {:void.auth/strategy [session-strategy bearer-strategy jwt-strategy]})
