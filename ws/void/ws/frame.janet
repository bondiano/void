### void/ws/frame — the RFC 6455 §5 framing layer.
###
### Pure functions over buffers, exactly like `void/http/wire`: parse
### one frame out of a buffer, encode one frame into bytes, and say no
### to the shapes the protocol forbids. No sockets, no state, no
### fibers — the connection loop in ./conn owns all of that, and this
### module is what a test can exercise byte by byte.
###
### **Every refusal here is a close code, not a message.** A frame with
### a reserved bit set, an unknown opcode, a fragmented control frame or
### a text payload that is not UTF-8 are all cases where RFC 6455 §7.4
### names the number the peer must be told, so the error value carries
### it (`{:ws/close 1002 :message ...}`) and the connection loop sends
### precisely that. A protocol error described in prose to a peer that
### only reads numbers is a protocol error twice.
###
### Two rules that look like details and are not:
###
###   * **A client frame must be masked and a server frame must not
###     be**. It is not a security measure between us and the
###     peer — it exists so that a proxy on the path cannot be fooled
###     into seeing a request inside a payload — and both directions
###     of the rule are enforced, because a server that tolerates an
###     unmasked client frame is the hole the rule exists to close.
###   * **Text is UTF-8 or it is a 1007**. The check costs a
###     pass over the payload and it is the only thing standing
###     between "a websocket" and "a byte pipe with an opcode".

(def opcodes
  "Opcode name -> number (RFC 6455 §5.2)."
  {:continuation 0x0
   :text 0x1
   :binary 0x2
   :close 0x8
   :ping 0x9
   :pong 0xA})

(def opcode-names
  "Number -> opcode name."
  (table/to-struct (tabseq [[k v] :pairs opcodes] v k)))

(defn control?
  "Is this a control opcode (close/ping/pong)? Control frames may not
  be fragmented and carry at most 125 bytes."
  [opcode]
  (>= (get opcodes opcode opcode) 0x8))

(def close-codes
  ``The close codes RFC 6455 §7.4.1 defines, by the name void spells
  them with. `:no-status` and `:abnormal` are never *sent* — they are
  what a peer that closed without a code, or a socket that died,
  reports as.``
  {:normal 1000
   :going-away 1001
   :protocol-error 1002
   :unsupported-data 1003
   :no-status 1005
   :abnormal 1006
   :invalid-payload 1007
   :policy-violation 1008
   :too-big 1009
   :extension-required 1010
   :internal-error 1011
   :tls-handshake 1015})

(def close-names
  "Number -> close-code name, for a log line that reads."
  (table/to-struct (tabseq [[k v] :pairs close-codes] v k)))

(defn- refuse [code message]
  (error {:ws/close (get close-codes code code) :message message}))

(defn sendable-close-code?
  ``May this code go out on the wire? 1005/1006/1015 are reserved for
  what a *local* endpoint reports and must never be sent, the range below
  1000 does not exist, and 1016-2999 is unassigned.``
  [code]
  (and (int? code)
       (or (and (>= code 1000) (<= code 1011)
                (not (or (= code 1004) (= code 1005) (= code 1006))))
           (and (>= code 3000) (<= code 4999)))))

# -- utf-8 ---------------------------------------------------------------

