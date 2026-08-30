### void/auth — authentication: identity as data, strategies as an
### extension point (SPEC.md §5.14, ADR-0023).
###
### void does not know what a user is, and this plugin is the shape of
### that ignorance: an **identity** is `{:subject "user:42" :via
### :password :claims {...}}` and nothing more, the **user store** is a
### contract an application implements (or takes from `void/auth-db`),
### and a **strategy** is a contribution that turns either a request or
### a set of credentials into an identity.
###
### Two plugins, and the split is the one `void/cache` already makes:
###
###   void/auth       identity, hashing, stores, strategies, tokens,
###                   JWT, one-time codes — core + void/crypto
###   void/auth-http  the middleware, `:void.auth/access`, login and
###                   logout, and the strategies that read a request
###                   (./http)
###
### so a jobs worker that needs to know whose job it is runs the first
### without dragging in the HTTP kernel.
###
### What an application composes:
###
###     (void/run! {:plugins [:void/crypto :void/auth :void/auth-http ...]})
###     # config/prod.janet
###     {:auth {:hasher :argon2id
###             :strategies [:session :bearer]}
###      :crypto {:require [:argon2id]}}
###
### and marks the routes that need somebody:
###
###     (defroutes app {:void.auth/access :required}
###       [:get "/dashboard" dashboard]
###       [:get "/login" login-form {:void.auth/access :public}])
###
### Every primitive comes from `void/crypto` (ADR-0022): this package
### hashes nothing itself, and a composition without `:void/crypto` is
### a boot error rather than a surprise at the first login.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./identity :as identity-mod)
(import ./hash :as hash-mod)
(import ./store :as store)
(import ./strategy :as strategy)
(import ./token :as token-mod)
(import ./challenge :as challenge-mod)
(import ./jwt :as jwt-mod)
(import ./password :as password)
(import ./state :as state)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.auth")

# -- extension points ----------------------------------------------------

(plugin/defextension-point :void.auth/strategy
  :doc "Authentication strategies (ADR-0023): {:name :session :authenticate (fn [req] identity|nil)? :verify (fn [creds] identity|nil)? :challenge (fn [req] response)? :cookie bool? :priority int?}; a strategy needs at least one of :authenticate and :verify"
  :schema {:name :keyword
           :doc [:optional :string]
           :authenticate [:optional :function]
           :verify [:optional :function]
           :challenge [:optional :function]
           :cookie [:optional :boolean]
           :priority [:optional :int]}
  :validate (fn [contribs]
              (def seen @{})
              (each c contribs
                (when (in seen (c :name))
                  (errorf "duplicate authentication strategy %q" (c :name)))
                (put seen (c :name) true)
                # the same check normalize makes, run at resolution so
                # that a strategy which can never authenticate anybody
                # fails the boot rather than the login
                (unless (or (c :authenticate) (c :verify))
                  (errorf "strategy %q has neither :authenticate nor :verify" (c :name)))))
  :reduce |(sorted-by |($ :name) $))

(plugin/defextension-point :void.auth/hasher
  :doc "Password hashers behind PHC identifiers (ADR-0023): {:name :argon2id :derive (fn [password salt params] bytes) :encode-params (fn [params] \"m=..,t=..\") :cost-keys [:m :t]? :version int?}; [:auth :hasher] selects which one writes new hashes"
  :schema {:name :keyword
           :derive :function
           :encode-params :function
           :cost-keys [:optional [:vector :keyword]]
           :version [:optional :int]}
  :reduce |(sorted-by |($ :name) $))

(plugin/defextension-point :void.auth/deliver
  :doc "Delivery of magic links and one-time codes (ADR-0023): {:name :mail/magic-link :fn (fn [challenge] ...)}; called with {:kind :subject :handle :code :expires :to :claims :channel}. void/mail-auth is one of these, and an application that texts its codes contributes its own. Called by auth/challenge!, which refuses a challenge nobody delivered"
  :schema {:name :keyword
           :doc [:optional :string]
           :fn :function}
  :reduce |(sorted-by |($ :name) $))

