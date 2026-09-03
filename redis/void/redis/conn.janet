### void/redis/conn — one connection.
###
### A redis connection is a plain `net/` stream and a buffer, which is the
### whole reason this plugin has no native code and no thread pool:
### `net/read` and `net/write` park the fiber on the ev loop, so N fibers
### on N connections are N concurrent commands on one OS thread, and the
### only thing this module has to get right is the framing.
###
### Framing is where a redis client is usually wrong. Replies arrive in
### the order the commands were sent, so the connection is a queue, not
### a request/response pair: everything that reads must read *exactly*
### the frames it is owed, or the next caller gets someone else's
### answer. That is why the reader asks `resp/scan` how many bytes are
### missing rather than trying to parse what has arrived, why a read
### timeout marks the connection broken instead of returning (the reply
### is still coming, and the connection can never be trusted again),
### and why RESP3 push frames are pulled out of the stream here — an
### out-of-band frame that reached a caller counting replies would
### shift every reply after it by one.
###
###     (def c (conn/open {:host "127.0.0.1" :port 6379}))
###     (conn/call c ["SET" "k" "v"])            # -> "OK"
###     (conn/pipeline c [["GET" "k"] ["TTL" "k"]])   # one round trip
###     (conn/close c)
###
### Errors from the server are values coming out of ./resp and become
### throws here, because that is the layer that knows what was asked:
### the thrown table carries the code the caller branches on
### (WRONGTYPE, NOSCRIPT, MOVED), the whole reply, and the command that
### earned it. A failure of the *connection* is a different thing and
### says so with :fatal true — the pool discards those rather than
### handing them to the next fiber.
###
### One connection is meant for one fiber at a time (the pool sees to
### that). Writes take a lock anyway, because a subscriber connection
### has a second fiber sending SUBSCRIBE while the first is parked in
### `receive` — that is the one legitimate way two fibers share a
### connection, and it works precisely because they use opposite
### directions of it.

(import void/core/log :as log)
(import ./resp :as resp)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.redis")

(def default-read-size
  "Bytes asked of the kernel when the reply size is not yet known."
  4096)

(def compact-threshold
  ``Consumed bytes tolerated at the head of the read buffer before it
  is compacted. Nothing is copied in the common case — a buffer that
  is fully consumed is simply cleared — and this bounds the memory a
  pipelined batch holds on to in the uncommon one.``
  65536)

(var- next-id 0)

# -- errors --------------------------------------------------------------

(defn command-error
  ``An error reply as the value this module throws: the code a caller
  can branch on, the server's own line, and the command that earned
  it.``
  [reply args]
  (freeze
    {:redis/error true
     :code (get reply :code "")
     :message (string "redis: " (get reply :reply ""))
     :reply (get reply :reply "")
     :command (when args (string (resp/argument (first args))))}))

(defn connection-error
  ``A failure of the connection itself rather than of a command.
  :fatal marks it: the pool discards a connection that raised one,
  because what is left of the protocol state on it is unknown.``
  [c what &opt cause]
  (freeze
    {:redis/error true
     :code "CONNECTION"
     :fatal true
     :message (string "redis: " what
                      (when cause (string ": " (if (string? cause) cause (describe cause)))))
     :server (get-in c [:opts :describe] "")}))

(defn error?
  "Is this value (or thrown error) a redis error?"
  [v]
  (and (dictionary? v) (truthy? (get v :redis/error))))

(defn fatal?
  "Did this error break the connection, rather than just fail a
  command?"
  [v]
  (and (dictionary? v) (truthy? (get v :fatal))))

(defn error-code
  "The leading code of a redis error (\"WRONGTYPE\", \"NOSCRIPT\",
  \"MOVED\", \"CONNECTION\"), or nil."
  [v]
  (when (dictionary? v) (get v :code)))

# -- opening -------------------------------------------------------------

