### void/auth/strategy — the :void.auth/strategy extension point.
###
### A strategy is a dictionary with up to three halves, and a strategy
### that has only one is normal:
###
###   :authenticate (fn [req] identity|nil)   read a credential the
###                                           request carried
###   :verify       (fn [creds] identity|nil) check credentials handed
###                                           over deliberately (a
###                                           login form, a code)
###   :challenge    (fn [req] response|nil)   what a refusal looks like
###
### `:session`, `:bearer` and `:jwt` have the first; `:password`, and
### `:otp` have the second. That split is not tidiness: the first half
### runs on **every** request and must be cheap, and the second is allowed
### to spend 25 ms on a KDF because it happens once per login. A strategy
### with no `:authenticate` is never in the per-request chain at all.
###
### `:cookie` says whether `:authenticate` reads a cookie. It exists for
### `void/security`, which demands a CSRF token exactly when the
### credential was cookie-borne — the strategy is the only thing that
### knows.
###
### **Errors are not "no identity".** A strategy turns a malformed
### token, a wrong password or an unknown session into nil; if it
### *throws*, the request fails as a 500 rather than a 401. That is
### deliberate: a store that is down must not read as "this user does
### not exist", because the answer to the latter is to send the
### visitor to a login form and the answer to the former is to page
### somebody.

(import void/core/log :as log)
(import ./identity :as identity)

(def log-ns "void.auth.strategy")

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(def default-priority
  "Where a strategy sits in the chain when it does not say. Lower runs
  first."
  100)

(defn normalize
  "Validate a strategy and fill in its defaults."
  [s]
  (unless (dictionary? s)
    (errorf "a strategy must be a dictionary, got %q" s))
  (def name (get s :name))
  (unless (keyword? name)
    (errorf "a strategy needs a keyword :name, got %q" name))
  (each k [:authenticate :verify :challenge]
    (when-let [f (get s k)]
      (unless (callable? f)
        (errorf "strategy %q: %q must be a function, got %q" name k f))))
  (unless (or (s :authenticate) (s :verify))
    (errorf "strategy %q has neither :authenticate nor :verify — it can never establish an identity" name))
  (freeze (merge @{:cookie false :priority default-priority} s)))

(def registry
  "Registered strategies, by name. The plugin fills it from
  :void.auth/strategy contributions at start; tests and scripts
  register into it directly."
  @{})

(defn register!
  "Add (or replace) a strategy. Returns its name."
  [s]
  (def n (normalize s))
  (put registry (n :name) n)
  (n :name))

(defn deregister!
  "Remove a strategy — the REPL's undo, and how a test cleans up."
  [name]
  (put registry name nil)
  nil)

(defn lookup
  "One strategy by name, or nil."
  [name]
  (get registry name))

(defn known
  "Every registered strategy name, sorted."
  []
  (sorted (keys registry)))

(var order
  ``The configured [:auth :strategies] order, or nil for "every
  registered request strategy, by priority then name". Set by the
  plugin at :before-start.``
  nil)

(defn request-strategies
  ``The strategies that read a request, in the order they are tried.
  `names` (a route's :void.auth/strategies) narrows the list;
  `order` decides it otherwise. A name that is not registered is an
  error — a typo in a route's metadata must not silently disable
  authentication.``
  [&opt names]
  (def wanted (or names order))
  (if wanted
    (seq [n :in wanted
          :let [s (or (lookup n)
                      (errorf "unknown authentication strategy %q (registered: %s)"
                              n (string/join (map string (known)) " ")))]
          :when (s :authenticate)]
      s)
    (sorted-by |[($ :priority) (string ($ :name))]
               (filter |($ :authenticate) (values registry)))))

(defn authenticate
  ``Run the request strategies until one produces an identity. Returns
  it, or nil when the request is anonymous. An identity that has
  already expired is not an identity.``
  [req &opt names]
  (var found nil)
  (each s (request-strategies names)
    (when (nil? found)
      (def id ((s :authenticate) req))
      (when id
        (unless (identity/identity? id)
          (errorf "strategy %q returned %q, which is not an identity" (s :name) id))
        (if (identity/expired? id)
          (log/debug "expired identity ignored" :ns log-ns
                     :strategy (s :name) :subject (id :subject))
          (set found id)))))
  found)

(defn attempt
  ``Verify credentials with one named strategy — the login half.
  Returns an identity or nil; an unknown strategy, or one that cannot
  verify, is an error rather than a failed login, because that is a
  programming mistake and not a wrong password.``
  [name credentials]
  (def s (or (lookup name)
             (errorf "unknown authentication strategy %q (registered: %s)"
                     name (string/join (map string (known)) " "))))
  (def verify (or (s :verify)
                  (errorf "strategy %q cannot verify credentials — it only reads requests" name)))
  (def id (verify credentials))
  (when id
    (unless (identity/identity? id)
      (errorf "strategy %q returned %q, which is not an identity" name id)))
  id)

(defn challenge
  ``The response a refusal should carry, from the first strategy that
  offers one (`WWW-Authenticate` for bearer, a redirect for a form).
  nil when no strategy has an opinion — the caller then renders its
  own 401.``
  [req &opt names]
  (var out nil)
  (each s (request-strategies names)
    (when (and (nil? out) (s :challenge))
      (set out ((s :challenge) req))))
  out)