(plugin/contribute! :void.core/interface
  {:name :void/auth
   :doc "The resolved authentication: the stores this composition has, the strategies it registered and the hashing settings behind them."
   :methods {:users "the active user store"
             :tokens "the active API-token store"
             :challenges "the active store for magic links and one-time codes"
             :settings "the [:auth] slice as it was resolved"}})

(each [name doc methods]
  [[:void/auth-user-store
    "Who exists and what their password hash is — implemented by an application, or by void/auth-db over a void/db entity."
    {:find "(fn [{:by :email :value \"a@b.c\"}] record|nil)"
     :secret "(fn [record] phc|nil)"
     :subject "(fn [record] \"user:42\")"
     :claims "(fn [record] {...})"}]
   [:void/auth-token-store
    "API tokens, stored as digests — never as tokens."
    {:find "(fn [id] record|nil)" :put "(fn [record])" :delete "(fn [id] deleted?)"}]
   [:void/auth-challenge-store
    "Magic links and one-time codes; :take must remove what it returns, or the code is not single-use."
    {:put "(fn [handle record ttl])" :take "(fn [handle] record|nil)"}]]
  (plugin/contribute! :void.core/interface {:name name :doc doc :methods methods}))

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:auth] config slice."
  {:hasher [:optional :keyword]
   :scrypt [:optional :dictionary]
   :argon2id [:optional :dictionary]
   :strategies [:optional [:vector :keyword]]
   :users [:optional :dictionary]
   :token [:optional :dictionary]
   :challenge [:optional :dictionary]})

(def defaults
  ``Defaults of the [:auth] slice.

  `:strategies` unset means "every registered strategy that reads
  requests, by priority" — an application that wants a shorter list,
  or a different order, says so.

  `:users` is the in-process user store's contents: subject ->
  `{:email :password-hash :claims}`. It is meant for a handful of
  operators and for tests (`void auth hash` prints what goes in
  `:password-hash` — the key is spelled that way because
  `{:secret "NAME"}` is an env-var reference to the config layer,
  ADR-0007). Anything with a registration form wants void/auth-db.``
  {:hasher :scrypt
   :scrypt (get hash-mod/defaults :scrypt)
   :argon2id (get hash-mod/defaults :argon2id)
   :strategies nil
   :users {}
   :token token-mod/defaults
   :challenge challenge-mod/defaults})

(defn- slice [cfg]
  (def c (merge defaults (or cfg {})))
  (each key [:scrypt :argon2id :token :challenge]
    (put c key (merge (defaults key) (get cfg key {}))))
  c)

# -- public surface (re-exports) -----------------------------------------

(def identity "See identity/make — build an identity value." identity-mod/make)
(def identity? "See identity/identity?." identity-mod/identity?)
(def current-user "See identity/current — the identity on this fiber, or nil." identity-mod/current)
(def authenticated? "See identity/authenticated?." identity-mod/authenticated?)
(def subject "See identity/subject — the current subject string." identity-mod/subject)
(def subject-of "See identity/subject-of — \"user:42\" -> [:user \"42\"]." identity-mod/subject-of)
(def claim "See identity/claim." identity-mod/claim)
(def with-identity* "See identity/with-identity*." identity-mod/with-identity*)
(defmacro with-identity
  "See identity/with-identity — run the body as somebody."
  [id & body]
  ~(,identity-mod/with-identity* ,id (fn [] ,;body)))
(def identity-dyn "See identity/dyn-key — the dyn void/authz reads without importing this package." identity-mod/dyn-key)

(def hash-password "See hash/hash — a password as a PHC string." hash-mod/hash)
(def verify-password "See hash/verify — [ok? needs-rehash?]." hash-mod/verify)
(def needs-rehash? "See hash/needs-rehash?." hash-mod/needs-rehash?)
(def parse-hash "See hash/parse — a PHC string as data." hash-mod/parse)
(def dummy-verify "See hash/dummy-verify — spend the time, answer false." hash-mod/dummy-verify)

(def check-password "See password/check — the full result of a login attempt." password/check)
(def register-strategy! "See strategy/register!." strategy/register!)
(def strategies "See strategy/known — every registered strategy." strategy/known)
(def strategy-of "See strategy/lookup." strategy/lookup)
(def authenticate "See strategy/authenticate — the request chain." strategy/authenticate)
(def attempt "See strategy/attempt — verify credentials with one strategy." strategy/attempt)

