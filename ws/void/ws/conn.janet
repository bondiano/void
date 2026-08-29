### void/ws/conn — one websocket connection (SPEC §5.6, ADR-0028).
###
### **Two fibers and one socket.** The reader is the connection fiber
### the HTTP server already had: `ring/upgrade` hands it over and it
### never returns to HTTP, so a websocket costs no fiber the request
### did not already cost. The writer is the second one, and it exists
### for a single reason — **a broadcast must not be able to block on
### the slowest member of a room**. With one outbound queue per
### connection and a fiber draining it, `broadcast!` is N enqueues and
### returns; without it, one client on a phone in a lift would stall
### the fan-out for everybody.
###
### **What a full queue means.** The queue is bounded
### (`[:ws :send-queue]`), and when it fills the connection is closed
### with 1008 rather than quietly losing frames. That is the choice
### every broadcast hub has to make, and it is made this way because a
### websocket usually carries *deltas*: a client that silently missed
### one is looking at a screen that no longer describes anything,
### while a client that got disconnected reconnects and resyncs.
### `[:ws :overflow :drop]` inverts it for streams of independent
### facts (a ticker, a metrics feed) where a gap costs nothing; the
### drops are counted either way.
###
### **Liveness is not the reader's job.** The reader blocks with no
### timeout at all; the registry's sweeper (./rooms) pings idle
### connections and closes the ones that stop answering, which is one
### fiber for the whole process rather than a timer per socket. When
### it closes a socket the parked read wakes as EOF — exactly the path
### a peer disappearing takes.
###
### **The close handshake is finished, not faked** (RFC 6455 §5.5.1):
### a close frame is answered with a close frame carrying the peer's
### own code, and an endpoint that closed first waits for the answer
### up to `[:ws :close-timeout]` before dropping the TCP connection.

(import void/core/log :as log)
(import ./frame :as frame)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.ws")

(def defaults
  ``Per-connection limits. `:max-message` is the assembled size of a
  fragmented message and `:max-frame` the size of one piece of it:
  both exist because the peer *says* how much it is about to send, and
  a server that believes it has handed out its memory.``
  {:max-frame 1048576
   :max-message 1048576
   :send-queue 64
   :overflow :close
   :close-timeout 5})

# -- what this process's sockets have done -------------------------------
#
# Plain integers in one table, read by `stats` — the same public seam
# void/obs instruments void/http/client and void/db/pool through, so
# this module needs no knowledge that observability exists.

(def- counters
  @{:opened 0 :closed 0 :messages-in 0 :messages-out 0
    :frames-in 0 :frames-out 0 :bytes-in 0 :bytes-out 0
    :pings 0 :pongs 0 :dropped 0 :overflows 0 :errors 0})

(defn stats
  "What this process's websockets have done since it started."
  []
  (table/to-struct counters))

(defn reset-stats!
  "Zero the counters — for a test that asserts on them."
  []
  (eachk k counters (put counters k 0))
  nil)

(defn- count! [key &opt n]
  (put counters key (+ (get counters key 0) (or n 1))))

(var- next-id 0)

(defn- now [] (os/clock :monotonic))

# -- construction --------------------------------------------------------

(defn make
  ``A connection value over an already-upgraded socket. `opts` carries
  the limits above plus:
    :request   the upgrade request — an application reads its session,
               identity, params and headers off it, because the
               handshake went through the whole middleware chain
    :protocol  the negotiated subprotocol, or nil
    :registry  the registry this connection belongs to (./rooms)``
  [socket &opt opts]
  (default opts {})
  (def cfg (merge defaults (or opts {})))
  @{:id (++ next-id)
    :socket socket
    :request (get opts :request)
    :protocol (get opts :protocol)
    :registry (get opts :registry)
    :config cfg
    :outbox (ev/chan (cfg :send-queue))
    :state :open
    :rooms @{}
    # application scratch: what a handler wants to remember about this
    # peer between messages, and the reason no plugin needs a table of
    # its own keyed by connection
    :data @{}
    :opened (now)
    :last-recv (now)
    :awaiting-pong nil
    :sent 0
    :received 0
    :dropped 0
    :writer-done false})