(defn utf8-valid?
  ``Is this byte sequence well-formed UTF-8 (RFC 3629)? Strict:
  overlong encodings, surrogate halves and anything past U+10FFFF are
  rejected, because they are exactly what §8.1 asks a websocket
  endpoint to fail on rather than to normalise away.``
  [bytes]
  (def n (length bytes))
  (var i 0)
  (var ok true)
  (while (and ok (< i n))
    (def b (in bytes i))
    (def [len lo hi]
      (cond
        (< b 0x80) [1 0 0]
        (< b 0xC2) [0 0 0]             # continuation byte, or overlong C0/C1
        (< b 0xE0) [2 0x80 0xBF]
        (= b 0xE0) [3 0xA0 0xBF]       # no overlong three-byte forms
        (= b 0xED) [3 0x80 0x9F]       # no surrogates
        (< b 0xF0) [3 0x80 0xBF]
        (= b 0xF0) [4 0x90 0xBF]       # no overlong four-byte forms
        (< b 0xF4) [4 0x80 0xBF]
        (= b 0xF4) [4 0x80 0x8F]       # nothing past U+10FFFF
        [0 0 0]))
    (cond
      (zero? len) (set ok false)
      (> (+ i len) n) (set ok false)
      (do
        (for j 1 len
          (def c (in bytes (+ i j)))
          # the first continuation byte carries the range that rules
          # out overlongs and surrogates; the rest are plain 10xxxxxx
          (def [l h] (if (= j 1) [lo hi] [0x80 0xBF]))
          (when (or (< c l) (> c h)) (set ok false)))
        (+= i len))))
  ok)

# -- masking -------------------------------------------------------------

(defn mask!
  "XOR `buf` in place with a 4-byte key. Its own inverse."
  [buf key]
  (def n (length buf))
  (var i 0)
  (while (< i n)
    (put buf i (bxor (in buf i) (in key (band i 3))))
    (++ i))
  buf)

# -- parsing -------------------------------------------------------------

(defn- be-length [buf start n]
  (var v 0)
  (for i 0 n (set v (+ (* v 256) (in buf (+ start i)))))
  v)

(defn parse
  ``Parse one frame from `buf` at `start`. Returns nil while the frame
  is incomplete, otherwise

      {:fin bool :opcode <keyword> :payload <string> :size <bytes consumed>}

  Options:
    :expect-mask  true on a server (client frames must be masked),
                  false on a client (server frames must not be)
    :max-frame    payload bytes accepted before a 1009

  Throws {:ws/close <code> :message ...} on everything the protocol
  forbids.``
  [buf &opt start opts]
  (default start 0)
  (default opts {})
  (def expect-mask (get opts :expect-mask true))
  (def max-frame (get opts :max-frame math/inf))
  (def avail (- (length buf) start))
  (when (< avail 2) (break nil))
  (def b0 (in buf start))
  (def b1 (in buf (+ start 1)))
  (def fin (not (zero? (band b0 0x80))))
  (unless (zero? (band b0 0x70))
    (refuse :protocol-error "reserved frame bits are set and no extension was negotiated"))
  (def op-num (band b0 0x0F))
  (def opcode
    (or (get opcode-names op-num)
        (refuse :protocol-error (string/format "unknown opcode 0x%x" op-num))))
  (def masked (not (zero? (band b1 0x80))))
  (def len7 (band b1 0x7F))
  (when (and (control? opcode) (not fin))
    (refuse :protocol-error "a control frame may not be fragmented"))
  (when (and (control? opcode) (> len7 125))
    (refuse :protocol-error "a control frame may not carry more than 125 bytes"))
  (def [len-bytes header-len]
    (cond
      (= len7 126) [2 4]
      (= len7 127) [8 10]
      [0 2]))
  (when (< avail header-len) (break nil))
  (def len
    (if (zero? len-bytes)
      len7
      (do
        # §5.2: "the most significant bit MUST be 0" — a peer that sets
        # it is not sending a huge frame, it is sending a broken one
        (when (and (= len-bytes 8) (>= (in buf (+ start 2)) 0x80))
          (refuse :protocol-error
                  "a 64-bit payload length must have its high bit clear"))
        (be-length buf (+ start 2) len-bytes))))
  # a minimal length encoding is required; a peer padding the length field
  # is a peer whose framing must not be trusted
  (when (or (and (= len-bytes 2) (< len 126))
            (and (= len-bytes 8) (< len 65536)))
    (refuse :protocol-error "payload length is not minimally encoded"))
  (when (> len max-frame)
    (refuse :too-big (string/format "frame of %d bytes over the %d-byte limit"
                                    len max-frame)))
  (unless (= masked expect-mask)
    (refuse :protocol-error
            (if expect-mask
              "a frame from a client must be masked"
              "a frame from a server must not be masked")))
  (def total (+ header-len (if masked 4 0) len))
  (when (< avail total) (break nil))
  (def data-start (+ start header-len (if masked 4 0)))
  (def payload (buffer/new len))
  (buffer/push payload (string/slice buf data-start (+ data-start len)))
  (when masked
    (mask! payload (string/slice buf (+ start header-len) (+ start header-len 4))))
  {:fin fin :opcode opcode :payload (string payload) :size total})

