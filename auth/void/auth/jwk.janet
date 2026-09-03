### void/auth/jwk — JSON Web Keys as the PEM libcrypto will open
### (RFC 7517/7518).
###
### An authorization server publishes its public keys as JWKS: JSON with
### base64url integers in it. `void/crypto/sign` opens keys from PEM,
### because that is what `PEM_read_bio_PUBKEY` takes (every primitive
### comes from libcrypto, and none of them is reimplemented here). The gap
### between the two is an encoding, and this module is that encoding and
### nothing else: a JWK in, a `-----BEGIN PUBLIC KEY-----` block out.
###
### **It is DER writing, not cryptography.** SubjectPublicKeyInfo is
### four nested TLVs, the OIDs are constants out of the RFCs, and the
### one rule worth stating twice is DER's integer rule: content is
### minimal two's complement, so a leading zero byte is *added* when
### the top bit is set and leading zeroes are *stripped* otherwise.
### Getting that wrong is the classic interop bug (`void/crypto/sign`
### has the same note about ECDSA signatures, for the same reason).
###
### The suite checks the output against PEM files OpenSSL wrote for
### the same keys, byte for byte. That is the only test worth having
### here: an encoder that agrees with itself proves nothing.

(import spork/base64)
(import void/crypto/encode :as encode)

# -- DER -----------------------------------------------------------------

(defn- der-len [n]
  (if (< n 128)
    (string/from-bytes n)
    (do
      (def bytes @[])
      (var v n)
      (while (pos? v)
        (array/insert bytes 0 (band v 0xff))
        (set v (brshift v 8)))
      (string/from-bytes (bor 0x80 (length bytes)) ;bytes))))

(defn- tlv [tag content]
  (string (string/from-bytes tag) (der-len (length content)) content))

(defn- der-integer
  ``A DER INTEGER from an unsigned big-endian number: leading zeroes
  dropped, one added back when the top bit is set (the value is
  positive and DER integers are signed).``
  [bytes]
  (var i 0)
  (def b (string bytes))
  (while (and (< i (dec (length b))) (zero? (in b i))) (++ i))
  (def trimmed (string/slice b i))
  (tlv 0x02 (if (>= (in trimmed 0) 0x80)
              (string "\0" trimmed)
              trimmed)))

(defn- der-sequence [& parts] (tlv 0x30 (string ;parts)))
(defn- der-oid [content] (tlv 0x06 content))
(defn- der-null [] "\x05\0")
(defn- der-bitstring [content] (tlv 0x03 (string "\0" content)))

(def- oid-rsa
  "1.2.840.113549.1.1.1 — rsaEncryption."
  "\x2a\x86\x48\x86\xf7\x0d\x01\x01\x01")

(def- oid-ec
  "1.2.840.10045.2.1 — id-ecPublicKey."
  "\x2a\x86\x48\xce\x3d\x02\x01")

(def- curves
  ``The P-curves JWS uses: the named-curve OID, the width each
  coordinate is padded to, and the JWS algorithm the curve implies
  (RFC 7518 §3.1 — a key on P-256 signs ES256 and nothing else).``
  {"P-256" {:oid "\x2a\x86\x48\xce\x3d\x03\x01\x07" :width 32 :alg :es256}
   "P-384" {:oid "\x2b\x81\x04\x00\x22" :width 48 :alg :es384}
   "P-521" {:oid "\x2b\x81\x04\x00\x23" :width 66 :alg :es521}})

# -- PEM -----------------------------------------------------------------

(defn- pem [der]
  # spork's encoder rather than `crypto/encode/base64`: that one drops
  # padding on purpose (PHC strings say so), and PEM is the other
  # convention — RFC 7468 wants the `=` and OpenSSL writes it
  (def b64 (base64/encode (string der)))
  (def lines @[])
  (var i 0)
  (while (< i (length b64))
    (array/push lines (string/slice b64 i (min (length b64) (+ i 64))))
    (+= i 64))
  (string "-----BEGIN PUBLIC KEY-----\n"
          (string/join lines "\n")
          "\n-----END PUBLIC KEY-----\n"))

