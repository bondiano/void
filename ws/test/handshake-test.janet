(import ../test-support/paths)
(import void/ws/handshake :as handshake)
(import void/ws/sha1 :as sha1)

# -- sha1, against the vectors that define it ---------------------------

(defn- hex [s] (string/join (seq [b :in s] (string/format "%02x" b))))

(each [input want]
  [["" "da39a3ee5e6b4b0d3255bfef95601890afd80709"]
   ["abc" "a9993e364706816aba3e25717850c26c9cd0d89d"]
   ["abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
    "84983e441c3bd26ebaae4aa1f95129e5e54670f1"]
   [(string/repeat "a" 1000000) "34aa973cd4c4daa4f61eeb2bdbad27316534016f"]]
  (assert (= want (hex (sha1/digest input)))
          (string/format "sha1 of %d bytes matches the published vector"
                         (length input))))

# -- the accept value the RFC prints (§1.3) ------------------------------

(assert (= "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
           (handshake/accept-key "dGhlIHNhbXBsZSBub25jZQ=="))
        "the §1.3 worked example produces the §1.3 accept value")

# -- reading an upgrade request ------------------------------------------

(def key (handshake/client-key))
(assert (handshake/valid-key? key) "a minted key is 16 base64 bytes")
(each bad ["" "short" (string key "x") "!!!!!!!!!!!!!!!!!!!!!!!="]
  (assert (not (handshake/valid-key? bad))
          (string/format "%q is not a Sec-WebSocket-Key" bad)))

(defn- request [&opt headers method]
  @{:method (or method :get)
    :path "/live"
    :headers (merge @{"upgrade" "websocket"
                      "connection" "Upgrade"
                      "sec-websocket-version" "13"
                      "sec-websocket-key" key}
                    (or headers @{}))})

(def ok (handshake/check (request)))
(assert (= key (ok :key)) "a well-formed handshake reads back its key")
(assert (nil? (ok :protocol)) "and offers no subprotocol when nobody asked")

(assert (= 405 ((handshake/check (request nil :post)) :status))
        "a handshake is a GET")
(assert (= 426 ((handshake/check (request @{"upgrade" "h2c"})) :status))
        "an upgrade to something else is 426")
(assert (= "13" (get-in (handshake/check (request @{"upgrade" "h2c"}))
                        [:headers "sec-websocket-version"]))
        "and the 426 says which version to come back with")
(assert (= 400 ((handshake/check (request @{"connection" "keep-alive"})) :status))
        "Upgrade without Connection: Upgrade is a contradiction")
(assert (= 426 ((handshake/check (request @{"sec-websocket-version" "8"})) :status))
        "version 8 (hybi-08) is not version 13")
(assert (= 400 ((handshake/check (request @{"sec-websocket-key" "nope"})) :status))
        "a key that is not 16 bytes is a bad request")

# a header list is case-insensitive and comma-separated: browsers send
# "Connection: keep-alive, Upgrade" through some proxies
(assert (get (handshake/check (request @{"connection" "keep-alive, Upgrade"})) :key)
        "Connection carrying more than one token still counts")

# -- subprotocols --------------------------------------------------------

(def offered ["chat.v2" "chat.v1"])
(assert (nil? (handshake/negotiate-protocol (request) offered))
        "a client that names none gets none")
(assert (= "chat.v2"
           (handshake/negotiate-protocol
             (request @{"sec-websocket-protocol" "chat.v1, chat.v2"}) offered))
        "the server's preference decides, not the order the client asked in")
(assert (= :none
           (handshake/negotiate-protocol
             (request @{"sec-websocket-protocol" "mqtt"}) offered))
        "no overlap is a refusal, not a silent connection")
(assert (= 400 ((handshake/check (request @{"sec-websocket-protocol" "mqtt"}) offered)
                :status))
        "and the refusal is a 400 naming what this route speaks")

(def hs (handshake/response-headers key "chat.v2"))
(assert (= "websocket" (hs "upgrade")))
(assert (= (handshake/accept-key key) (hs "sec-websocket-accept")))
(assert (= "chat.v2" (hs "sec-websocket-protocol")))
(assert (nil? ((handshake/response-headers key) "sec-websocket-protocol"))
        "no subprotocol means no header at all")

# -- the client's side of the same check ---------------------------------

(defn- answer [&opt over status]
  @{:status (or status 101)
    :message "Switching Protocols"
    :headers (merge @{"upgrade" "websocket"
                      "connection" "Upgrade"
                      "sec-websocket-accept" (handshake/accept-key key)}
                    (or over @{}))})

(assert (nil? (handshake/check-response (answer) key))
        "a correct answer passes")
(assert (handshake/check-response (answer nil 200) key)
        "anything but 101 is refused")
(assert (handshake/check-response (answer @{"sec-websocket-accept" "wrong"}) key)
        "an accept value that does not match the key is refused")
(assert (handshake/check-response
          (answer @{"sec-websocket-extensions" "permessage-deflate"}) key)
        "and so is an extension nobody offered — void negotiates none")

(print "handshake ok")
