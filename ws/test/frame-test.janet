(import ../test-support/paths)
(import void/ws/frame :as frame)

# -- the examples in the specification (RFC 6455 §5.7) -------------------

(defn- bytes [& bs] (string/from-bytes ;bs))

(def unmasked-hello (bytes 0x81 0x05 0x48 0x65 0x6c 0x6c 0x6f))
(def masked-hello
  (bytes 0x81 0x85 0x37 0xfa 0x21 0x3d 0x7f 0x9f 0x4d 0x51 0x58))

(def f (frame/parse unmasked-hello 0 {:expect-mask false}))
(assert (= "Hello" (f :payload)) "the unmasked §5.7 example decodes")
(assert (f :fin))
(assert (= :text (f :opcode)))
(assert (= 7 (f :size)))

(def m (frame/parse masked-hello 0 {:expect-mask true}))
(assert (= "Hello" (m :payload)) "and so does the masked one")
(assert (= 11 (m :size)))

(assert (= unmasked-hello (frame/encode :text "Hello"))
        "a server frames Hello exactly as the RFC prints it")
(assert (= masked-hello
           (frame/encode :text "Hello" {:mask (bytes 0x37 0xfa 0x21 0x3d)}))
        "and a client with that key produces the RFC's masked bytes")

# a 256-byte and a 65536-byte binary frame use the two extended length
# forms (0x7E + 2 bytes, 0x7F + 8 bytes)
(def big (frame/encode :binary (string/repeat "x" 256)))
(assert (= 0x7E (in big 1)) "256 bytes take the 16-bit length form")
(assert (= [0x01 0x00] [(in big 2) (in big 3)]))
(def huge (frame/encode :binary (string/repeat "x" 65536)))
(assert (= 0x7F (in huge 1)) "65536 bytes take the 64-bit form")
(assert (= 65536 (length ((frame/parse huge 0 {:expect-mask false}) :payload))))

# -- incompleteness is not an error --------------------------------------

(each n [0 1 2 3 4 6]
  (assert (nil? (frame/parse (string/slice unmasked-hello 0 n) 0 {:expect-mask false}))
          (string/format "%d bytes of a 7-byte frame is not yet a frame" n)))

# a frame followed by the start of the next one reports only its own size
(def two (string unmasked-hello unmasked-hello))
(assert (= 7 ((frame/parse two 0 {:expect-mask false}) :size)))

# -- what the protocol forbids -------------------------------------------

(defn- refused [buf opts]
  (def [ok err] (protect (frame/parse buf 0 (merge {:expect-mask false} opts))))
  (assert (not ok) "the frame is refused")
  (get err :ws/close))

(assert (= 1002 (refused (bytes 0xC1 0x00) {}))
        "a reserved bit with no extension negotiated is a protocol error")
(assert (= 1002 (refused (bytes 0x83 0x00) {}))
        "and so is an opcode that does not exist")
(assert (= 1002 (refused (bytes 0x09 0x00) {}))
        "a fragmented control frame is a protocol error")
(assert (= 1002 (refused (bytes 0x89 0x7E 0x00 0xFF) {}))
        "and a control frame over 125 bytes is one too")
(assert (= 1002 (refused (bytes 0x81 0x7E 0x00 0x05 0x48 0x65 0x6c 0x6c 0x6f) {}))
        "a length that could have been written in 7 bits must be")
(assert (= 1009 (refused (bytes 0x82 0x7E 0x04 0x00) {:max-frame 100}))
        "a frame over :max-frame is refused before its bytes are read")
(assert (= 1002 (refused (bytes 0x82 0x7F 0x80 0 0 0 0 0 0 0) {}))
        "but a 64-bit length with its high bit set is broken framing, not a big frame")
(assert (= 1002 (refused unmasked-hello {:expect-mask true}))
        "a server refuses an unmasked frame from a client")
(assert (= 1002 (refused masked-hello {:expect-mask false}))
        "and a client refuses a masked frame from a server")

# -- close payloads ------------------------------------------------------

(assert (= "" (frame/close-payload)) "a close with no code has an empty payload")
(def cp (frame/close-payload :normal "bye"))
(assert (= [0x03 0xE8] [(in cp 0) (in cp 1)]) "1000 goes out big-endian")
(assert (= {:code 1000 :name :normal :reason "bye"} (frame/parse-close cp)))
(assert (= 1005 ((frame/parse-close "") :code))
        "an empty close payload reports as 1005, the code nobody sent")

(each code [:no-status :abnormal :tls-handshake 999 1004 1016]
  (def [ok] (protect (frame/close-payload code)))
  (assert (not ok) (string/format "%q may not be sent (RFC 6455 §7.4.1)" code)))
(assert (frame/close-payload 4000) "the private range 3000-4999 may be")

(def [ok err] (protect (frame/parse-close (bytes 0x03 0xEE))))
(assert (and (not ok) (= 1002 (err :ws/close)))
        "a peer that sends 1006 is telling us something no peer may say")

(def [ok2 err2] (protect (frame/parse-close (string (bytes 0x03 0xE8) "\xff"))))
(assert (and (not ok2) (= 1007 (err2 :ws/close)))
        "and a close reason that is not UTF-8 is a 1007")

# -- utf-8 ---------------------------------------------------------------

(each good ["" "hello" "привет" "κόσμε" "\xF0\x9F\x92\xA9"
            "\xC2\x80" "\xE0\xA0\x80" "\xF4\x8F\xBF\xBF"]
  (assert (frame/utf8-valid? good) (string/format "%q is UTF-8" good)))

(each bad ["\xFF" "\xC0\xAF" "\xC1\xBF"          # overlong two-byte forms
           "\xE0\x80\xAF"                        # overlong three-byte
           "\xED\xA0\x80" "\xED\xBF\xBF"         # surrogate halves
           "\xF0\x80\x80\x80"                    # overlong four-byte
           "\xF4\x90\x80\x80"                    # past U+10FFFF
           "\xF5\x80\x80\x80" "\xC2"             # truncated
           "\xE2\x82" "\x80"]
  (assert (not (frame/utf8-valid? bad))
          (string/format "%q is not UTF-8" bad)))

# -- masking is its own inverse ------------------------------------------

(def key (bytes 0xDE 0xAD 0xBE 0xEF))
(def payload (string/repeat "the quick brown fox " 7))
(def buf (buffer payload))
(frame/mask! buf key)
(assert (not= payload (string buf)) "masking changes the bytes")
(frame/mask! buf key)
(assert (= payload (string buf)) "and masking again brings them back")

(print "frame ok")
