### void/ws/sha1 — SHA-1, for the one thing RFC 6455 uses it for
### (ADR-0028).
###
### **This is not cryptography, and void has not started writing its
### own.** ADR-0022 says every cryptographic primitive comes from the
### system libcrypto, and that rule stands. The handshake hash of RFC
### 6455 §4.2.2 is outside it: the input is a header the client just
### sent in the clear, the salt is a GUID printed in the specification,
### and the output proves exactly one thing — that whatever answered
### read the request and understood it was a WebSocket handshake. It
### defends a cache, not a secret; the RFC says as much itself.
###
### The alternative was an edge from void/ws to void/crypto, which
### would make every websocket application require OpenSSL on the
### machine and a started component to hash twenty bytes at connect
### time. That is a real dependency bought with a fake need.
###
### Nothing else in void may call this. A second caller would be one
### that wants a *hash*, and hashes live in void/crypto/digest with the
### rest of them.
###
### Janet's bitwise operators take **signed** 32-bit integers
### (`brushift` is the one exception and takes unsigned), so the state
### words here are signed int32 throughout: `s32` folds the
### specification's hex constants into that range at load time so they
### stay readable, `lshr` is the logical right shift the language does
### not offer for a negative word, and `wrap32` brings a sum back.

(defn- s32
  "A 32-bit constant as the signed integer Janet's bit operators take."
  [n]
  (if (>= n 0x80000000) (- n 0x100000000) n))

(defn- wrap32
  "A sum back into signed 32-bit."
  [n]
  (def m (mod n 0x100000000))
  (if (>= m 0x80000000) (- m 0x100000000) m))

(defn- lshr
  ``Logical right shift of a signed 32-bit word: `brshift` sign-extends
  and `brushift` refuses a negative, so the sign bits are masked off
  afterwards.``
  [x n]
  (if (zero? n) x (band (brshift x n) (dec (blshift 1 (- 32 n))))))

(defn- rotl [x n]
  (bor (blshift x n) (lshr x (- 32 n))))

(defn- u32 [bytes i]
  (bor (blshift (get bytes i) 24)
       (blshift (get bytes (+ i 1)) 16)
       (blshift (get bytes (+ i 2)) 8)
       (get bytes (+ i 3))))

(defn- pad
  ``The RFC 3174 §4 padding: a 0x80 byte, zeros up to 56 mod 64, then
  the original length in bits as a big-endian 64-bit integer.``
  [data]
  (def out (buffer/new (+ (length data) 72)))
  (buffer/push out data)
  (buffer/push-byte out 0x80)
  (while (not= 56 (% (length out) 64))
    (buffer/push-byte out 0))
  (def bits (* 8 (length data)))
  (each shift [56 48 40 32 24 16 8 0]
    (buffer/push-byte out (% (math/floor (/ bits (math/exp2 shift))) 256)))
  out)

(def- k
  "The four round constants (RFC 3174 §5)."
  [(s32 0x5A827999) (s32 0x6ED9EBA1) (s32 0x8F1BBCDC) (s32 0xCA62C1D6)])

(defn digest
  "SHA-1 of bytes, raw (20 bytes)."
  [data]
  (def msg (pad data))
  (var h0 (s32 0x67452301))
  (var h1 (s32 0xEFCDAB89))
  (var h2 (s32 0x98BADCFE))
  (var h3 (s32 0x10325476))
  (var h4 (s32 0xC3D2E1F0))
  (def w (array/new-filled 80 0))
  (loop [chunk :range [0 (length msg) 64]]
    (for i 0 16 (put w i (u32 msg (+ chunk (* 4 i)))))
    (for i 16 80
      (put w i (rotl (bxor (w (- i 3)) (w (- i 8)) (w (- i 14)) (w (- i 16))) 1)))
    (var a h0) (var b h1) (var c h2) (var d h3) (var e h4)
    (for i 0 80
      (def f
        (cond
          (< i 20) (bor (band b c) (band (bnot b) d))
          (< i 40) (bxor b c d)
          (< i 60) (bor (band b c) (band b d) (band c d))
          (bxor b c d)))
      (def tmp (wrap32 (+ (rotl a 5) f e (in k (div i 20)) (w i))))
      (set e d)
      (set d c)
      (set c (rotl b 30))
      (set b a)
      (set a tmp))
    (set h0 (wrap32 (+ h0 a)))
    (set h1 (wrap32 (+ h1 b)))
    (set h2 (wrap32 (+ h2 c)))
    (set h3 (wrap32 (+ h3 d)))
    (set h4 (wrap32 (+ h4 e))))
  (def out (buffer/new 20))
  (each h [h0 h1 h2 h3 h4]
    (each s [24 16 8 0]
      (buffer/push-byte out (band 0xFF (lshr h s)))))
  (string out))