(defn open?
  "Is this connection still able to carry application messages?"
  [conn]
  (= :open (conn :state)))

(defn closed?
  [conn]
  (= :closed (conn :state)))

(defn info
  "A snapshot of one connection, for a health endpoint, a log line or
  a test."
  [conn]
  {:id (conn :id)
   :state (conn :state)
   :protocol (conn :protocol)
   :rooms (tuple ;(sorted (keys (conn :rooms))))
   :age (- (now) (conn :opened))
   :idle (- (now) (conn :last-recv))
   :sent (conn :sent)
   :received (conn :received)
   :dropped (conn :dropped)
   :queued (ev/count (conn :outbox))})

# -- the outbound queue --------------------------------------------------

(defn- drop-socket! [conn]
  (put conn :state :closed)
  (protect (:close (conn :socket)))
  (protect (ev/chan-close (conn :outbox))))

(defn- overflow! [conn]
  (count! :overflows)
  (put conn :dropped (inc (conn :dropped)))
  (count! :dropped)
  (if (= :drop (get-in conn [:config :overflow]))
    false
    (do
      (log/warn "outbound queue full — closing the connection" :ns log-ns
                :conn (conn :id) :queue (ev/capacity (conn :outbox)))
      # a close frame would have to go through the same full queue, so
      # the socket is dropped and the peer sees an abnormal close —
      # which is the truth: it stopped reading
      (drop-socket! conn)
      false)))

(defn enqueue!
  ``Put already-framed bytes on this connection's outbound queue.
  Returns true when queued, false when the connection is gone or the
  queue overflowed.

  The full check and the give are one step on purpose: Janet's ev
  scheduler switches fibers only at yield points, and neither
  `ev/full` nor an `ev/give` with room to spare is one — so no other
  fiber can slip a frame in between them and turn the check into a
  lie.``
  [conn bytes]
  (def ch (conn :outbox))
  (cond
    (= :closed (conn :state)) false
    (ev/full ch) (overflow! conn)
    (do
      (ev/give ch bytes)
      true)))

(defn abandon!
  ``Drop the socket without a close frame. For a peer that has stopped
  answering pings there is nobody left to send a code to, and a close
  handshake with a dead connection is a five-second wait for nothing.``
  [conn]
  (drop-socket! conn)
  conn)

(def eof
  ``The sentinel that ends the writer. It goes through the queue like
  any other frame, which is the point: the writer closes the socket
  *after* the last thing queued behind it — a close frame handed to a
  channel is not a close frame on the wire, and a reader that closed
  the socket on the strength of `ev/count` being zero would cut its
  own goodbye (Janet hands a value straight to a parked taker without
  ever queuing it, so the count is zero before the write has begun).``
  :void.ws/eof)

(defn- writer
  "The fiber that drains the outbound queue onto the socket, and the
  only place the socket is closed on an orderly end."
  [conn]
  (def sock (conn :socket))
  (var running true)
  (while running
    (def bytes (ev/take (conn :outbox)))
    (cond
      (or (nil? bytes) (= eof bytes))
      (set running false)

      (let [[ok err] (protect (:write sock bytes))]
        (if ok
          (do (count! :frames-out)
              (count! :bytes-out (length bytes)))
          (do
            # a peer that went away mid-write is not worth a stack
            # trace; the reader is about to see the same EOF
            (log/debug "websocket write failed — peer gone" :ns log-ns
                       :conn (conn :id) :error (string err))
            (drop-socket! conn)
            (set running false))))))
  (put conn :writer-done true)
  (protect (:close sock)))

# -- sending -------------------------------------------------------------

(defn send-frame!
  "Frame and queue one message. `opcode` is a ./frame opcode keyword."
  [conn opcode &opt payload]
  (def queued (enqueue! conn (frame/encode opcode payload)))
  (when (and queued (not (frame/control? opcode)))
    (put conn :sent (inc (conn :sent)))
    (count! :messages-out))
  queued)

(defn enqueue-message!
  ``Queue already-framed *data* bytes and count them as a message —
  what a broadcast uses, having framed the message once for everybody
  (./rooms). Returns true when queued.``
  [conn bytes]
  (when (enqueue! conn bytes)
    (put conn :sent (inc (conn :sent)))
    (count! :messages-out)
    true))

