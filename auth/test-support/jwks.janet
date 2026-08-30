# The JWKS an authorization server would publish for the throwaway
# key pairs in crypto/test-support/keys.janet — the *same* keys, in the
# form RFC 7517 defines, so `void/auth/jwk` can be checked against PEM
# that OpenSSL wrote for them (auth/test/jwk-test.janet) and the OAuth
# suite can sign tokens that its own fake issuer publishes keys for.
#
# Derived once from those PEMs; regenerate both together or not at all.
# They protect nothing: see that file's header on why fixture keys are
# checked in.

(import spork/json)

(def keys
  "The two public keys, as JWKs."
  [{:kty "RSA" :kid "rsa-1" :use "sig" :alg "RS256"
     :n "p8BwNttTEqJCquOgWnJp-3auVUsjL3chq4zailyZMenONIfrGL2ADpIKqo_p8MkISoniHT9KWSF3nc_593Z_8j5N3PZktDWj3cQK-Z-wGhrIsuzmaQcM3CilYR2Fv1YTOV2eV3ivtO7m2BwMxzmbCz0i4wZV2RS8kxVTezMqryr_WHSLG-Ac_WrFgmnvuez62rDToUnX4VY7eS4f9GyDPp6TzqSIRhsxOBwxII_QHmqQGzYolwgadO8LNaBge9Arr8ljHT9xBKVkc80bm2f6gEXonddcmcdB2gShlCll0-O_PXCfXXogwguLx8AXBznlGcxpbRM4EBSucjrXwN9f_Q"
     :e "AQAB"}
   {:kty "EC" :kid "ec-1" :use "sig" :alg "ES256" :crv "P-256"
     :x "KFESiLA_xdWU1ICoGgMbwt1NZ3uSwMqW4qNSAELC8CY"
     :y "8mTVlcsTRIRTfH_n8Sno4tfY-SMJ1E0IK6dRDrQjDvc"}])

(def document
  "The key set, as an authorization server serves it."
  {:keys keys})

(def json-document
  "The same document, encoded — what a JWKS endpoint writes."
  (json/encode document))