(defn- deadline-call
  ``Run `f` under a timeout without touching the caller's root task:
  the work runs in a supervised child task, and only that task is
  cancelled. `ev/deadline` on the caller would cancel the *request*
  a pooled connection is serving — the bug class the kernel documents.``
  [timeout f on-timeout]
  (def slot @{})
  (def sup (ev/chan 1))
  (def task (ev/go (fn timed []
                     (put slot :value (f))
                     (put slot :done true))
                   nil sup))
  (when (and timeout (pos? timeout)) (ev/deadline timeout task task))
  (def [status fiber] (ev/take sup))
  (cond
    (= :error status) (error (fiber/last-value fiber))
    # a flag rather than the value: whether the work finished is not
    # something the value can answer for
    (slot :done) (slot :value)
    (on-timeout)))

(var tls-connect
  ``How a `{:tls true}` connection (a rediss:// URL) is opened —
  `(fn [host port opts] stream)` — or nil when this composition has
  no TLS. `void/tls` installs its connector here on load; while it is nil,
  an encrypted target is refused with both ways out named rather than
  quietly spoken to in plaintext.``
  nil)

(defn- connect-stream [opts]
  (def timeout (get opts :connect-timeout 5))
  (def [host port]
    (if-let [sock (get opts :unix)]
      [:unix sock]
      [(get opts :host "127.0.0.1") (get opts :port 6379)]))
  (when (get opts :tls)
    (when (get opts :unix)
      (error "redis: :tls over a :unix socket makes no sense — a unix socket does not cross a network"))
    (when (nil? tls-connect)
      (errorf (string "redis: %s asks for TLS and this composition has none — add "
                      ":void/tls to :plugins, or terminate the TLS in "
                      "front of redis and point [:redis :url] at the plaintext side")
              (string (get opts :host) ":" (get opts :port)))))
  (deadline-call
    timeout
    (fn []
      (if (get opts :tls)
        (tls-connect host (string port) {:timeout timeout})
        (net/connect host port)))
    (fn [] (errorf "redis: connecting to %s timed out after %.1fs"
                   (if (get opts :unix) (string "unix:" (get opts :unix))
                     (string (get opts :host) ":" (get opts :port)))
                   timeout))))

(defn describe-target
  "What a set of connection options points at, for logs and errors."
  [opts]
  (if-let [sock (get opts :unix)]
    (string "unix:" sock)
    (string (get opts :host "127.0.0.1") ":" (get opts :port 6379))))

# -- reading -------------------------------------------------------------

(defn- mark-broken! [c]
  (put c :broken true)
  c)

(defn- compact! [c]
  (def pos (c :pos))
  (cond
    (zero? pos) nil
    (= pos (length (c :buf))) (do (buffer/clear (c :buf)) (put c :pos 0))
    (> pos compact-threshold)
    (do (def tail (string/slice (c :buf) pos))
        (buffer/clear (c :buf))
        (buffer/push (c :buf) tail)
        (put c :pos 0)))
  nil)

(defn- read-more! [c want timeout]
  ``Read until the buffer is `want` bytes long. `want` comes from
  `resp/scan`, so a blob that is still arriving is asked for in one
  read rather than discovered a chunk at a time.``
  (def s (c :stream))
  (def buf (c :buf))
  (while (< (length buf) want)
    (def before (length buf))
    # a method call, not net/read: the stream may be a TLS session, which
    # answers :read with the same signature
    (def [ok result]
      (protect (:read s (max default-read-size (- want before)) buf timeout)))
    (unless ok
      (mark-broken! c)
      (error (connection-error c "read failed" result)))
    (when (or (nil? result) (= before (length buf)))
      (mark-broken! c)
      (error (connection-error c "the server closed the connection"))))
  nil)

(def no-timeout
  ``The :timeout that means "do not time this read out at all" —
  spelled, rather than nil, because `{:timeout nil}` is a struct with
  no :timeout key in it and would silently mean the default.``
  :none)

(defn- read-timeout [c opts]
  (def t (get opts :timeout :default))
  (cond
    (= :default t) (get-in c [:opts :timeout] 5)
    (= no-timeout t) nil
    t))

(defn receive
  ``Read one frame, whatever it is — a reply, or a RESP3 push. Blocks
  the fiber, not the loop. `opts` takes a :timeout of its own, which is
  what a blocking command (BLPOP, XREAD BLOCK) needs: the server holds
  the reply for as long as it was told to, and a read timeout under
  that would break a connection that is working exactly as asked.
  `:none` waits for as long as it takes.``
  [c &opt opts]
  (default opts {})
  (when (c :closed) (error (connection-error c "the connection is closed")))
  (def timeout (read-timeout c opts))
  (var out nil)
  (var done false)
  (while (not done)
    (def [state n]
      (let [[ok r] (protect (resp/scan (c :buf) (c :pos)
                                       (get-in c [:opts :max-bulk])))]
        (unless ok
          (mark-broken! c)
          (error (connection-error c "the server is not speaking RESP" r)))
        r))
    (if (= :done state)
      # the scanner and the grammar are written to agree, but only one
      # of them is load-bearing for :pos — a frame the grammar refuses
      # (or that blows up a capture function) must break the
      # connection, never leave :pos unmoved for the next owner to
      # trip over the same byte
      (let [[ok parsed] (protect (resp/parse (c :buf) (c :pos)))]
        (unless (and ok parsed)
          (mark-broken! c)
          (error (connection-error c "the server is not speaking RESP"
                                   (if ok "the frame does not parse" parsed))))
        (def [value end] parsed)
        (put c :pos end)
        (compact! c)
        (set out value)
        (set done true))
      (read-more! c n timeout)))
  out)

(defn- dispatch-push [c value]
  (if-let [handler (c :on-push)]
    (handler value)
    (log/debug "dropping an unexpected push frame" :ns log-ns
               :kind (first (resp/push-items value)))))

(defn receive-reply
  ``Read the next *reply*: attribute frames are skipped (RESP3 metadata
  a client that does not use it must ignore) and push frames are
  handed to the connection's :on-push before the wait resumes. What
  comes back is the frame the caller is owed, which is the invariant
  everything counting replies depends on.``
  [c &opt opts]
  (var out nil)
  (var done false)
  (while (not done)
    (def v (receive c opts))
    (cond
      (resp/attribute? v) nil
      (resp/push? v) (dispatch-push c v)
      (do (put c :pending (max 0 (dec (c :pending))))
          (set out v)
          (set done true))))
  out)

# -- writing -------------------------------------------------------------

(defn- write! [c bytes]
  (when (c :closed) (error (connection-error c "the connection is closed")))
  (def timeout (get-in c [:opts :timeout] 5))
  (def [ok err]
    (protect (ev/with-lock (c :lock)
               (:write (c :stream) bytes timeout))))
  (unless ok
    (mark-broken! c)
    (error (connection-error c "write failed" err)))
  nil)

(defn- note-sent!
  ``Account for one command going out: it is owed a reply (`:pending`),
  and a few commands open or close state that outlives the exchange —
  an open MULTI queues the next owner's commands into this owner's
  transaction, and a standing WATCH aborts it. The pool asks `clean?`
  before reusing a connection, and this is where the answer is kept.``
  [c args]
  (put c :commands (inc (c :commands)))
  (put c :pending (inc (c :pending)))
  (def head (first args))
  (case (when (or (bytes? head) (keyword? head) (symbol? head))
          (string/ascii-upper (string head)))
    "MULTI" (put c :in-multi true)
    "EXEC" (do (put c :in-multi false) (put c :watching false))
    "DISCARD" (do (put c :in-multi false) (put c :watching false))
    "WATCH" (put c :watching true)
    "UNWATCH" (put c :watching false)
    "RESET" (do (put c :in-multi false) (put c :watching false)))
  nil)

(defn send
  "Write one command. The reply is left in the stream for `receive`."
  [c args]
  (note-sent! c args)
  (write! c (resp/encode args)))

(defn send-all
  "Write several commands as one buffer — the write half of a
  pipeline, and the reason a pipeline is one round trip rather than
  N."
  [c commands]
  (each args commands (note-sent! c args))
  (write! c (resp/encode-all commands)))

# -- commands ------------------------------------------------------------

(defn call
  ``Send one command and return its reply. An error reply is thrown
  (see `command-error`) unless `opts` asks for it `:raw`, which is what
  a caller that expects a failure — a probe, a handshake against a
  server that may be too old — wants.

      (conn/call c ["GET" "user:1"])
      (conn/call c ["BLPOP" "q" 0] {:timeout :none})  # wait forever``
  [c args &opt opts]
  (default opts {})
  (send c args)
  (def v (receive-reply c opts))
  (if (and (resp/error? v) (not (opts :raw)))
    (error (command-error v args))
    v))

(defn pipeline
  ``Send every command, then read every reply: one round trip instead
  of N, which for a redis on another host is the difference between a
  batch and a queue.

      (conn/pipeline c [["INCR" "hits"] ["EXPIRE" "hits" "60"]])

  Unlike MULTI/EXEC this is not atomic — other clients' commands
  interleave with these. A failed command does not stop the rest (the
  server ran them all), so by default the first error is thrown with
  the results collected around it under :results and :index; `:raw`
  returns error values in place instead.``
  [c commands &opt opts]
  (default opts {})
  (when (empty? commands) (break @[]))
  (send-all c commands)
  (def out @[])
  (each _ commands (array/push out (receive-reply c opts)))
  (unless (opts :raw)
    (loop [i :range [0 (length out)] :let [v (in out i)] :when (resp/error? v)]
      (error (merge (command-error v (in commands i))
                    {:index i :results (freeze out)}))))
  out)

# -- the handshake -------------------------------------------------------

(defn- hello-map
  "The HELLO reply as a table, whichever protocol answered it: RESP3
  sends a map, RESP2 the same pairs flattened into an array."
  [reply]
  (cond
    (dictionary? reply) reply
    (indexed? reply)
    (let [out @{}]
      (loop [i :range [0 (length reply) 2]]
        (put out (in reply i) (get reply (inc i))))
      out)
    @{}))

(defn- fall-back-to-resp2?
  ``Is this HELLO failure the server saying it is too old, rather than
  the server saying no? A redis before 6 has no HELLO command at all,
  and a proxy in front of one answers the same way; NOPROTO is the
  in-between case — HELLO exists, version 3 does not. Everything else
  (WRONGPASS, NOAUTH, NOPERM) is an answer and must not be retried in
  a way that hides it.``
  [reply]
  (def line (string/ascii-lower (get reply :reply "")))
  (or (= "NOPROTO" (get reply :code))
      (string/find "unknown command" line)
      (string/find "unknown subcommand" line)))

(defn- handshake! [c opts]
  (def want (get opts :protocol 3))
  (def user (get opts :username))
  (def pass (get opts :password))
  (var authenticated false)
  (var protocol 2)
  (var server @{})

  (when (>= want 3)
    (def args (if pass
                ["HELLO" "3" "AUTH" (or user "default") pass]
                ["HELLO" "3"]))
    (def reply (call c args {:raw true}))
    (cond
      (resp/error? reply)
      (unless (fall-back-to-resp2? reply)
        (error (command-error reply ["HELLO"])))
      (do
        (set server (hello-map reply))
        (set protocol (get server "proto" 3))
        (set authenticated (truthy? pass)))))

  (when (and pass (not authenticated))
    (call c (if user ["AUTH" user pass] ["AUTH" pass])))

  (def db (get opts :database 0))
  (when (and db (pos? db)) (call c ["SELECT" db]))

  (when-let [name (get opts :client-name)]
    # a name is a convenience for CLIENT LIST, never a requirement:
    # a server that refuses it (an old one, a proxy) is still usable
    (def r (call c ["CLIENT" "SETNAME" name] {:raw true}))
    (when (resp/error? r)
      (log/debug "the server refused CLIENT SETNAME" :ns log-ns
                 :name name :reply (get r :reply))))

  (put c :protocol protocol)
  (put c :server (freeze server))
  (put c :server-id (get server "id"))
  (put c :database (or db 0))
  c)

# -- lifecycle -----------------------------------------------------------

(defn open
  ``Open one connection and complete its handshake (HELLO/AUTH/SELECT/
  CLIENT SETNAME). Options are what ./config produces:

    :host :port         or :unix for a socket path
    :username :password credentials; a password alone is the classic
                        `requirepass`, both is an ACL user
    :database           SELECTed when non-zero
    :protocol           3 asks for RESP3 and accepts RESP2 from a
                        server too old to have HELLO; 2 never asks
    :client-name        CLIENT SETNAME, for CLIENT LIST
    :connect-timeout    seconds to reach the server
    :timeout            seconds any one read or write may take``
  [&opt opts]
  (default opts {})
  (def stream (connect-stream opts))
  (set next-id (inc next-id))
  (def c
    @{:stream stream
      :opts (merge {:describe (describe-target opts)} opts)
      :buf @""
      :pos 0
      :lock (ev/lock)
      :id next-id
      :generation 0
      :commands 0
      :pending 0
      :in-multi false
      :watching false
      :protocol 2
      :server @{}
      :database 0
      :closed false
      :broken false
      :on-push nil})
  (def [ok err] (protect (handshake! c opts)))
  (unless ok
    (protect (:close stream))
    (put c :closed true)
    (error err))
  c)

(defn open?
  "Is this connection usable — open, and not broken by a failure?"
  [c]
  (and (not (c :closed)) (not (c :broken))))

(defn clean?
  ``Is the protocol state of this connection known-good: every sent
  command answered, no MULTI open, no WATCH standing? The pool refuses
  to reuse one that is not — a fiber cancelled between a send and its
  reply leaves the answer in flight for the next owner to read as its
  own, and an open transaction would swallow that owner's commands.``
  [c]
  (and (zero? (c :pending))
       (not (c :in-multi))
       (not (c :watching))))

(defn close
  "Close the connection. Closing twice is not an error — the pool and
  a component's :stop both do it on the way down."
  [c]
  (unless (c :closed)
    (put c :closed true)
    (protect (:close (c :stream))))
  nil)

(defn reconnect!
  ``Replace the socket under an existing connection value and redo the
  handshake, keeping the connection's identity (and whatever holds a
  reference to it). The generation counter is what tells a caller that
  everything session-scoped — SELECTed database aside, which is redone
  — is gone: subscriptions, WATCHes, an open MULTI.``
  [c]
  (protect (:close (c :stream)))
  (def opts (c :opts))
  (def stream (connect-stream opts))
  (put c :stream stream)
  (put c :buf @"")
  (put c :pos 0)
  (put c :pending 0)
  (put c :in-multi false)
  (put c :watching false)
  (put c :closed false)
  (put c :broken false)
  (put c :generation (inc (c :generation)))
  (handshake! c opts)
  c)

(defn info
  "What this connection is: server version, protocol, database, and
  how many times it has been replaced."
  [c]
  {:id (c :id)
   :server (get-in c [:opts :describe])
   :server-version (get (c :server) "version")
   :mode (get (c :server) "mode")
   :role (get (c :server) "role")
   :client-id (c :server-id)
   :protocol (c :protocol)
   :database (c :database)
   :generation (c :generation)
   :commands (c :commands)
   :open (open? c)})

(defn ping
  "PING, as the pool's liveness check. Returns true, or throws."
  [c]
  (def r (call c ["PING"]))
  (or (= "PONG" r) (= "PONG" (get r 0))))
