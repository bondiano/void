### void/ws/client — the other end of the same framing (ADR-0028).
###
### The server side of this package is callback-shaped because a
### server holds thousands of connections and none of them may block
### another. A client holds one, and what a client's caller wants is a
### **pull**: send this, now read the next message. So `receive` is a
### blocking call rather than a handler registration, and the whole
### client is a socket, a buffer and the frame codec read in the
### opposite direction — the same relationship `void/http/client` has
### with `void/http/server` (ADR-0027).
###
### It exists for the two callers that would otherwise have to fake
### one: this package's own suite, which cannot test a protocol
### against itself without a peer that speaks it, and the B4 load
### generator (§8.2: a thousand connections, 10k messages a second),
### which is a thousand of these in one process.
###
### **Client frames are masked, and the key is real randomness**
### (`os/cryptorand`, RFC 6455 §5.3). Masking is not encryption and the
### key travels next to the payload; it exists so an intermediary
### cannot be talked into seeing a request inside a message body. A
### client that masked with a constant would satisfy the letter of the
### framing and none of its purpose.
###
### No TLS (ADR-0010): `wss://` is an error at URL-parse time naming
### the relay that terminates it, the same answer `void/http/client`
### gives `https://`.

(import void/http/client :as http-client)
(import void/http/wire :as wire)
(import ./frame :as frame)
(import ./handshake :as handshake)

(def defaults
  ``Client defaults. `:timeout` bounds one `receive`, not the
  connection: a socket that carries a message an hour from now is
  working exactly as intended, and only the caller knows how long it
  is willing to wait for the next one.``
  {:timeout 10
   :connect-timeout 5
   :max-frame 1048576
   :max-message 8388608})

(defn parse-url
  ``Split a `ws://` URL the way `void/http/client` splits an `http://`
  one — same parser, because they are the same authority grammar.
  `http://` is accepted as a spelling of the same thing (an upgrade
  request *is* an HTTP request); `wss://` and `https://` are refused
  with the deployment shape that replaces them.``
  [url]
  (def s (string url))
  (def sep (or (string/find "://" s)
               (errorf "ws client: %s is not an absolute URL (want ws://host[:port]/path)" s)))
  (def scheme (string/ascii-lower (string/slice s 0 sep)))
  (def rest (string/slice s (+ sep 3)))
  (cond
    (or (= "wss" scheme) (= "https" scheme))
    (errorf (string "ws client: %s — void speaks no TLS (ADR-0010). "
                    "wss:// terminates at the relay, sidecar or proxy in front "
                    "of the process; point this at it over ws://") s)

    (or (= "ws" scheme) (= "http" scheme))
    (http-client/parse-url (string "http://" rest))

    (errorf "ws client: unsupported scheme %s:// (ws:// or http://)" scheme)))

# -- the handshake -------------------------------------------------------

(defn- read-head [sock buf timeout]
  (var head nil)
  (while (nil? head)
    (if-let [end (wire/head-end buf)]
      (do
        (set head (wire/parse-response-head buf))
        (when (= :error head) (error "ws client: malformed handshake response")))
      (let [more (net/read sock 4096 buf timeout)]
        (when (nil? more)
          (error "ws client: the server closed the connection during the handshake")))))
  head)

(defn connect
  ``Open a websocket to `url`. Options:
    :headers    extra request headers (a cookie, an Authorization)
    :protocols  subprotocols to offer, best first
    :timeout :connect-timeout :max-frame :max-message

  Returns the client. Throws when the server refuses the upgrade, with
  the status it refused with — a 401 or a 403 on a socket route is the
  authorization answer of a normal request, and it should read like
  one.``
  [url &opt opts]
  (default opts {})
  (def cfg (merge defaults opts))
  (def parts (parse-url url))
  (def key (handshake/client-key))
  (def sock (net/connect (parts :host) (string (parts :port))))
  (def headers
    (merge @{"host" (string (parts :host) ":" (parts :port))
             "upgrade" "websocket"
             "connection" "Upgrade"
             "sec-websocket-key" key
             "sec-websocket-version" handshake/version}
           (or (get opts :headers) {})))
  (when-let [ps (get opts :protocols)]
    (unless (empty? ps)
      (put headers "sec-websocket-protocol"
           (string/join (map string ps) ", "))))
  (def head-buf @"")
  (buffer/format head-buf "GET %s HTTP/1.1\r\n" (parts :target))
  (eachp [k v] headers
    (buffer/format head-buf "%V: %V\r\n" k v))
  (buffer/push head-buf "\r\n")
  (def [ok err] (protect (:write sock head-buf)))
  (unless ok
    (protect (:close sock))
    (errorf "ws client: could not send the handshake to %s: %s" url (string err)))
  (def buf @"")
  (def [head-ok head] (protect (read-head sock buf (cfg :connect-timeout))))
  (unless head-ok
    (protect (:close sock))
    (error head))
  (when-let [problem (handshake/check-response head key)]
    (protect (:close sock))
    (errorf "ws client: %s refused the upgrade — %s" url problem))
  # bytes past the head are frames: a server may send its first one in
  # the same packet as the 101, and dropping them would lose a message
  (def leftover (string/slice buf (head :head-size)))
  (buffer/clear buf)
  (buffer/push buf leftover)
  @{:socket sock
   :buffer buf
   :url url
   :config cfg
   :state :open
   :protocol (let [p (get-in head [:headers "sec-websocket-protocol"])]
               (if (indexed? p) (first p) p))
   :sent 0
   :received 0})