# -- encoding ------------------------------------------------------------

(defn encode
  ``One frame as bytes. `opcode` is a keyword from `opcodes`, `payload`
  bytes (nil for none). Options:
    :fin   false for a fragment that continues (default true)
    :mask  a 4-byte key — what a *client* must send; a server
           never masks, so leaving it out is the server's case``
  [opcode payload &opt opts]
  (default opts {})
  (def data (or payload ""))
  (def len (length data))
  (def op (or (get opcodes opcode)
              (errorf "unknown websocket opcode %q (have %s)"
                      opcode
                      (string/join (map |(string/format "%q" $)
                                        (sorted (keys opcodes))) " "))))
  (when (and (control? opcode) (> len 125))
    (errorf "a %q frame carries at most 125 bytes, got %d" opcode len))
  (def key (get opts :mask))
  (when (and key (not= 4 (length key)))
    (errorf "a mask key is 4 bytes, got %d" (length key)))
  (def out (buffer/new (+ len 14)))
  (buffer/push-byte out (bor (if (get opts :fin true) 0x80 0) op))
  (def mask-bit (if key 0x80 0))
  (cond
    (< len 126) (buffer/push-byte out (bor mask-bit len))
    (< len 65536)
    (do (buffer/push-byte out (bor mask-bit 126))
        (buffer/push-byte out (brshift len 8))
        (buffer/push-byte out (band len 0xFF)))
    (do (buffer/push-byte out (bor mask-bit 127))
        (each shift [56 48 40 32 24 16 8 0]
          (buffer/push-byte out (% (math/floor (/ len (math/exp2 shift))) 256)))))
  (if key
    (do
      (buffer/push out key)
      (def body (buffer/new len))
      (buffer/push body data)
      (buffer/push out (mask! body key)))
    (buffer/push out data))
  (string out))

# -- close payloads ------------------------------------------------------

(defn close-payload
  ``The body of a close frame: a big-endian code and an optional UTF-8
  reason. A close with no code at all is an empty payload — legal, and
  what `nil` here means.``
  [&opt code reason]
  (if (nil? code)
    ""
    (do
      (def n (get close-codes code code))
      (unless (sendable-close-code? n)
        (errorf "%q is not a close code that may be sent (RFC 6455 §7.4.1)" code))
      (def out (buffer/new 2))
      (buffer/push-byte out (brshift n 8))
      (buffer/push-byte out (band n 0xFF))
      (when reason
        (when (> (length reason) 123)
          (errorf "a close reason is at most 123 bytes, got %d" (length reason)))
        (buffer/push out reason))
      (string out))))

(defn parse-close
  ``A close frame's payload -> {:code <int> :name <keyword or nil>
  :reason <string>}. An empty payload is 1005 ("no status received"),
  which is a code no one sent — it is what a local endpoint reports.``
  [payload]
  (def n (length payload))
  (cond
    (zero? n) {:code 1005 :name :no-status :reason ""}
    (= 1 n) (refuse :protocol-error "a close payload of one byte is not a close code")
    (do
      (def code (+ (* 256 (in payload 0)) (in payload 1)))
      (def reason (string/slice payload 2))
      (unless (sendable-close-code? code)
        (refuse :protocol-error
                (string/format "%d is not a close code a peer may send" code)))
      (unless (utf8-valid? reason)
        (refuse :invalid-payload "a close reason must be UTF-8"))
      {:code code :name (get close-names code) :reason reason})))