(def issue-token "See token/issue — mint an API token." token-mod/issue)
(def verify-token "See token/verify." token-mod/verify)
(def revoke-token "See token/revoke." token-mod/revoke)
(def tokens-of "See token/list-for." token-mod/list-for)

(def issue-challenge "See challenge/issue — a magic link or a one-time code." challenge-mod/issue)
(def redeem-challenge "See challenge/redeem." challenge-mod/redeem)

(defn deliverers
  "The :void.auth/deliver contributions this composition resolved, or
  an empty list before it started."
  []
  (get (or (state/active) {}) :deliver []))

(defn challenge!
  ``Issue a magic link (or a one-time code) for `subject` **and get it
  to the person** — the half of ADR-0023 §7 that waited for a delivery
  to exist (`void/mail-auth` is one, 3.5):

      (auth/challenge! (string "user:" (user :id)) {:to (user :email)})

  `opts` is `challenge/issue`'s (`:kind` :link or :otp, `:ttl`,
  `:claims`, `:handle`) plus what the delivery needs: `:to` (an
  address, however the deliverer reads one) and `:channel` (which
  deliverer this is for, when a composition has several).

  Every deliverer is called and each decides whether the payload is
  its business — one that did nothing returns nil. **A challenge
  nobody delivered is an error**: the code exists, the visitor is
  waiting for it, and the alternative is a login page that spins
  forever with nothing in any log.

  Returns `{:handle :kind :expires :delivered}` — deliberately
  *without* the code, which exists only inside this call and inside
  whatever carried it away.``
  [subject &opt opts]
  (default opts {})
  (def issued (challenge-mod/issue (state/challenges) subject opts))
  (def payload
    (merge issued {:subject subject
                   :claims (get opts :claims {})
                   :to (get opts :to)
                   :channel (get opts :channel)}))
  (def delivered
    (seq [d :in (deliverers)
          :let [[ok result] (protect ((d :fn) payload))]]
      (unless ok
        (log/error "a challenge delivery failed" :ns log-ns
                   :deliverer (d :name) :kind (issued :kind) :err (string result))
        (error result))
      (when result (d :name))))
  (def names (filter |(not (nil? $)) delivered))
  (when (empty? names)
    (errorf (string "a %s challenge for %s was issued and nobody delivered it. "
                    "Registered deliverers: %s — add :void/mail-auth (with "
                    ":void/mail under it), or contribute your own "
                    ":void.auth/deliver")
            (issued :kind) subject
            (if (empty? (deliverers))
              "none"
              (string/join (map |(string/format "%q" ($ :name)) (deliverers)) " "))))
  (log/info "challenge delivered" :ns log-ns
            :kind (issued :kind) :subject subject :via names)
  {:handle (issued :handle)
   :kind (issued :kind)
   :expires (issued :expires)
   :delivered names})

(defn redeem!
  ``Redeem a challenge against the active store — `redeem-challenge`
  without having to name the store. Returns an identity or nil.``
  [handle code &opt opts]
  (challenge-mod/redeem (state/challenges) handle code opts))

(def encode-jwt "See jwt/encode-token." jwt-mod/encode-token)
(def decode-jwt "See jwt/decode-token — {:ok true :claims} or {:ok false :reason}." jwt-mod/decode-token)
(def peek-jwt "See jwt/peek — unverified, for choosing a key by kid." jwt-mod/peek)

(def user-store "See state/users — the active user store." state/users)
(def token-store "See state/tokens." state/tokens)
(def challenge-store "See state/challenges." state/challenges)
(def auth-dyn "See state/auth-dyn — the test override." state/auth-dyn)
(def make-state "See state/make." state/make)

(def memory-user-store "See store/memory-user-store." store/memory-user-store)
(def memory-token-store "See store/memory-token-store." store/memory-token-store)
(def memory-challenge-store "See store/memory-challenge-store." store/memory-challenge-store)

# -- the memory stores, as components ------------------------------------

