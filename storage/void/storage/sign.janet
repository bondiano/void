### void/storage/sign — temporary URLs for the local store.
###
### The same construction as void/security's CSRF token, on the same
### keys: the MAC is `secret/sign` over a versioned payload of the key
### and the expiry, verified with `secret/valid?` — constant-time
### against every configured key, so a rotation invalidates nothing.
### This is a *module* edge on void/security, not a plugin one (the
### void/obs — void/pressure/sample pose): signing works when the
### composition includes :void/security, and a composition that never
### asks for a temporary URL never needs it. Asking without the keys is
### an error naming the plugin, not a URL that quietly never verifies.
###
### What rides in the URL is `exp` (unix seconds) and `sig`
### (base64url). The key itself is the URL path, so it is in the
### signature but not repeated in the query; a moved or renamed object
### invalidates its old links, which is the behavior a signed link is
### for. The s3 store never comes here — its temporary URL is SigV4
### query auth, verified by the other end (./sigv4).

(import void/crypto :as crypto)
(import void/security/secret :as secret)

(def- version
  # domain separation: a storage MAC must never verify as a CSRF token
  # or vice versa, and a version in the payload is what allows the
  # scheme to change without a flag day
  "void.storage.v1")

(defn- payload [key expires-at]
  (string version "\n" key "\n" expires-at))

(defn- keys-ready! []
  (when (empty? secret/keys)
    (error (string "storage: a temporary URL needs the signing keys of "
                   ":void/security — add it to :plugins (and [:security "
                   ":signing-key] in :prod), or serve the file without :expires"))))

(defn params
  ``The query parameters of a temporary URL for `key`:
  {"exp" "<unix>" "sig" "<base64url mac>"}. `expires` is seconds from
  `now` (default: from the wall clock).``
  [key expires &opt now]
  (default now (os/time))
  (keys-ready!)
  (unless (and (number? expires) (pos? expires))
    (errorf "storage: :expires must be a positive number of seconds, got %q" expires))
  (def at (math/trunc (+ now expires)))
  {"exp" (string at)
   "sig" (crypto/base64url (secret/sign (payload key at)))})

(defn valid?
  ``Does `sig` authorize `key` until `exp`, and is `exp` still in the
  future? Tampering, truncation and expiry all get the same false —
  which of them it was is nothing a client needs told.``
  [key exp sig &opt now]
  (default now (os/time))
  (truthy?
    (and (bytes? exp) (bytes? sig)
       (not (empty? secret/keys))
       (when-let [at (scan-number (string exp))]
         (and (>= at now)
              (let [[ok raw] (protect (crypto/base64url-decode (string sig)))]
                (and ok (secret/valid? (payload key at) raw))))))))