(defn send!
  "Send a text message."
  [conn text]
  (send-frame! conn :text (string text)))

(defn send-binary!
  "Send a binary message."
  [conn bytes]
  (send-frame! conn :binary bytes))

(defn ping!
  "Send a ping with an optional ≤125-byte payload."
  [conn &opt payload]
  (count! :pings)
  (put conn :awaiting-pong (now))
  (send-frame! conn :ping payload))

(defn pong!
  "Send an unsolicited pong — RFC 6455 §5.5.3 allows one as a
  unidirectional heartbeat."
  [conn &opt payload]
  (send-frame! conn :pong payload))

(defn close!
  ``Begin the closing handshake: queue a close frame and give the peer
  up to :close-timeout to answer before the socket is dropped.
  Idempotent — closing a closing connection does nothing.``
  [conn &opt code reason]
  (when (= :open (conn :state))
    (put conn :state :closing)
    (send-frame! conn :close (frame/close-payload (or code :normal) reason))
    (def grace (get-in conn [:config :close-timeout]))
    (ev/go
      (fn close-grace []
        (ev/sleep grace)
        (unless (= :closed (conn :state))
          (log/debug "peer never answered the close frame" :ns log-ns
                     :conn (conn :id))
          (drop-socket! conn)))))
  conn)

# -- the reader ----------------------------------------------------------

(defn- consume! [buf n]
  (if (>= n (length buf))
    (buffer/clear buf)
    (let [rest (string/slice buf n)]
      (buffer/clear buf)
      (buffer/push buf rest))))

(defn- finish!
  ``End the connection: let the writer put whatever is still queued —
  the close frame, above all — on the wire, then close.``
  [conn close-info handlers]
  (unless (= :closed (conn :state))
    (unless (ev/full (conn :outbox))
      (ev/give (conn :outbox) eof))
    (def deadline (+ (now) (min 1 (get-in conn [:config :close-timeout] 1))))
    (while (and (not (conn :writer-done)) (< (now) deadline))
      (ev/sleep 0.002)))
  (put conn :state :closed)
  (protect (ev/chan-close (conn :outbox)))
  (protect (:close (conn :socket)))
  (count! :closed)
  # the registry unregisters here rather than in the plugin, so a
  # connection cannot outlive its rooms whichever way it ended
  (when-let [detach (get handlers :on-detach)] (protect (detach conn)))
  (when-let [h (get handlers :on-close)]
    (def [ok err] (protect (h conn close-info)))
    (unless ok
      (count! :errors)
      (log/error "websocket :on-close handler failed" :ns log-ns
                 :conn (conn :id) :error (if (string? err) err (describe err)))))
  close-info)

(defn- protocol-close!
  "Answer a protocol violation with the close code it names, and end."
  [conn code message]
  (when (= :open (conn :state))
    (put conn :state :closing)
    (send-frame! conn :close
                 (frame/close-payload
                   (if (frame/sendable-close-code? code) code 1002)
                   message)))
  {:code code :name (get frame/close-names code) :reason message})

(defn- run-handler [conn handlers key & args]
  (when-let [h (get handlers key)]
    (def [ok err] (protect (h conn ;args)))
    (unless ok
      (count! :errors)
      (log/error "websocket handler failed" :ns log-ns
                 :conn (conn :id) :stage key
                 :error (if (string? err) err (describe err)))
      # the peer is owed an answer the handler did not give: 1011 says
      # the failure was ours
      (close! conn :internal-error "handler error"))))

