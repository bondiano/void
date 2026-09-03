### void/ws/rooms — the connection registry, rooms and broadcast.
###
### A room is a **set of connections under a keyword**, and that is the
### whole abstraction. There is no membership store, no persistence and
### no delivery guarantee: a room is a fan-out list, it lives as long
### as the process does, and a connection leaves it by disconnecting.
### Anything durable — who is in a channel across restarts, a message
### that must survive a reconnect — is `void/db` and `void/bus`, and a
### room that pretended otherwise would be a worse version of both.
###
### **One encode, N enqueues.** A broadcast frames the message once and
### hands the *same bytes* to every member, which is possible only because
### a server never masks (RFC 6455 §5.3): the frame that goes to the
### thousandth connection is byte for byte the one that went to the first.
### That property is what makes B4 (1k connections, 10k msg/s) an
### exercise in queueing rather than in encoding.
###
### **Prefork is a boundary, and it is not hidden.** With
### `[:http :workers] > 1` each worker has its own registry, and a
### broadcast reaches the connections *that worker* holds — the same
### shape every other piece of per-worker state has and the
### same one `void/pressure` reports per worker. There is nothing to
### aggregate over: prefork workers share nothing but the listening
### socket. An application that needs a fan-out across workers (or
### across machines) already has the tool for it — publish the fact on
### `void/bus` and let every worker's subscriber broadcast locally:
###
###     (bus/defhandler on-post-created [msg]
###       (ws/broadcast! :feed (render (msg :payload))))
###
### Three lines, and the ones the socket layer must not guess for you.

(import void/core/log :as log)
(import ./conn :as conn)
(import ./frame :as frame)

(def log-ns "void.ws")

(def defaults
  ``Registry settings. `:ping-interval` is how long a connection may
  be silent before it is pinged and `:pong-timeout` how long the pong
  may take; together they are the only thing that tells a live idle
  peer from a socket whose other end stopped existing without saying
  so — TCP will not.``
  {:ping-interval 30
   :pong-timeout 10
   :sweep-interval 5
   :max-connections 4096})

(defn make
  "A registry: every open connection of this process, and the rooms
  they are in."
  [&opt opts]
  @{:conns @{}
    :rooms @{}
    :config (merge defaults (or opts {}))
    :sweeper nil
    :sweeping false
    :peak 0
    :total 0})

# -- membership ----------------------------------------------------------

(defn count-conns
  "How many connections this registry holds."
  [reg]
  (length (reg :conns)))

(defn full?
  "Is the registry at `[:ws :max-connections]`?"
  [reg]
  (>= (count-conns reg) (get-in reg [:config :max-connections])))

(defn register!
  "Add a connection to the registry."
  [reg conn]
  (put (reg :conns) (conn :id) conn)
  (put conn :registry reg)
  (put reg :total (inc (reg :total)))
  (put reg :peak (max (reg :peak) (count-conns reg)))
  conn)

(defn- room-set [reg name]
  (or (get (reg :rooms) name)
      (let [s @{}] (put (reg :rooms) name s) s)))

(defn join!
  ``Put a connection in a room (a keyword). Joining twice is joining
  once — membership is a set.``
  [reg conn name]
  (unless (keyword? name)
    (errorf "a room name is a keyword, got %q" name))
  (put (room-set reg name) (conn :id) conn)
  (put (conn :rooms) name true)
  conn)

(defn leave!
  "Take a connection out of one room. Empty rooms are forgotten —
  a room is its members."
  [reg conn name]
  (when-let [s (get (reg :rooms) name)]
    (put s (conn :id) nil)
    (when (empty? s) (put (reg :rooms) name nil)))
  (put (conn :rooms) name nil)
  conn)

(defn unregister!
  "Remove a connection from the registry and from every room it was
  in. Called from the connection's own close path, so it runs however
  the connection ended."
  [reg conn]
  (each name (keys (conn :rooms))
    (leave! reg conn name))
  (put (reg :conns) (conn :id) nil)
  conn)

(defn members
  "The connections in a room (an empty tuple for a room nobody is in)."
  [reg name]
  (tuple ;(sorted-by |($ :id) (values (get (reg :rooms) name {})))))

(defn room-names
  "Every room with at least one member."
  [reg]
  (tuple ;(sorted (keys (reg :rooms)))))

(defn connections
  "Every connection this registry holds."
  [reg]
  (tuple ;(sorted-by |($ :id) (values (reg :conns)))))

