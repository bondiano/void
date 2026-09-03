### void/oauth/pkce — Proof Key for Code Exchange (RFC 7636).
###
### S256 and nothing else: OAuth 2.1 requires PKCE for every client,
### and `plain` exists only for a device that cannot hash — which this
### one can. There is deliberately no knob to turn it off: a client
### without PKCE is open to code injection on the redirect, and "my
### authorization server does not support it" is a reason to upgrade
### the server, not to hand out the downgrade in configuration.
###
### The verifier is 32 bytes of OS randomness in the base64url alphabet —
### 43 characters, inside RFC 7636 §4.1's 43..128 window. The challenge is
### base64url(SHA-256(verifier)), computed with void/crypto: nothing
### cryptographic is written here, only an encoding.

(import void/crypto :as crypto)

(defn verifier
  "A fresh code verifier: 43 characters of the unreserved alphabet."
  []
  (crypto/base64url (crypto/random-bytes 32)))

(defn challenge
  "The S256 code challenge for a verifier — what goes into the
  authorization request, while the verifier waits for the exchange."
  [verifier]
  (crypto/base64url (crypto/sha256 verifier)))

(def method
  "The one challenge method this client speaks."
  "S256")