(def memory-users-component
  (system/component :auth/memory-users
    :doc "The in-process user store, seeded from [:auth :users]: a
    handful of operators kept in configuration, and what a test uses.
    An application with a registration form provides
    :void/auth-user-store itself, or composes void/auth-db."
    :provides [:void/auth-user-store]
    :config {:key :auth :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (def users
        (tabseq [[subject rec] :pairs (get cfg :users {})]
          (string subject) (merge {:subject (string subject)} rec)))
      (log/info "auth memory user store ready" :ns log-ns :users (length users))
      (store/normalize-user-store (store/memory-user-store users)))))

(def memory-tokens-component
  (system/component :auth/memory-tokens
    :doc "The in-process API-token store. Tokens die with the process,
    which is right for a single-process deployment and wrong for
    everything else — void/auth-db keeps them in the database."
    :provides [:void/auth-token-store]
    :start
    (fn start [_ _]
      (store/normalize-token-store (store/memory-token-store)))))

(def memory-challenges-component
  (system/component :auth/memory-challenges
    :doc "The in-process store for magic links and one-time codes.
    Per-process: with prefork workers (ADR-0010) or a second replica a
    code issued by one process cannot be redeemed at another, so
    anything past one process wants void/auth-db — and under
    [:deploy :shape] :fleet this store stops the boot (ADR-0030)."
    :provides [:void/auth-challenge-store]
    :start
    (fn start [_ _]
      (store/normalize-challenge-store (store/memory-challenge-store)))))

(plugin/contribute! :void.core/store
  {:name :void.auth/tokens
   :what "API tokens"
   :needs [:auth/registry]
   :doc "Where this composition keeps API-token digests"
   :ask (fn ask-tokens [boot]
          (when-let [a (get-in boot [:system :instances :auth/registry])]
            (def st (a :tokens))
            {:store (get st :name :anonymous)
             :shared? (store/shared? st)
             :replacement "compose void/auth-db and set {:void/auth-token-store {:impl :auth.db/tokens}} — a token minted on one replica authenticates on that replica only"}))})

(plugin/contribute! :void.core/store
  {:name :void.auth/challenges
   :what "magic links and one-time codes"
   :needs [:auth/registry]
   :doc "Where this composition keeps single-use challenges"
   :ask (fn ask-challenges [boot]
          (when-let [a (get-in boot [:system :instances :auth/registry])]
            (def st (a :challenges))
            {:store (get st :name :anonymous)
             :shared? (store/shared? st)
             :replacement "compose void/auth-db and set {:void/auth-challenge-store {:impl :auth.db/challenges}} — a magic link issued by one replica and clicked on another is a login that fails for no visible reason"}))})

# -- the registry component ----------------------------------------------

(var contributions
  ``What the extension points resolved to, captured at :before-start.

  Read from a hook rather than from `plugin/current-boot` on purpose:
  that var is only set by the tracking start path, and `test/start!`
  (ADR-0017) does not use it — a component that reached for it would
  work under `plugin/start!` and silently register no strategies under
  the inject client, which is precisely the arrangement every test in
  this package uses.``
  @{})

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 400
   :name :auth/collect-extensions
   :doc "Capture the resolved :void.auth/* contributions before components start"
   :fn (fn collect [boot]
         (each point [:void.auth/strategy :void.auth/hasher :void.auth/deliver]
           (put contributions point
                (or (get-in boot [:extensions point :resolved]) []))))})

(defn- resolved [name]
  (get contributions name []))