# -- broadcast -----------------------------------------------------------

(defn- fan-out
  "Queue already-framed bytes on every connection in `targets`.
  Returns how many took it."
  [targets bytes except]
  (var delivered 0)
  (each c targets
    (unless (or (and except (= (c :id) (except :id)))
                (not (conn/open? c)))
      (when (conn/enqueue-message! c bytes)
        (++ delivered))))
  delivered)

(defn broadcast!
  ``Send one message to every connection in a room. Returns the number
  of connections that took it — a connection whose queue overflowed is
  not one of them (see ./conn on what a full queue means).

  Options:
    :except  a connection not to send to (the sender, usually)
    :binary  frame as binary rather than text

  The message is encoded **once**: what goes out to every member is
  the same immutable string of bytes.``
  [reg name message &opt opts]
  (default opts {})
  (def bytes (frame/encode (if (opts :binary) :binary :text) message))
  (fan-out (members reg name) bytes (opts :except)))

(defn broadcast-all!
  "As broadcast!, to every connection of this process rather than to a
  room."
  [reg message &opt opts]
  (default opts {})
  (def bytes (frame/encode (if (opts :binary) :binary :text) message))
  (fan-out (connections reg) bytes (opts :except)))

(defn close-all!
  "Close every connection with a code — what the component's :stop
  does, so a drain says goodbye rather than cutting sockets."
  [reg &opt code reason]
  (default code :going-away)
  (each c (connections reg)
    (protect (conn/close! c code reason)))
  reg)

# -- liveness ------------------------------------------------------------

(defn sweep!
  ``One liveness pass: ping the connections that have been silent for
  `:ping-interval`, abandon the ones that never answered a ping within
  `:pong-timeout`, and forget the ones that are already closed.
  Returns {:pinged :abandoned :reaped}.``
  [reg]
  (def cfg (reg :config))
  (def now (os/clock :monotonic))
  (var pinged 0)
  (var abandoned 0)
  (var reaped 0)
  (each c (connections reg)
    (cond
      (conn/closed? c)
      (do (unregister! reg c) (++ reaped))

      (and (c :awaiting-pong)
           (> (- now (c :awaiting-pong)) (cfg :pong-timeout)))
      (do
        (log/debug "no pong — abandoning the connection" :ns log-ns
                   :conn (c :id) :waited (- now (c :awaiting-pong)))
        (conn/abandon! c)
        (unregister! reg c)
        (++ abandoned))

      (and (nil? (c :awaiting-pong))
           (conn/open? c)
           (> (- now (c :last-recv)) (cfg :ping-interval)))
      (do (conn/ping! c) (++ pinged))))
  {:pinged pinged :abandoned abandoned :reaped reaped})

(defn start-sweeper!
  ``Start the one fiber that keeps every connection of this process
  honest. One fiber, not one timer per socket: at a thousand
  connections the difference is a thousand fibers waking on their own
  schedules against one waking on a known one.``
  [reg]
  (def cfg (reg :config))
  (when (pos? (cfg :sweep-interval))
    (put reg :sweeping true)
    (put reg :sweeper
         (ev/go
           (fn ws-sweeper []
             # the loop reads a flag rather than being cancelled:
             # cancelling a fiber parked in ev/sleep raises inside it,
             # and an orderly shutdown should not have to print an
             # error to announce itself
             (while (reg :sweeping)
               (ev/sleep (cfg :sweep-interval))
               (when (reg :sweeping)
                 (def [ok err] (protect (sweep! reg)))
                 (unless ok
                   (log/error "websocket sweep failed" :ns log-ns
                              :error (if (string? err) err (describe err))))))))))
  reg)

(defn stop-sweeper!
  "Ask the sweeper to stop; it exits within one interval."
  [reg]
  (put reg :sweeping false)
  (put reg :sweeper nil)
  reg)

# -- status --------------------------------------------------------------

(defn status
  "What this process's socket layer looks like right now — the body of
  a health check and of `void ws status`."
  [reg]
  {:connections (count-conns reg)
   :peak (reg :peak)
   :total (reg :total)
   :limit (get-in reg [:config :max-connections])
   :rooms (tabseq [name :in (room-names reg)]
            name (length (get (reg :rooms) name {})))
   :sweeping (truthy? (reg :sweeping))
   :pid (os/getpid)})