(defn serve
  ``Run one connection to its end: read frames, assemble messages,
  answer control frames and hand every complete message to
  `(:on-message handlers)`. Returns the close info
  `{:code :name :reason}`.

  `handlers` may carry :on-open (fn [conn]), :on-message
  (fn [conn message]), :on-close (fn [conn close-info]) and the
  :on-detach the registry unregisters with. A message is
  `{:type :text|:binary :data <string>}`.

  `leftover` are the bytes that arrived behind the handshake — the
  kernel hands them over rather than dropping them (ring/upgrade),
  because a client is allowed to send its first frame in the same
  packet as its request.``
  [conn handlers &opt leftover]
  (def sock (conn :socket))
  (def cfg (conn :config))
  (def buf (buffer/new 4096))
  (when (and leftover (pos? (length leftover)))
    (buffer/push buf leftover))
  (count! :opened)
  (ev/go (fn conn-writer [] (writer conn)))
  (run-handler conn handlers :on-open)

  # message assembly across fragments: the opcode the message started
  # with, and the pieces since
  (var frag-opcode nil)
  (def frag @"")

  (defn handle-frame [f]
    (def payload (f :payload))
    (count! :frames-in)
    (count! :bytes-in (length payload))
    (put conn :last-recv (now))
    (case (f :opcode)
      :ping (do (send-frame! conn :pong payload) nil)

      :pong (do (count! :pongs) (put conn :awaiting-pong nil) nil)

      :close
      (let [ci (frame/parse-close payload)]
        (if (= :closing (conn :state))
          # the answer to our own close: the handshake is complete
          ci
          (do
            (put conn :state :closing)
            # echo the peer's code back, except when it sent none —
            # 1005 is a code no endpoint may put on the wire (§7.4.1),
            # so an empty close is answered with an empty close
            (send-frame! conn :close
                         (if (= 1005 (ci :code))
                           ""
                           (frame/close-payload (ci :code))))
            ci)))

      :continuation
      (do
        (when (nil? frag-opcode)
          (error {:ws/close 1002 :message "a continuation frame with nothing to continue"}))
        (when (> (+ (length frag) (length payload)) (cfg :max-message))
          (error {:ws/close 1009
                  :message (string/format "message over the %d-byte limit"
                                          (cfg :max-message))}))
        (buffer/push frag payload)
        (when (f :fin)
          (def data (string frag))
          (def op frag-opcode)
          (set frag-opcode nil)
          (buffer/clear frag)
          (when (and (= :text op) (not (frame/utf8-valid? data)))
            (error {:ws/close 1007 :message "a text message must be UTF-8"}))
          (put conn :received (inc (conn :received)))
          (count! :messages-in)
          (run-handler conn handlers :on-message {:type op :data data}))
        nil)

      # a data frame: :text or :binary
      (do
        (when frag-opcode
          (error {:ws/close 1002
                  :message "a new data frame arrived inside a fragmented message"}))
        # the cap is on the message, so it is checked here as well as
        # on each continuation: a single unfragmented frame is a whole
        # message and must not be able to walk past the limit alone
        (when (> (length payload) (cfg :max-message))
          (error {:ws/close 1009
                  :message (string/format "message over the %d-byte limit"
                                          (cfg :max-message))}))
        (if (f :fin)
          (do
            (when (and (= :text (f :opcode)) (not (frame/utf8-valid? payload)))
              (error {:ws/close 1007 :message "a text message must be UTF-8"}))
            (put conn :received (inc (conn :received)))
            (count! :messages-in)
            (run-handler conn handlers :on-message
                         {:type (f :opcode) :data payload}))
          (do
            (set frag-opcode (f :opcode))
            (buffer/push frag payload)))
        nil)))

  (var result nil)
  (while (nil? result)
    (def [ok out]
      (protect
        (let [f (frame/parse buf 0 {:expect-mask true
                                    :max-frame (cfg :max-frame)})]
          (if (nil? f)
            :need-more
            (do
              (consume! buf (f :size))
              (handle-frame f))))))
    (cond
      (not ok)
      (let [code (if (dictionary? out) (get out :ws/close 1002) 1002)
            message (if (dictionary? out) (get out :message "")
                      (string out))]
        (log/debug "websocket protocol error" :ns log-ns
                   :conn (conn :id) :code code :reason message)
        (set result (protocol-close! conn code message)))

      (= :need-more out)
      (let [[read-ok more] (protect (net/read sock 4096 buf))]
        (when (or (not read-ok) (nil? more))
          (set result
               {:code 1006 :name :abnormal
                :reason (if (= :closing (conn :state))
                          "peer went away after the close frame"
                          "peer went away")})))

      (dictionary? out)
      (set result out)))
  (finish! conn result handlers))
