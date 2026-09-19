### void/db-postgres/listener — LISTEN/NOTIFY on a connection of its own.
###
### Postgres delivers a notification to the *session* that ran LISTEN.
### That single sentence is why this cannot live on the pool: LISTEN
### issued through a checkout binds the subscription to whichever
### connection happened to serve it, and the next checkout — a
### different connection — hears nothing. So a listener owns one
### connection, outside the pool, for as long as it is subscribed.
###
### The connection is otherwise idle, which is what makes it cheap: the
### listening fiber parks in fdwait on the socket and costs nothing until
### the server actually says something. One fiber, one connection, any
### number of channels.
###
###     (def l (listener/open conninfo))
###     (listener/start! l)
###     (listener/subscribe! l "orders" (fn [n] (print (n :payload))))
###     ...
###     (listener/stop! l)
###
### A handler runs in the listening fiber, so it must not block for
### long and must not touch this connection; queue the work, or take a
### pooled connection of your own. An error in a handler is logged and
### the next handler still runs — one bad subscriber does not silence
### the rest.
###
### Two fibers must never read one PGconn, so `subscribe!` does not
### issue its own LISTEN. It records what it wants and interrupts the
### wait (conn/interrupt! — the watchers are dropped, the connection is
### not), and the listening fiber, which is the only fiber that ever
### touches the connection, reconciles what is subscribed with what is
### wanted before parking again.
###
### Delivery is at-most-once, and that is Postgres', not ours: a
### notification sent while nobody is connected is gone, and a listener
### that reconnects has missed whatever happened in between. Anything
### that must not be missed belongs in a table the listener is told to
### go and read — which is the usual shape anyway, since a payload is
### capped at 8000 bytes.

(import void/core/log :as log)
(import ./conn :as conn)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.db.postgres.listen")

(def default-backoff
  ``Reconnect delays in seconds: the first retry is quick because most
  disconnections are a blip, and the ceiling keeps a listener against a
  server that is down from becoming the reason it stays down.``
  {:min 0.2 :max 30 :factor 2})

# -- identifiers ---------------------------------------------------------

(defn quote-channel
  {:params [:any] :ret :string :throws [:string]}
  ``A channel name as a quoted SQL identifier. LISTEN takes no
  parameters — the name is part of the statement — so it is quoted
  rather than interpolated, and a name that cannot be quoted (a NUL
  byte, or nothing at all) is refused.``
  [name]
  (def s (string name))
  (when (empty? s)
    (error "postgres: a notification channel needs a name"))
  (when (index-of 0 s)
    (errorf "postgres: %q is not a channel name" s))
  (string `"` (string/replace-all `"` `""` s) `"`))

# -- the listener --------------------------------------------------------

(defn open
  {:params [:string (or @{:connect-timeout :any :decode :any :backoff :any
                          :on-error :any & r}
                        :nil)]
   :ret @{:conninfo :string :opts :any
          :backoff @{:min :number :max :number :factor :number}
          :conn (or PgConn
                    :nil)
          :wanted @{:string @[(fn [PgNotification] :any)]}
          :active @{:string :boolean}
          :fiber (or :fiber :nil)
          :wakeup :abstract
          :running :boolean
          :stopped :boolean
          :stats @{:notifications :number :dispatched :number :errors :number
                   :connects :number :reconnects :number}}}
  ``A listener over `conninfo`, not yet running. opts:

    :connect-timeout  seconds for the handshake (as ./conn)
    :decode           ./types options — a payload is text, so this
                      only matters if a handler is given one back
    :backoff          {:min :max :factor} reconnect delays
    :on-error         (fn [stage err]) besides the log line — for a
                      component that wants to fail its health check``
  [conninfo &opt opts]
  (default opts {})
  @{:conninfo conninfo
    :opts opts
    :backoff (merge default-backoff (get opts :backoff {}))
    :conn nil
    # channel -> array of handlers, the subscriptions that are wanted
    :wanted @{}
    # channel -> true, the LISTENs actually issued on :conn
    :active @{}
    :fiber nil
    # what wakes the loop while it has no connection to be woken on:
    # a listener with no channels holds no connection at all, and a
    # first subscription has to reach it somehow
    :wakeup (ev/chan 1)
    :running false
    :stopped false
    :stats @{:notifications 0 :dispatched 0 :errors 0 :connects 0
             :reconnects 0}})

