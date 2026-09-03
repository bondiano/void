### void/ws/handshake — the RFC 6455 §4 opening handshake.
###
### A websocket connection begins as an ordinary GET, and in void it
### *stays* an ordinary GET for as long as possible: it is routed,
### middleware runs on it, the session is loaded, `void/auth` and
### `void/authz` have already decided who is asking and whether they
### may. Only then does this module look at the four headers that make
### the request an upgrade and produce either the 101 or the refusal.
###
### That ordering is the whole design: a websocket route is a route.
### Nothing here knows about extension points, and none of the plugins
### that protect an HTTP route needed a second implementation for sockets.
###
### The refusals are deliberately HTTP responses rather than close
### frames — at this point no connection has been upgraded, so the peer
### is still a client reading a status line, and 400/426 is what it can
### act on.

(import spork/base64)
(import void/http/ring :as ring)
(import ./sha1 :as sha1)

(def guid
  ``The magic string of RFC 6455 §1.3. It is printed in the
  specification, which is the clearest statement possible that the
  accept value is not a secret — see ./sha1 on why this package hashes
  it itself.``
  "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")

(def version
  "The only protocol version RFC 6455 defines."
  "13")

(defn accept-key
  "The `Sec-WebSocket-Accept` value for a client's `Sec-WebSocket-Key`
  (step 5): base64(sha1(key + guid))."
  [key]
  (base64/encode (sha1/digest (string key guid))))

(defn- header-tokens
  "A comma-separated header value as lowercase trimmed tokens."
  [value]
  (if (nil? value)
    []
    (map |(string/ascii-lower (string/trim $)) (string/split "," (string value)))))

(defn- has-token? [req name token]
  (def v (get-in req [:headers name]))
  (def values (if (indexed? v) v [v]))
  (some |(index-of token (header-tokens $)) values))

(defn valid-key?
  ``Is this a `Sec-WebSocket-Key`? §4.1 says 16 random bytes,
  base64-encoded — so 24 characters that decode to 16 bytes. A server
  that skips the check answers a nonce it never read.``
  [key]
  (and (string? key)
       (= 24 (length key))
       (let [[ok raw] (protect (base64/decode key))]
         (and ok (= 16 (length raw))))))

(defn requested-protocols
  "The subprotocols the client offered (`Sec-WebSocket-Protocol`), in
  its order of preference."
  [req]
  (def v (get-in req [:headers "sec-websocket-protocol"]))
  (def values (if (indexed? v) v (if (nil? v) [] [v])))
  (filter |(not (empty? $)) (mapcat header-tokens values)))

(defn negotiate-protocol
  ``Pick a subprotocol: the first one the *server* offers that the
  client also named — the server's preference wins, which is the
  choice §4.2.2 leaves to it.

  Returns nil when no header goes back at all: either side may be
  silent about subprotocols, and a client that names none is asking
  for the route's plain protocol rather than making a demand. `:none`
  — a refusal — is only for the case where both sides named some and
  the lists do not meet, because there the client asked for something
  specific and would otherwise be handed a socket it cannot read.``
  [req offered]
  (if (or (nil? offered) (empty? offered))
    nil
    (let [wanted (requested-protocols req)]
      (if (empty? wanted)
        nil
        (or (find |(index-of (string/ascii-lower (string $)) wanted) offered)
            :none)))))

(defn check
  ``Read the upgrade request. Returns `{:key ... :protocol ...}` when
  it is one, or a response table to send back when it is not:

    405  the route was reached with something other than GET
    426  no upgrade headers, or a version other than 13 — the answer
         carries `Sec-WebSocket-Version: 13`, which is how §4.4 says a
         server tells a client which version to come back with
    400  upgrade headers that contradict themselves (no key, a key
         that is not 16 base64 bytes, a subprotocol list with nothing
         in it this server speaks)``
  [req &opt protocols]
  (cond
    (not= :get (req :method))
    (ring/text 405 "405 Method Not Allowed — a websocket handshake is a GET")

    (not (has-token? req "upgrade" "websocket"))
    (ring/response 426 "426 Upgrade Required — this route speaks WebSocket"
                   @{"content-type" "text/plain; charset=utf-8"
                     "upgrade" "websocket"
                     "connection" "Upgrade"
                     "sec-websocket-version" version})

    (not (has-token? req "connection" "upgrade"))
    (ring/text 400 "400 Bad Request — Upgrade: websocket without Connection: Upgrade")

    (not= version (string (get-in req [:headers "sec-websocket-version"] "")))
    (ring/response 426 "426 Upgrade Required — only WebSocket version 13"
                   @{"content-type" "text/plain; charset=utf-8"
                     "sec-websocket-version" version})

    (do
      (def key (get-in req [:headers "sec-websocket-key"]))
      (def key1 (if (indexed? key) (first key) key))
      (cond
        (not (valid-key? key1))
        (ring/text 400 "400 Bad Request — Sec-WebSocket-Key must be 16 bytes, base64")

        (do
          (def protocol (negotiate-protocol req protocols))
          (if (= :none protocol)
            (ring/text 400
                       (string/format "400 Bad Request — no shared subprotocol (this route speaks %s)"
                                      (string/join (map string protocols) ", ")))
            {:key key1 :protocol protocol}))))))

(defn response-headers
  "The 101 headers for an accepted handshake."
  [key &opt protocol]
  (def h @{"upgrade" "websocket"
           "connection" "Upgrade"
           "sec-websocket-accept" (accept-key key)})
  (when protocol
    (put h "sec-websocket-protocol" (string protocol)))
  h)

# -- the client side of the same handshake -------------------------------

(defn client-key
  "A fresh `Sec-WebSocket-Key`: 16 random bytes, base64. The randomness
  is `os/cryptorand`, which Janet has built in — see ./sha1 on why this
  package needs nothing else."
  []
  (base64/encode (string (os/cryptorand 16))))

(defn check-response
  ``Validate a server's handshake answer against the key that was
  sent. Returns nil when it is good, an error string when it is not —
  a client that skips this will happily talk frames to something that
  never agreed to speak them.``
  [head key]
  (def headers (get head :headers {}))
  (defn one [name]
    (def v (get headers name))
    (if (indexed? v) (first v) v))
  (cond
    (not= 101 (head :status))
    (string/format "expected 101 Switching Protocols, got %d %s"
                   (head :status) (get head :message ""))
    (not= "websocket" (string/ascii-lower (or (one "upgrade") "")))
    "the server did not answer Upgrade: websocket"
    (not (index-of "upgrade" (header-tokens (one "connection"))))
    "the server did not answer Connection: Upgrade"
    (not= (accept-key key) (one "sec-websocket-accept"))
    "Sec-WebSocket-Accept does not match the key that was sent"
    (one "sec-websocket-extensions")
    (string/format "the server negotiated an extension nobody offered: %s"
                   (one "sec-websocket-extensions"))
    nil))
