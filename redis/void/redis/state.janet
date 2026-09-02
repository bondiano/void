### void/redis/state — the runtime: current client, dyn-scoped
### connections, and the funnel every command passes through (SPEC.md
### §5.10).
###
### The shape is void/db's, because the problem is: a checked-out
### connection lives in a dyn (:void.redis/conn), so everything inside
### `with-conn` shares it and the checkout comes back when the scope
### exits, on the error path too. What needs a scope here is narrower
### than a transaction but just as real — MULTI/EXEC, WATCH, a
### SUBSCRIBE, a Lua script that must see its own writes — and all of
### them mean "the same connection", which is the only thing a redis
### session is.
###
### One funnel, `call`, is where timing, the pool metrics, the :debug
### line and the one retry live. void/obs (wave 3) hangs its
### instrumentation on the same funnel, the way it will on void/db's.
###
### The retry deserves its own paragraph, because it is a trade rather
### than a free win. The overwhelmingly common connection failure is
### not "redis is down" but "the socket we kept had been closed while
### it sat idle" — a server-side `timeout`, a restart, a proxy tidying
### up — and a client that did not handle it would fail one command per
### pooled connection after every such event. A socket in that state is
### indistinguishable from a healthy one until something is written to
### it, so the fix has to be a retry rather than a check. It is bounded
### as tightly as it can be: only a *connection* failure (never an
### error reply), only on a connection that had been idle rather than
### one just opened (a fresh connection failing means the server is
### unreachable, and retrying that just doubles the wait), only once,
### and never inside `with-conn` — a scope means a session, and a
### session cannot be silently replaced under a MULTI. What remains is
### the honest caveat: a command whose reply was lost may have been
### applied, so a retried INCR could count twice. Set
### `[:redis :retry] false` where that matters more than the stale
### socket does. A *blocking* command (BLPOP and its family) is never
### retried at all: its lost reply may have carried an element the
### server already removed, and a replay would quietly take a second
### one — that error goes to the caller.

(import void/core/log :as log)
(import ./codec :as codec)
(import ./conn :as conn)
(import ./pool :as pool)

(def log-ns
  "Log namespace of the command funnel — spelled out, since the
  file-derived default would carry the install path."
  "void.redis.command")

(def conn-dyn
  "Dynamic binding: the checked-out connection of this fiber."
  :void.redis/conn)

(def client-dyn
  "Dynamic binding: client override — set it to run a scope against a
  client other than the started :redis/client component (tests,
  tooling, a second redis)."
  :void.redis/client)

(var current-client
  "The value of the running :redis/client component (set by its
  :start). One per process, like plugin/current-boot."
  nil)

(defn active-client
  "The client this fiber runs against: the `client-dyn` override, else
  the started component."
  []
  (or (dyn client-dyn)
      current-client
      (error "void/redis is not started — no :redis/client component (or bind the client-dyn dynamic)")))

(defn active-pool
  "The connection pool of the active client."
  []
  ((active-client) :pool))

(defn active-codec
  "The codec of the active client — what [:redis :codec] named."
  []
  ((active-client) :codec))

(defn key-prefix
  "The string every key built through this client is prefixed with."
  []
  ((active-client) :prefix))

(defn prefixed
  ``A key as it is sent to the server. The prefix is what lets one
  redis serve several applications — and one laptop several checkouts
  — without them writing over each other.``
  [k]
  (def p (key-prefix))
  (if (empty? p) (string k) (string p k)))

(defn unprefixed
  "The application's spelling of a key the server sent back (KEYS,
  SCAN, a keyspace notification)."
  [k]
  (def p (key-prefix))
  (if (and (not (empty? p)) (string/has-prefix? p k))
    (string/slice k (length p))
    (string k)))

# -- connection scope ----------------------------------------------------

(defn with-conn*
  ``Run (f conn) with a connection checked out into `conn-dyn`.
  Re-entrant: an already-bound connection is reused and not returned
  early.``
  [f]
  (if-let [c (dyn conn-dyn)]
    (f c)
    (do
      (def p (active-pool))
      (def c (pool/checkout p))
      (defer (pool/checkin p c)
        (with-dyns [conn-dyn c]
          (f c))))))

