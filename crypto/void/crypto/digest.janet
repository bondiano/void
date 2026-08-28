### void/crypto/digest — SHA-2 and HMAC, from the library (ADR-0022).
###
### One-shot calls (`EVP_Digest`, `HMAC`) rather than the init/update/
### final dance: everything void hashes — a token, a JWS signing input,
### a cookie value — is already one contiguous piece of memory, and a
### streaming API would mean a context object with a lifetime to get
### wrong for no gain. When something in void starts hashing files,
### streaming comes back as a separate function with its own tests.
###
### Everything returns **raw bytes**, never hex: the caller picks the
### spelling (`encode/hex`, `encode/base64url`), and a function that
### returned hex would quietly double every length in the database.

(import ./lib :as lib)

(def sizes
  "Digest length in bytes, by algorithm."
  {:sha1 20 :sha256 32 :sha384 48 :sha512 64})

(defn- known
  ``[digest length, EVP_MD pointer] for an algorithm name, or an error
  naming the ones there are. One lookup for both callers below, so the
  message cannot depend on which of them asked.``
  [algo]
  (def size
    (or (sizes algo)
        (errorf "unknown digest %q (have %s)" algo
                (string/join (map string (sorted (keys sizes))) " "))))
  [size
   (case algo
     :sha256 (lib/EVP_sha256)
     :sha384 (lib/EVP_sha384)
     :sha512 (lib/EVP_sha512)
     # SHA-1 is here for TOTP (RFC 6238 fixed it) and for nothing else;
     # it is not offered as a hash for anything void stores
     :sha1 (lib/EVP_sha1))])

(defn digest
  "Hash bytes with one of :sha1 :sha256 :sha384 :sha512. Returns raw
  bytes."
  [algo data]
  (lib/ensure!)
  (def [size md] (known algo))
  (def out (buffer/new-filled size))
  (def written (buffer/new-filled 4))
  (def rc (lib/EVP_Digest data (length data) out written md nil))
  (unless (= 1 rc)
    (errorf "EVP_Digest(%q) failed: %s" algo (or (lib/last-error) "no detail")))
  (string out))

(defn sha256 "SHA-256 of bytes, raw." [data] (digest :sha256 data))
(defn sha384 "SHA-384 of bytes, raw." [data] (digest :sha384 data))
(defn sha512 "SHA-512 of bytes, raw." [data] (digest :sha512 data))

(defn hmac
  ``HMAC of `data` under `key`, raw bytes. The key is bytes, not a
  password: HMAC does not stretch, so a key derived from something
  guessable stays guessable.``
  [algo key data]
  (lib/ensure!)
  (def [size md] (known algo))
  (def out (buffer/new-filled 64))
  (def written (buffer/new-filled 4))
  (def rc (lib/HMAC md key (length key) data (length data) out written))
  (when (nil? rc)
    (errorf "HMAC(%q) failed: %s" algo (or (lib/last-error) "no detail")))
  (string (buffer/slice out 0 size)))

(defn hmac-sha256
  "HMAC-SHA256 — what signs a CSRF token, a JWS with HS256 and every
  short-lived value void hands a client."
  [key data]
  (hmac :sha256 key data))