(def registry-component
  (system/component :auth/registry
    :doc "What this composition authenticates with: the three stores,
    every :void.auth/strategy contribution plus the built-in password
    strategy, and the hashing settings. Registering happens here, at
    :start, so that a strategy contributed by a plugin and one
    registered from a REPL are the same thing."
    :deps [:void/auth-user-store :void/auth-token-store :void/auth-challenge-store]
    :provides [:void/auth]
    :config {:key :auth :schema Config}
    :start
    (fn start [deps cfg0]
      (def cfg (slice cfg0))
      (set hash-mod/settings cfg)
      (set strategy/order (get cfg :strategies))
      (each h (resolved :void.auth/hasher)
        (put hash-mod/hashers (h :name)
             (merge {:version nil :cost-keys []} h)))
      (def users (deps :void/auth-user-store))
      (def value
        (state/make {:users users
                     :tokens (deps :void/auth-token-store)
                     :challenges (deps :void/auth-challenge-store)
                     :settings cfg
                     :deliver (resolved :void.auth/deliver)}))
      # the built-in first, so a contribution named :password replaces
      # it rather than colliding with it
      (strategy/register! (password/strategy users))
      (each s (resolved :void.auth/strategy) (strategy/register! s))
      (set state/current value)
      (log/info "auth ready" :ns log-ns
                :hasher (hash-mod/active-hasher)
                :user-store (get users :name)
                :strategies (strategy/known)
                :order (get cfg :strategies)
                :deliver (map |($ :name) (resolved :void.auth/deliver)))
      (unless (get (hash-mod/hashers (hash-mod/active-hasher)) :derive)
        (errorf "[:auth :hasher] names %q, which is not a registered hasher (have %s)"
                (hash-mod/active-hasher)
                (string/join (map string (sorted (keys hash-mod/hashers))) " ")))
      value)
    :stop
    (fn stop [_]
      (set state/current nil)
      nil)
    :health
    (fn health [value]
      {:status :up
       :user-store (get-in value [:users :name])
       :token-store (get-in value [:tokens :name])
       :challenge-store (get-in value [:challenges :name])
       :hasher (hash-mod/active-hasher)
       :strategies (strategy/known)})))

# -- CLI -----------------------------------------------------------------

(plugin/contribute! :void.core/cli
  {:name :auth/hash
   :read-only? true
   :doc "Hash a password with the configured hasher: void auth hash <password>"
   :needs [:auth/registry]
   :fn (fn cli-hash [_ & args]
         (unless (= 1 (length args))
           (error "usage: void auth hash <password>"))
         (print (hash-mod/hash (first args))))})

(plugin/contribute! :void.core/cli
  {:name :auth/strategies
   :read-only? true
   :doc "List the authentication strategies in this composition: void auth strategies"
   :needs [:auth/registry]
   :fn (fn cli-strategies [_ & args]
         (unless (empty? args)
           (errorf "void auth strategies takes no arguments (got %q)"
                   (string/join args " ")))
         (printf "%-14s %-8s %-8s %-10s %s" "strategy" "request" "login" "cookie" "order")
         (def order (or strategy/order (map |($ :name) (strategy/request-strategies))))
         (each name (strategy/known)
           (def s (strategy/lookup name))
           (printf "%-14s %-8s %-8s %-10s %s"
                   (string name)
                   (if (s :authenticate) "yes" "—")
                   (if (s :verify) "yes" "—")
                   (if (s :cookie) "yes" "—")
                   (if-let [i (index-of name order)] (string (inc i)) "—"))))})

(plugin/contribute! :void.core/cli
  {:name :auth/token
   :read-only? false
   :doc "Mint an API token: void auth token <subject> [name]"
   :needs [:auth/registry]
   :fn (fn cli-token [value & args]
         (unless (or (= 1 (length args)) (= 2 (length args)))
           (error "usage: void auth token <subject> [name]"))
         (def out (token-mod/issue (value :tokens) (first args)
                                   {:name (get args 1 "api token")}))
         (print (out :token))
         (eprint "the secret is shown once — it is not recoverable from the store"))})

# -- health --------------------------------------------------------------

(plugin/contribute! :void.core/health
  {:name :auth/registry
   :fn (fn auth-health []
         (if-let [value (state/active)]
           {:status :up
            :user-store (get-in value [:users :name])
            :hasher (hash-mod/active-hasher)
            :strategies (strategy/known)}
           {:status :down :reason "void/auth is not started"}))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/auth
  :doc "Authentication: identity as data in a dyn, strategies as an extension point, password hashes as PHC strings over void/crypto, API tokens stored as digests, JWT with the algorithm fixed by configuration, and single-use magic links and one-time codes."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/crypto ">=0.0.1"}
  :config-key :auth
  :config-schema Config
  :config-defaults defaults
  :components [memory-users-component
               memory-tokens-component
               memory-challenges-component
               registry-component])
