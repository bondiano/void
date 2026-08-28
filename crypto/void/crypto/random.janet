### void/crypto/random — randomness, from the operating system.
###
### The one primitive ADR-0022 deliberately does **not** take from
### libcrypto. `os/cryptorand` is getrandom(2) / arc4random(3) — the
### kernel's own CSPRNG, with the guarantees we want, and going through
### `RAND_bytes` instead would add a userspace pool that has to be
### re-seeded after fork. void forks (ADR-0010, prefork workers), and a
### generator whose state is inherited by every worker is the classic
### way to hand several processes the same "random" session ids.
###
### Sizes are in **bytes**, and the default is 32 of them: 256 bits is
### the size at which guessing stops being a threat model, and every
### token in void (session id, API token, CSRF nonce, one-time code
### secret) is that or larger.

(import ./encode :as encode)

(def default-size
  "Bytes in a token nobody sized on purpose: 256 bits."
  32)

(defn bytes
  "n cryptographically random bytes from the OS."
  [&opt n]
  (default n default-size)
  (unless (and (int? n) (pos? n))
    (errorf "random/bytes needs a positive count, got %q" n))
  (os/cryptorand n))

(defn token
  ``A URL- and cookie-safe random token: n random bytes as base64url
  (43 characters for the default 32 bytes). This is what an API token,
  a magic-link code and a session id are made of.``
  [&opt n]
  (encode/base64url (bytes n)))

(defn hex-token
  "The same randomness spelled in hex — for places that must stay
  case-insensitive or alphanumeric (a URL path segment, an OTP link)."
  [&opt n]
  (encode/hex (bytes n)))

(defn digits
  ``A numeric one-time code of `n` digits, uniform and without modulo
  bias: rejection sampling over whole bytes rather than `(% x 10)`,
  which would make 0-5 more likely than 6-9 on a 256-value byte.``
  [&opt n]
  (default n 6)
  (unless (and (int? n) (pos? n) (<= n 32))
    (errorf "random/digits takes 1..32 digits, got %q" n))
  (def out (buffer/new n))
  (while (< (length out) n)
    (each b (bytes 16)
      (when (and (< (length out) n) (< b 250))
        (buffer/push-byte out (+ (chr "0") (% b 10))))))
  (string out))