(defn channels
  {:params [@{:wanted @{:string @[(fn [PgNotification] :any)]} & r}] :ret @[:string]}
  "The channels this listener has at least one handler for."
  [l]
  (sorted (filter |(not (empty? (get-in l [:wanted $]))) (keys (l :wanted)))))

(defn stats
  {:params [@{:stats @{:notifications :number :dispatched :number :errors :number
                       :connects :number :reconnects :number}
              :conn (or @{:pg (or :pointer :nil) :closed :boolean :broken :boolean & r} :nil)
              :running :boolean :wanted @{:string @[(fn [PgNotification] :any)]} & r}]
   :ret @{:notifications :number :dispatched :number :errors :number
          :connects :number :reconnects :number
          :channels :number :connected :boolean :running :boolean}}
  "Point-in-time counters plus the connection state."
  [l]
  (merge (table/to-struct (l :stats))
         {:channels (length (channels l))
          :connected (and (l :conn) (conn/live? (l :conn)) true)
          :running (l :running)}))

# -- subscription --------------------------------------------------------

(defn- nudge!
  {:params [@{:conn (or @{:pg (or :pointer :nil) :closed :boolean :broken :boolean & r} :nil)
              :wakeup :abstract & r}]
   :ret :nil}
  ``Wake the listening fiber, whichever way it is parked: on the
  socket (interrupt the wait — the connection itself is untouched) or,
  with no channels and so no connection, on the wakeup channel.

  The listening fiber is the only one that may touch the connection,
  so this is how a change of subscriptions travels: as a wake-up, not
  as a statement issued from here.``
  [l]
  (when-let [c (l :conn)]
    (when (conn/live? c) (conn/interrupt! c)))
  (when (zero? (ev/count (l :wakeup)))
    (ev/give (l :wakeup) true))
  nil)

(defn subscribe!
  {:params [@{:wanted @{:string @[(fn [PgNotification] :any)]}
              :conn (or @{:pg (or :pointer :nil) :closed :boolean :broken :boolean & r} :nil)
              :wakeup :abstract & r}
            :any g]
   :ret g
   :where {g (fn [PgNotification] :any)}
   :throws [:string]}
  ``Call `f` with every notification on `channel`:
  {:channel :payload :pid}. Returns `f`, which is also what
  `unsubscribe!` takes back.

  Subscribing before `start!` is fine — nothing is issued until the
  listener runs — and so is subscribing while it runs, which wakes the
  listening fiber to issue the LISTEN.``
  [l channel f]
  (quote-channel channel)
  (def name (string channel))
  (unless (get-in l [:wanted name]) (put-in l [:wanted name] @[]))
  (array/push (get-in l [:wanted name]) f)
  (nudge! l)
  f)

(defn unsubscribe!
  {:params [@{:wanted @{:string @[(fn [PgNotification] :any)]}
              :conn (or @{:pg (or :pointer :nil) :closed :boolean :broken :boolean & r} :nil)
              :wakeup :abstract & r}
            :any (or (fn [PgNotification] :any) :nil)]
   :ret :nil}
  ``Remove one handler, or every handler of a channel when `f` is
  omitted. The UNLISTEN follows once the channel has no handlers left.``
  [l channel &opt f]
  (def name (string channel))
  (def hs (get-in l [:wanted name]))
  (when hs
    (if (nil? f)
      (array/clear hs)
      (when-let [i (index-of f hs)] (array/remove hs i)))
    (nudge! l))
  nil)

# -- the listening fiber -------------------------------------------------

