### void/auth/identity — who the request is, as data (ADR-0023 §1).
###
### An identity is a plain struct, not a user object:
###
###     {:subject "user:42"     required, "<kind>:<id>"
###      :via     :password     the strategy that established it
###      :cookie  true          was it carried by a cookie?
###      :claims  {...}         open, the application's business
###      :at      1767225600    when it was established
###      :expires 1767229200}   or nil — forever, until the session goes
###
### void does not know what a user is. It cannot: the subject may be a
### person, a service token, a background job or an RPC call from the
### service next door, and the only thing the framework is entitled to
### say is that the request carried a verifiable claim to be somebody.
### Everything an application knows about that somebody reaches
### authorization as *attributes* (ADR-0024 §2), pulled when a policy
### asks for them, rather than as fields nailed onto this struct.
###
### `:cookie` is the one field that exists for another package.
### `void/security` decides whether to demand a CSRF token by asking
### whether the credential was carried by a cookie (ADR-0025 §1) — a
### `Authorization: Bearer` request is not subject to CSRF, and only
### the strategy that read the credential knows which it was.
###
### The current identity lives in a dyn, per fiber, so it is inherited
### by whatever the handler spawns and isolated between concurrent
### requests without anybody passing it down. `void/authz` reads
### **this dyn key** rather than importing this package, which is what
### lets an application keep its own authentication and still use
### void's authorization.

(def dyn-key
  ``The dyn the current identity lives in. Named rather than passed:
  `void/authz` reads this key without importing void/auth (ADR-0024),
  and so may anything else.``
  :void.auth/identity)

(defn make
  ``Build an identity. `subject` is required and is a string —
  "user:42", "service:billing", "token:9f3c". Options: :via :cookie
  :claims :at :expires.``
  [subject &opt opts]
  (default opts {})
  (unless (and (bytes? subject) (not (empty? subject)))
    (errorf "an identity needs a non-empty subject string, got %q" subject))
  (freeze
    {:subject (string subject)
     :via (get opts :via :unknown)
     :cookie (truthy? (get opts :cookie))
     :claims (get opts :claims {})
     :at (get opts :at (os/time))
     :expires (get opts :expires)}))

(defn identity?
  "Is this an identity value?"
  [x]
  (and (dictionary? x) (string? (get x :subject))))

(defn expired?
  "Has this identity's :expires passed? An identity without one never
  expires on its own — the session or the token behind it does."
  [id &opt now]
  (default now (os/time))
  (and (identity? id)
       (truthy? (id :expires))
       (<= (id :expires) now)))

(defn current
  "The identity bound to this fiber, or nil when the request is
  anonymous. Anonymous is nil, never an empty identity: `(if
  (auth/current-user) ...)` is the question every caller asks."
  []
  (dyn dyn-key))

(defn authenticated?
  "Is there an identity on this fiber?"
  []
  (not (nil? (current))))

(defn subject
  "The current subject string, or nil."
  []
  (when-let [id (current)] (id :subject)))

(defn claim
  ``One claim of the current identity (or of a given one), with a
  default. Claims are what the strategy could prove — a session's
  stored roles, a JWT's payload — and nothing else: an attribute that
  has to be looked up belongs to void/authz's providers.``
  [key &opt default id]
  (def i (or id (current)))
  (if i (get-in i [:claims key] default) default))

(defn subject-of
  ``Split a subject into [kind id]: "user:42" -> [:user "42"]. A
  subject without a colon is [:unknown subject], because a convention
  is not a schema and void does not get to reject somebody else's
  spelling.``
  [subject]
  (def s (string subject))
  (if-let [i (first (string/find-all ":" s))]
    [(keyword (string/slice s 0 i)) (string/slice s (inc i))]
    [:unknown s]))

(defn with-identity*
  "Run `thunk` with `id` as the current identity."
  [id thunk]
  (with-dyns [dyn-key id] (thunk)))

(defmacro with-identity
  ``Run the body as `id` — what the middleware does around a handler,
  and what a job or a test does to answer "and what would this user
  see?".``
  [id & body]
  ~(,with-identity* ,id (fn [] ,;body)))
