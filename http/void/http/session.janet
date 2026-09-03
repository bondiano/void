### void/http/session — cookie sessions over a pluggable store.
###
### The store contract behind the :void.http/session-store extension
### point: {:load (fn [sid] data|nil) :save (fn [sid data ttl]) :delete
### (fn [sid]) :sweep (fn [])}. The memory store lives here; redis/db
### stores come from their plugins. The contribution also says whether the
### store is `:shared?`, and that is the honest form of what used to be a
### `:workers > 1` check: an in-memory store is one process's heap, so a
### prefork family *and* a second machine both lose sessions on it.
### `[:deploy :shape] :fleet` refuses it at start, with prefork as one of
### the ways to be a fleet.
###
### The middleware (phase 3000) puts a mutable table at (req :session);
### a handler mutates it, or replaces it via (resp :session), or
### destroys it with {:session :delete}, or asks for a new id under the
### same data with (session/rotate! req) — equivalently {:session
### :rotate}. Session ids are 128-bit random values from the OS; an id
### presented by the client but unknown to the store is never adopted —
### a fresh one is issued on first save.
###
### **Why rotation is part of the contract.** A session id that survives
### a change of privilege is session fixation: an attacker who can set the
### cookie before a login (a subdomain, a shared machine, a link with a
### session in it) holds a valid id afterwards. The only fix is a new id
### at that moment, so `void/auth` rotates on every login, and it needs
### the session layer to be able to do it. `rotate!` marks the *request*,
### because whoever logs a user in is usually deep inside a handler and
### does not build the response.

(import ./ring :as ring)

(defn sid
  "A fresh session id: 32 hex chars of OS randomness."
  []
  (def bytes (os/cryptorand 16))
  (def out (buffer/new 32))
  (each b bytes (buffer/format out "%02x" b))
  (string out))

# -- memory store --------------------------------------------------------

(defn memory-store
  ``An in-process session store: sid -> {:data :expires}. Expired
  entries die lazily on load and in bulk on :sweep, which also runs
  every :sweep-every saves (default 256).``
  [&opt opts]
  (default opts {})
  (def entries @{})
  (var saves 0)
  (defn now [] (os/clock :monotonic))
  (defn sweep []
    (def t (now))
    (each k (seq [[k v] :pairs entries :when (< (v :expires) t)] k)
      (put entries k nil))
    nil)
  {:name :memory
   :entries entries
   :load (fn load [id]
           (when-let [e (get entries id)]
             (if (< (e :expires) (now))
               (do (put entries id nil) nil)
               (e :data))))
   :save (fn save [id data ttl]
           (++ saves)
           (when (zero? (% saves (get opts :sweep-every 256)))
             (sweep))
           (put entries id @{:data data :expires (+ (now) ttl)})
           id)
   :delete (fn delete [id] (put entries id nil))
   :sweep sweep})

# -- rotation ------------------------------------------------------------

(def rotate-key
  "Request key `rotate!` sets and the middleware reads."
  :void.http/session-rotate)

(defn rotate!
  ``Ask for a fresh session id on this request, keeping the data. Call
  it whenever the identity behind a session changes — a login, a
  privilege escalation, a password change — because an id that
  survives that change is session fixation. Safe to call several
  times, and safe on a request that has no session yet (one is issued
  anyway).``
  [req]
  (put req rotate-key true)
  nil)

# -- middleware ----------------------------------------------------------

(defn wrap-session
  ``Session middleware over a store. Options:
    :store        the store table (required)
    :cookie       cookie name (default "void-session")
    :ttl          seconds a session lives after its last save
                  (default 86400)
    :cookie-opts  extra cookie attributes (merged over {:path "/"
                  :http-only true :same-site :lax})

  Contract with handlers: (req :session) is always a table — mutate it
  in place or return a replacement under (resp :session); return
  {:session :delete ...} to destroy the session. The session is saved
  after the handler when it exists or is non-empty; the cookie is set
  only when the id is new.``
  [handler opts]
  (def store (or (opts :store) (error "wrap-session requires :store")))
  (def cookie-name (get opts :cookie "void-session"))
  (def ttl (get opts :ttl 86400))
  (def cookie-opts
    (merge {:path "/" :http-only true :same-site :lax}
           (get opts :cookie-opts {})))
  (fn session-handler [req]
    (def client-id (get (ring/cookies req) cookie-name))
    (def loaded (when client-id ((store :load) client-id)))
    (def session (or loaded @{}))
    (put req :session session)
    (def resp (handler req))
    (when (dictionary? resp)
      (def marker (resp :session))
      (if (= :delete marker)
        (do
          (when loaded ((store :delete) client-id))
          (ring/delete-cookie resp cookie-name cookie-opts))
        (do
          # a marker keyword is an instruction, not data: only a
          # dictionary replaces the session
          (def out (if (dictionary? marker) marker session))
          (def rotate?
            (or (= :rotate marker) (truthy? (get req rotate-key))))
          (when (or loaded rotate? (not (empty? out)))
            # a rotated session gets a new id even though the old one
            # was valid — that is the whole point — and the old entry
            # goes, or the fixated id stays usable
            (def fresh? (or rotate? (not loaded)))
            (def id (if fresh? (sid) client-id))
            (when (and rotate? loaded) ((store :delete) client-id))
            ((store :save) id out ttl)
            (when fresh?
              (ring/set-cookie resp cookie-name id cookie-opts))))))
    resp))