(defn- decode-part [jwk key]
  (def v (get jwk key))
  (unless (bytes? v)
    (errorf "JWK is missing %q (or it is not a string)" key))
  (def [ok bytes] (protect (encode/base64url-decode v)))
  (unless ok (errorf "JWK %q is not base64url" key))
  (string bytes))

(defn- pad-left [bytes width]
  (def b (string bytes))
  (cond
    (= (length b) width) b
    (< (length b) width) (string (string/repeat "\0" (- width (length b))) b)
    # a coordinate wider than its curve is not a coordinate
    (errorf "coordinate is %d bytes, wider than the %d this curve has"
            (length b) width)))

# -- the two key types ---------------------------------------------------

(defn algorithm
  ``The JWS algorithm this key can verify: its own `alg` when it
  declares one, otherwise the one its type implies — RSA keys default
  to RS256, EC keys are decided by their curve. nil when the key is
  not one this build can use.``
  [jwk]
  (def declared (get jwk :alg))
  (cond
    declared (let [k (keyword (string/ascii-lower (string declared)))]
               (when (index-of k [:rs256 :rs384 :rs512 :es256 :es384 :es512]) k))
    (= "RSA" (get jwk :kty)) :rs256
    (= "EC" (get jwk :kty)) (get-in curves [(string (get jwk :crv "")) :alg])
    nil))

(defn public-pem
  ``One JWK as a PEM public key, ready for `crypto/sign/public-key`.
  RSA keys (`n`, `e`) and EC keys on the P-curves (`crv`, `x`, `y`);
  anything else is an error naming what was asked for, because a
  silently skipped key is a token that fails to verify for no visible
  reason.``
  [jwk]
  (def kty (string (get jwk :kty "")))
  (case kty
    "RSA"
    (pem (der-sequence
           (der-sequence (der-oid oid-rsa) (der-null))
           (der-bitstring
             (der-sequence (der-integer (decode-part jwk :n))
                           (der-integer (decode-part jwk :e))))))

    "EC"
    (let [crv (string (get jwk :crv ""))
          spec (or (get curves crv)
                   (errorf "unsupported JWK curve %q (have %s)" crv
                           (string/join (sorted (keys curves)) " ")))]
      (pem (der-sequence
             (der-sequence (der-oid oid-ec) (der-oid (spec :oid)))
             (der-bitstring
               (string "\x04"
                       (pad-left (decode-part jwk :x) (spec :width))
                       (pad-left (decode-part jwk :y) (spec :width)))))))

    (errorf "unsupported JWK key type %q — this build verifies RSA and EC keys"
            kty)))

(defn signing-keys
  ``The usable verification keys of a JWKS document, as
  `[{:kid :alg :pem :jwk} ...]`.

  Keys meant for encryption are left out (`use` "enc", or `key_ops`
  without "verify"), and so is anything whose type or curve this build
  cannot open — a key set from a real authorization server carries
  keys for things this resource server does not do, and refusing the
  whole document because one of them is an X25519 key would be a
  resource server that stops working when its issuer adds an
  algorithm.``
  [jwks]
  (def out @[])
  (each jwk (get jwks :keys [])
    (when (dictionary? jwk)
      (def ops (get jwk :key_ops))
      (def usable?
        (and (not= "enc" (get jwk :use))
             (or (nil? ops) (and (indexed? ops) (index-of "verify" ops)))))
      (when usable?
        (def alg (algorithm jwk))
        (def [ok text] (if alg (protect (public-pem jwk)) [false nil]))
        (when (and alg ok)
          (array/push out {:kid (when-let [k (get jwk :kid)] (string k))
                           :alg alg
                           :pem text
                           :jwk jwk})))))
  (tuple ;out))