(defn- dispatch!
  {:params [@{:wanted @{:string @[(fn [PgNotification] :any)]}
              :stats @{:notifications :number :dispatched :number :errors :number & r}
              & r}
            PgNotification]
   :ret :nil}
  "Run every handler subscribed to a notification's channel, counting
  and logging a handler that throws rather than letting it silence
  the ones after it."
  [l note]
  (put-in l [:stats :notifications] (inc (get-in l [:stats :notifications])))
  (each f (or (get-in l [:wanted (note :channel)]) [])
    (def [ok err] (protect (f note)))
    (if ok
      (put-in l [:stats :dispatched] (inc (get-in l [:stats :dispatched])))
      (do
        (put-in l [:stats :errors] (inc (get-in l [:stats :errors])))
        (log/error "notification handler failed" :ns log-ns
                   :channel (note :channel)
                   :err (if (string? err) err (describe err)))))))

(defn- sync-subscriptions!
  {:params [@{:conn (or PgConn
                        :nil)
              :active @{:string :boolean} :wanted @{:string @[(fn [PgNotification] :any)]} & r}]
   :ret :nil
   :throws [{:db/error :keyword :message :string & r}]}
  ``Make the session's LISTENs match what is wanted. Runs in the
  listening fiber, which is the only one allowed to use the
  connection.``
  [l]
  (def c (l :conn))
  (def wanted (from-pairs (map |[$ true] (channels l))))
  (each name (keys (l :active))
    (unless (get wanted name)
      (conn/execute c (string "UNLISTEN " (quote-channel name)))
      (put (l :active) name nil)))
  (each name (sorted (keys wanted))
    (unless (get (l :active) name)
      (conn/execute c (string "LISTEN " (quote-channel name)))
      (put (l :active) name true))))

(defn- drop-connection!
  {:params [@{:conn (or @{:pg (or :pointer :nil) :fds FdwaitPair :closed :boolean & r} :nil)
              & r}]
   :ret :nil}
  "Close and forget the listener's connection, if it has one — the
  first step of both an idle turn and a reconnect."
  [l]
  (when-let [c (l :conn)]
    (put l :conn nil)
    (put l :active @{})
    (protect (conn/close c)))
  nil)

(defn- connect!
  {:params [@{:conninfo :string :opts :any :conn :any
              :stats @{:connects :number & r} :wanted @{:string @[(fn [PgNotification] :any)]} & r}]
   :ret PgConn
   :throws [:string PgError]}
  "Open a fresh connection, count it and log it — the reconnect
  `listen-turn` makes whenever it does not already hold a live one."
  [l]
  (put l :conn (conn/open (l :conninfo)
                          {:connect-timeout (get-in l [:opts :connect-timeout])
                           :decode (get-in l [:opts :decode] {})}))
  (def s (l :stats))
  (put s :connects (inc (s :connects)))
  (log/info "listener connected" :ns log-ns
            :backend-pid (conn/backend-pid (l :conn))
            :channels (length (channels l)))
  (l :conn))

(defn- report!
  {:params [@{:stats @{:errors :number & r} :opts :any & r} :keyword :any]
   :ret :nil}
  "Count and log a turn's failure, and tell `:on-error` if the caller
  gave one."
  [l stage err]
  (put-in l [:stats :errors] (inc (get-in l [:stats :errors])))
  (log/warn "listener lost its connection" :ns log-ns
            :stage stage :err (if (string? err) err (describe err)))
  (when-let [f (get-in l [:opts :on-error])]
    (protect (f stage err)))
  nil)

(defn- listen-turn
  {:params [@{:conn (or PgConn
                        :nil)
              :stats @{:reconnects :number & r} :conninfo :string :opts :any
              :wanted @{:string @[(fn [PgNotification] :any)]} :active @{:string :boolean} & r}]
   :ret :nil
   :throws [:string PgError]}
  "Hold a connection carrying the right LISTENs and park on it until
  the server says something."
  [l]
  (unless (and (l :conn) (conn/live? (l :conn)))
    (when (l :conn)
      (drop-connection! l)
      (put-in l [:stats :reconnects] (inc (get-in l [:stats :reconnects]))))
    (connect! l))
  (sync-subscriptions! l)
  (def notes (conn/wait-for-input (l :conn)))
  # nil is an interrupted wait: either `nudge!` (the connection is
  # fine, and the next turn reconciles the subscriptions) or the socket
  # went away, which the liveness check at the top of the next turn
  # finds
  (when notes
    (each note notes (dispatch! l note))))