# -- sending -------------------------------------------------------------

(defn- write-frame [client opcode &opt payload]
  (unless (= :closed (client :state))
    (:write (client :socket)
            (frame/encode opcode payload {:mask (os/cryptorand 4)}))
    true))

(defn send!
  "Send a text message."
  [client text]
  (put client :sent (inc (client :sent)))
  (write-frame client :text (string text)))

(defn send-binary!
  "Send a binary message."
  [client bytes]
  (put client :sent (inc (client :sent)))
  (write-frame client :binary bytes))

(defn ping!
  "Send a ping."
  [client &opt payload]
  (write-frame client :ping payload))

(defn pong!
  "Send an unsolicited pong."
  [client &opt payload]
  (write-frame client :pong payload))

# -- receiving -----------------------------------------------------------

(defn- consume! [buf n]
  (if (>= n (length buf))
    (buffer/clear buf)
    (let [rest (string/slice buf n)]
      (buffer/clear buf)
      (buffer/push buf rest))))

(defn receive
  ``Read the next message. Returns

      {:type :text|:binary :data <string>}   an application message
      {:type :close :code :name :reason}     the peer closed
      nil                                    the socket died, or the
                                             timeout expired

  Ping frames are answered with a pong here, in the caller's fiber:
  a client with no fiber of its own still has to be a well-behaved
  peer, and a pong is one write. `timeout` defaults to the client's
  `:timeout`; nil waits as long as the peer is willing to be silent.``
  [client &opt timeout]
  (default timeout (get-in client [:config :timeout]))
  (def sock (client :socket))
  (def buf (client :buffer))
  (def cfg (client :config))
  (def frag @"")
  (var frag-opcode nil)
  (var out nil)
  (while (nil? out)
    (def f (frame/parse buf 0 {:expect-mask false :max-frame (cfg :max-frame)}))
    (if (nil? f)
      (let [[ok more] (protect (net/read sock 4096 buf timeout))]
        (when (or (not ok) (nil? more))
          (put client :state :closed)
          (set out :gone)))
      (do
        (consume! buf (f :size))
        (case (f :opcode)
          :ping (write-frame client :pong (f :payload))
          :pong nil
          :close
          (let [ci (frame/parse-close (f :payload))]
            (when (= :open (client :state))
              (put client :state :closing)
              (write-frame client :close
                           (if (= 1005 (ci :code)) "" (frame/close-payload (ci :code)))))
            (put client :state :closed)
            (protect (:close sock))
            (set out (merge {:type :close} ci)))

          :continuation
          (do
            (unless frag-opcode
              (error "ws client: a continuation frame with nothing to continue"))
            (buffer/push frag (f :payload))
            (when (> (length frag) (cfg :max-message))
              (error "ws client: the server sent a message over :max-message"))
            (when (f :fin)
              (put client :received (inc (client :received)))
              (set out {:type frag-opcode :data (string frag)})))

          (if (f :fin)
            (do
              (put client :received (inc (client :received)))
              (set out {:type (f :opcode) :data (f :payload)}))
            (do
              (set frag-opcode (f :opcode))
              (buffer/push frag (f :payload))))))))
  (unless (= :gone out) out))

(defn close!
  ``Close the connection: send a close frame, wait for the peer's
  answer (up to `timeout`) and drop the socket. Idempotent.``
  [client &opt code reason timeout]
  (default timeout 2)
  (when (= :open (client :state))
    (put client :state :closing)
    (protect (write-frame client :close
                          (frame/close-payload (or code :normal) reason)))
    # drain until the peer's close comes back or the wait runs out;
    # whatever else arrives in the meantime is dropped, which is what
    # RFC 6455 §7.1.7 says a closing endpoint may do
    (protect (ev/with-deadline timeout
                               (while (and (not= :closed (client :state))
                                           (receive client timeout))))))
  (put client :state :closed)
  (protect (:close (client :socket)))
  client)

(defn open?
  [client]
  (not= :closed (client :state)))