(defmacro with-conn
  ``Run the body on one connection from the pool:

      (redis/with-conn
        (redis/command ["MULTI"])
        (redis/command ["INCR" "hits"])
        (redis/command ["EXPIRE" "hits" 60])
        (redis/command ["EXEC"]))

  Re-entrant, and implied by every single command — reach for it when
  several commands must share a session (MULTI/EXEC, WATCH, a script
  that reads what it just wrote).``
  [& body]
  ~(,with-conn* (fn with-conn-body [_] ,;body)))

(defn scoped?
  "True inside a `with-conn` scope — where a connection may not be
  replaced under the caller."
  []
  (not (nil? (dyn conn-dyn))))

# -- the command funnel --------------------------------------------------

(defn- elapsed-us [t0]
  (math/round (* 1_000_000 (- (os/clock :monotonic) t0))))

(defn- run-on [client c f label]
  (def p (client :pool))
  (def t0 (os/clock :monotonic))
  (def [ok res] (protect (f c)))
  (def us (elapsed-us t0))
  (pool/note-command! p us)
  (unless ok
    (log/error "redis command failed" :ns log-ns
               :command label :us us
               :err (if (dictionary? res) (get res :message (describe res)) (describe res)))
    (error res))
  (log/debug "redis command" :ns log-ns :command label :us us)
  res)

(defn- label-of [args]
  (when (indexed? args)
    (string/ascii-upper (string (get args 0 "")))))

(def- blocking-commands
  ``Commands the server holds the reply to on purpose. A lost reply to
  one of these may have carried an element the server had already
  removed — replaying the command would take a second one — so the
  funnel's retry refuses them and lets the error out. XREAD and
  XREADGROUP are here wholesale: whether they block depends on an
  argument, and the safe side of that guess is not retrying.``
  {"BLPOP" true "BRPOP" true "BLMOVE" true "BRPOPLPUSH" true
   "BLMPOP" true "BZPOPMIN" true "BZPOPMAX" true "BZMPOP" true
   "XREAD" true "XREADGROUP" true "WAIT" true "WAITAOF" true})

(defn- blocking-label?
  [label]
  (truthy? (get blocking-commands label)))

(defn execute
  ``The funnel: run (f conn) on the fiber's connection, or on one taken
  from the pool for the call. Times it into the pool metrics, logs it
  at :debug, discards a connection whose protocol state is in doubt
  (any checkin of a connection that is not conn/clean? closes it), and
  retries once when a pooled socket turns out to have been closed
  while idle (see the module docstring for what that trades).
  `no-retry` turns the retry off for this call — what a blocking
  command needs, where a replay is not idempotent even in principle.``
  [f &opt label no-retry]
  (def client (active-client))
  (if (scoped?)
    (run-on client (dyn conn-dyn) f label)
    (do
      (def p (client :pool))
      (var out nil)
      (var attempt 0)
      (var done false)
      (while (not done)
        (++ attempt)
        (def c (pool/checkout p))
        (def [ok res]
          (protect (defer (pool/checkin p c)
                     (with-dyns [conn-dyn c]
                       (run-on client c f label)))))
        (cond
          ok (do (set out res) (set done true))

          (and (= 1 attempt)
               (not no-retry)
               (client :retry)
               (conn/fatal? res)
               (not (c :fresh)))
          (log/debug "the pooled connection had been closed — retrying once"
                     :ns log-ns :command label :id (c :id))

          (error res)))
      out)))

(defn call
  ``Run one command. Arguments are what ./resp accepts — strings,
  numbers, keywords — and the reply is what ./resp decoded.

      (state/call ["SET" "k" "v" "EX" 60])

  An error reply throws (see conn/command-error); `opts` :raw returns
  it as a value instead, and :timeout overrides the read timeout for a
  blocking command. A blocking command is never retried: its reply may
  carry an element the server already removed, and a replay would take
  a second one.``
  [args &opt opts]
  (def label (label-of args))
  (execute (fn one [c] (conn/call c args opts)) label
           (blocking-label? label)))

(defn pipeline
  "Run several commands in one round trip on one connection. See
  conn/pipeline for what it does and does not guarantee. A pipeline
  carrying a blocking command is, like the command itself, never
  retried."
  [commands &opt opts]
  (execute (fn many [c] (conn/pipeline c commands opts))
           (string "PIPELINE(" (length commands) ")")
           (truthy? (some |(blocking-label? (label-of $)) commands))))

(defn codec-encode
  "Encode a value with the active client's codec."
  [v]
  (codec/encode (active-codec) v))

(defn codec-decode
  "Decode a reply with the active client's codec."
  [v]
  (codec/decode (active-codec) v))