(defn- idle-turn
  {:params [@{:conn :any :wakeup :abstract & r}] :ret :any}
  ``Nothing is subscribed: hold no connection and park until something
  is. A listener declared in a composition that never subscribes
  should cost a fiber, not a backend.``
  [l]
  (drop-connection! l)
  (ev/take (l :wakeup)))

(defn- tick
  {:params [@{:conn :any :stopped :boolean
              :backoff @{:min :number :max :number :factor :number} & r}
            :number]
   :ret :number}
  ``One turn of the loop. Returns the delay to wait before the next
  turn — 0 when all is well, a backoff when the connection has to be
  rebuilt.``
  [l wait]
  (def [ok err]
    (protect (if (empty? (channels l)) (idle-turn l) (listen-turn l))))
  (cond
    ok 0
    (l :stopped) 0
    (do
      (report! l (if (l :conn) :listening :connecting) err)
      (drop-connection! l)
      (min (get-in l [:backoff :max])
           (max (get-in l [:backoff :min])
                (* wait (get-in l [:backoff :factor])))))))

(defn- run
  {:params [@{:stopped :boolean :conn :any :running :boolean
              :backoff @{:min :number :max :number :factor :number} & r}]
   :ret :nil}
  "The listening fiber's whole life: tick until stopped, dropping the
  connection and clearing `:running` on the way out."
  [l]
  (var wait 0)
  (while (not (l :stopped))
    (set wait (tick l wait))
    (when (and (pos? wait) (not (l :stopped)))
      (ev/sleep wait)))
  (drop-connection! l)
  (put l :running false)
  nil)

(defn start!
  {:params [@{:running :boolean :stopped :boolean :fiber (or :fiber :nil) & r}]
   :ret @{:running :boolean :stopped :boolean :fiber (or :fiber :nil) & r}}
  ``Run the listener in a fiber of its own. Idempotent; a listener
  that was stopped can be started again.``
  [l]
  (when (l :running) (break l))
  (put l :stopped false)
  (put l :running true)
  (put l :fiber (ev/go (fn listener-loop [] (run l))))
  l)

(defn stop!
  {:params [@{:stopped :boolean :conn :any :wakeup :abstract & r}]
   :ret @{:stopped :boolean :conn :any :wakeup :abstract & r}}
  ``Stop the listener. Only the listening fiber may touch the
  connection — closing it from here (another fiber) while it is parked
  in `sync-subscriptions!` or `connect!` would free a PGconn out from
  under it, a use-after-free. So this only sets `:stopped` and wakes the
  fiber (`nudge!`); the fiber closes the connection and clears `:running`
  as it leaves `run`.``
  [l]
  (put l :stopped true)
  (nudge! l)
  l)

# -- sending -------------------------------------------------------------

(defn notify-sql
  {:params [:any :any] :ret [:string [:string :string?]]}
  ``[sql params] for a NOTIFY. `pg_notify` rather than the NOTIFY
  statement: the channel is then a *parameter* — no identifier
  quoting, no way for a name built at runtime to become SQL — and it
  is the only spelling that can carry a payload from a variable.``
  [channel &opt payload]
  ["SELECT pg_notify($1, $2)" [(string channel) (when payload (string payload))]])

(defn notify!
  {:params [PgConn
            :any :any]
   :ret :nil
   :throws [{:db/error :keyword :message :string & r}]}
  ``Send a notification over an existing connection. From inside a
  transaction it is delivered on COMMIT and not at all on rollback,
  which is what makes NOTIFY safe to pair with the write it announces.``
  [c channel &opt payload]
  (def [sql params] (notify-sql channel payload))
  (conn/execute c sql params)
  nil)
