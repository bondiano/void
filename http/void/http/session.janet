### void/http/session — cookie sessions over a pluggable store
### (SPEC.md §5.1, ROADMAP 1.1).
###
### The store contract behind the :void.http/session-store extension
### point: {:load (fn [sid] data|nil) :save (fn [sid data ttl])
### :delete (fn [sid]) :sweep (fn [])}. The memory store lives here;
### redis/db stores come from their plugins. ADR-0010 honesty: with
### :workers > 1 an in-memory store is per-process — sessions demand an
### external store in prefork setups, and the http plugin refuses the
### combination at start.
###
### The middleware (phase 3000) puts a mutable table at (req :session);
### a handler mutates it, or replaces it via (resp :session), or
### destroys it with {:session :delete}. Session ids are 128-bit random
### values from the OS; an id presented by the client but unknown to
### the store is never adopted — a fresh one is issued on first save.

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
      (if (= :delete (resp :session))
        (do
          (when loaded ((store :delete) client-id))
          (ring/delete-cookie resp cookie-name cookie-opts))
        (do
          (def out (or (resp :session) session))
          (when (or loaded (not (empty? out)))
            (def id (if loaded client-id (sid)))
            ((store :save) id out ttl)
            (unless loaded
              (ring/set-cookie resp cookie-name id cookie-opts))))))
    resp))
