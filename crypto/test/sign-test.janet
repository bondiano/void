(import ../test-support/paths)
(import ../test-support/keys)
(import void/crypto/lib :as lib)
(import void/crypto/sign :as sign)

(lib/load!)

(def payload "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ1c2VyOjQyIn0")

# -- RSA -----------------------------------------------------------------

(def rsa-priv (sign/private-key keys/rsa-private))
(def rsa-pub (sign/public-key keys/rsa-public))
(assert (= :rsa (rsa-priv :kind)))

(each algo [:rs256 :rs384 :rs512]
  (def sig (sign/sign rsa-priv algo payload))
  (assert (= 256 (length sig)) "PKCS#1 v1.5 over a 2048-bit key is 256 bytes")
  (assert (sign/verify rsa-pub algo payload sig) (string/format "%q round trip" algo))
  (assert (not (sign/verify rsa-pub algo (string payload "x") sig))
          "a changed payload does not verify")
  (assert (not (sign/verify rsa-pub algo payload (string (string/slice sig 0 255) "\x00")))
          "a changed signature does not verify"))

(assert (not (sign/verify rsa-pub :rs384 payload (sign/sign rsa-priv :rs256 payload)))
        "and a signature made with another digest does not verify — this is the check that stops alg substitution")

# -- ECDSA ---------------------------------------------------------------

(def ec-priv (sign/private-key keys/ec-private))
(def ec-pub (sign/public-key keys/ec-public))
(assert (= :ec (ec-priv :kind)))

# ECDSA is randomised, so one round trip proves little: the DER->raw
# conversion has to handle a coordinate with its top bit set (DER adds a
# leading zero) and one with leading zeroes (DER drops them). Fifty
# signatures reach both branches, and every one of them must be exactly
# 64 bytes — a 63-byte "signature" is the classic JWS interop bug.
(var widths @{})
(for i 0 50
  (def data (string payload i))
  (def sig (sign/sign ec-priv :es256 data))
  (put widths (length sig) true)
  (assert (sign/verify ec-pub :es256 data sig)
          (string/format "ES256 round trip %d" i)))
(assert (deep= @{64 true} widths)
        (string/format "every ES256 signature is r||s of 32 bytes each, got widths %q" (keys widths)))

(assert (not (sign/verify ec-pub :es256 "other payload" (sign/sign ec-priv :es256 payload))))
(assert (not (sign/verify ec-pub :es256 payload (string/repeat "\x00" 64)))
        "an all-zero signature is false, not an error")
(assert (not (sign/verify ec-pub :es256 payload "short"))
        "and so is a signature of the wrong length — a malformed token is just an invalid one")
(assert (not (sign/verify ec-pub :es256 payload (string/repeat "\xff" 64))))

# -- keys and algorithms have to match ------------------------------------

(def [ok err] (protect (sign/sign rsa-priv :es256 payload)))
(assert (not ok) "an RSA key cannot make an ECDSA signature")
(assert (string/find "EC key" (string err)))

(def [ok2 err2] (protect (sign/sign ec-priv :rs256 payload)))
(assert (not ok2))
(assert (string/find "RSA" (string err2)))

(def [ok3] (protect (sign/sign rsa-priv :hs256 payload)))
(assert (not ok3) "HS256 is not a signature — it is an HMAC, and it lives in ./digest")

# -- what is not a key ---------------------------------------------------

(each [pem what]
  [["not a pem at all" "text"]
   ["-----BEGIN PUBLIC KEY-----\nbm90IGEga2V5\n-----END PUBLIC KEY-----" "a PEM with rubbish inside"]
   [keys/rsa-private "a private key where a public one is expected"]]
  (def [ok] (protect (sign/public-key pem)))
  (assert (not ok) (string what " is not a public key")))

(sign/free-key rsa-priv)
(sign/free-key rsa-pub)
(sign/free-key ec-priv)
(sign/free-key ec-pub)
(assert (nil? (sign/free-key nil)) "freeing nothing is not an error")

(print "sign-test ok")
