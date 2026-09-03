### JWK -> PEM: checked against PEM that OpenSSL wrote for the same two
### keys, because an encoder that agrees with itself proves nothing.

(import ../test-support/paths)
(import ../test-support/jwks :as fixture)
# the throwaway key pairs void/crypto's signature suite carries, and
# the JWKs beside them are the same keys: duplicating a PEM fixture in
# two packages is two things to regenerate (see auth/test/jwt-test)
(import ../../crypto/test-support/keys :as keys)
(import void/crypto/encode :as encode)
(import void/auth/jwk :as jwk)

(def usable (jwk/signing-keys fixture/document))
(assert (= 2 (length usable)) "both keys of the set are usable")

(def by-kid (tabseq [k :in usable] (k :kid) k))

# -- the bytes are OpenSSL's ---------------------------------------------

# the fixture is a Janet long-string and so carries no trailing
# newline; everything before it is compared byte for byte
(defn- same-pem? [a b] (= (string/trimr a) (string/trimr b)))

(assert (same-pem? keys/rsa-public ((by-kid "rsa-1") :pem))
        "the RSA JWK encodes to exactly the PEM OpenSSL wrote for that key")
(assert (same-pem? keys/ec-public ((by-kid "ec-1") :pem))
        "and so does the P-256 one")

(assert (= :rs256 ((by-kid "rsa-1") :alg)) "an RSA key declaring RS256 is RS256")
(assert (= :es256 ((by-kid "ec-1") :alg)) "and a P-256 key is ES256")

# -- the algorithm a key implies -----------------------------------------

(assert (= :rs256 (jwk/algorithm {:kty "RSA"})) "an RSA key with no alg verifies RS256")
(assert (= :es384 (jwk/algorithm {:kty "EC" :crv "P-384"}))
        "and the curve decides for EC keys (RFC 7518 §3.1)")
(assert (= :es256 (jwk/algorithm {:kty "EC" :crv "P-256" :alg "ES256"}))
        "a declared alg is taken when it is one this build has")
(assert (nil? (jwk/algorithm {:kty "OKP" :crv "Ed25519"}))
        "and an algorithm it cannot verify is nil rather than a guess")

# -- what is left out of a key set ---------------------------------------

(def mixed
  {:keys [(first fixture/keys)
          # an encryption key in a signing set is normal, and is not a
          # reason to refuse the set
          {:kty "RSA" :kid "enc" :use "enc" :n "AQAB" :e "AQAB"}
          # so is a key type this build has no verifier for
          {:kty "OKP" :kid "ed" :crv "Ed25519" :x "abc"}
          # and one whose key_ops say it does not verify
          (merge (last fixture/keys) {:kid "wrap" :key_ops ["wrapKey"]})]})
(assert (deep= @["rsa-1"] (map |($ :kid) (jwk/signing-keys mixed)))
        "an unusable key is skipped and the set still works — an issuer that adds an algorithm must not take a resource server down")

# -- refusals are loud where they are the caller's fault -----------------

(each [bad why]
  [[{:kty "OKP" :crv "Ed25519" :x "abc"} "a key type with no verifier"]
   [{:kty "EC" :crv "P-192" :x "abc" :y "abc"} "a curve JWS does not use"]
   [{:kty "RSA" :e "AQAB"} "an RSA key with no modulus"]
   [{:kty "RSA" :n "!!!not base64!!!" :e "AQAB"} "a modulus that is not base64url"]]
  (assert (not (first (protect (jwk/public-pem bad))))
          (string why " is an error, not a silently skipped key")))

# -- the encoding rule worth stating twice -------------------------------
#
# DER integers are signed: a modulus whose top byte has the high bit
# set gains a leading zero, and leading zeroes are dropped otherwise.
# Both directions are here because getting either wrong produces a PEM
# that parses and a signature that never verifies.

(defn- der-of [pem]
  (string (encode/base64-decode
            (string/join (filter |(not (string/has-prefix? "-----" $))
                                 (string/split "\n" pem))))))

(assert (string/find "\0\xff" (der-of (jwk/public-pem {:kty "RSA" :n "_w" :e "AQAB"})))
        "a modulus with the top bit set gains a zero byte")
(assert (not (string/find "\0\x7f" (der-of (jwk/public-pem {:kty "RSA" :n "AH8" :e "AQAB"}))))
        "and a leading zero byte is dropped when it is not needed")

(print "jwk-test ok")
