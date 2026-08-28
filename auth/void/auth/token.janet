### void/auth/token — API tokens (ADR-0023 §5).
###
### A token is `<prefix><id>.<secret>`:
###
###     vt_kQ2m8Xr1.9ZC4t1qHkX0oWq7nBv3sLd2fPa6uYe8i5RgTjMhN0cA
###
### The **id** is a public lookup key; the **secret** is 256 bits from
### the OS. The store keeps a SHA-256 of the secret and never sees the
### secret again — a database dump does not yield working tokens, and
### the digest is enough to check one.
###
### **Why SHA-256 and not scrypt.** The secret is already uniform
### randomness; a KDF exists to make *guessable* inputs expensive to
### try, and there is nothing to guess here. Running scrypt would cost
### 25 ms on every API request (ADR-0022 §5) and buy no bits. Passwords
### are the exact opposite case, which is why they cost what they cost.
###
### **Why the id is separate from the secret.** Without it, checking a
### token means scanning every row, or indexing the digest and giving
### up constant-time comparison. With it, the lookup is one indexed
### read and the comparison is `crypto/equal?` on the digest.
###
### **Why the prefix.** `vt_` makes a leaked token recognisable —
### secret scanners key on prefixes, and so does the human reading a
### bug report. It is configurable because an application shipping its
### own product should use its own.

(import void/crypto/digest :as digest)
(import void/crypto/random :as random)
(import void/crypto/encode :as encode)
(import void/crypto/ct :as ct)
(import ./identity :as identity)

(def defaults
  "Shape of a token: how much randomness, and what it looks like."
  {:prefix "vt_"
   :id-bytes 8
   :secret-bytes 32})

(defn- digest-of [secret]
  (encode/hex (digest/sha256 secret)))

(defn parse
  ``Split a presented token into [id secret], or nil when it is not
  shaped like one. Cheap and total: it runs on every request that
  carries an Authorization header, including the ones carrying
  something else entirely.``
  [presented &opt opts]
  (default opts {})
  (def prefix (get opts :prefix (defaults :prefix)))
  (when (bytes? presented)
    (def text (string presented))
    (when (string/has-prefix? prefix text)
      (def body (string/slice text (length prefix)))
      (def i (first (string/find-all "." body)))
      (when (and i (pos? i) (< (inc i) (length body)))
        [(string/slice body 0 i) (string/slice body (inc i))]))))

(defn issue
  ``Mint a token for a subject and store its digest. Returns
  `{:token :record}` — the token is the **only** time the secret
  exists, so a caller that does not show it to the user has lost it.

  Options: :name (what the token is for), :scopes, :ttl (seconds),
  :claims, plus the shape options of `defaults`.``
  [store subject &opt opts]
  (default opts {})
  (def prefix (get opts :prefix (defaults :prefix)))
  (def id (encode/hex (random/bytes (get opts :id-bytes (defaults :id-bytes)))))
  (def secret (random/token (get opts :secret-bytes (defaults :secret-bytes))))
  (def now (get opts :now (os/time)))
  (def record
    {:id id
     :digest (digest-of secret)
     :subject subject
     :name (get opts :name "api token")
     :scopes (get opts :scopes [])
     :claims (get opts :claims {})
     :created now
     :expires (when-let [ttl (opts :ttl)] (+ now ttl))
     :used nil})
  ((store :put) record)
  {:token (string prefix id "." secret) :record record})

(defn find-record
  ``The stored record behind a presented token, or nil. Checks the
  digest in constant time and the expiry against `now`; does not
  touch `:used`.``
  [store presented &opt opts]
  (default opts {})
  (def now (get opts :now (os/time)))
  (when-let [[id secret] (parse presented opts)
             record ((store :find) id)]
    (when (and (ct/equal? (digest-of secret) (record :digest))
               (or (nil? (record :expires)) (> (record :expires) now)))
      record)))

(defn verify
  ``The identity behind a presented token, or nil. Records the use
  through the store's `:touch` — which a store is free to ignore.``
  [store presented &opt opts]
  (default opts {})
  (def now (get opts :now (os/time)))
  (when-let [record (find-record store presented opts)]
    ((store :touch) (record :id) now)
    (identity/make (record :subject)
                   {:via :bearer
                    # a bearer token is not carried by a cookie, so a
                    # request holding one is not subject to CSRF
                    # (ADR-0025 §1)
                    :cookie false
                    :claims (merge (get record :claims {})
                                   {:scopes (get record :scopes [])
                                    :token (record :id)})
                    :at now
                    :expires (record :expires)})))

(defn revoke
  "Delete a token by id. Returns true when there was one."
  [store id]
  (truthy? ((store :delete) id)))

(defn revoke-presented
  "Delete the token a client presented — logout, for an API client."
  [store presented &opt opts]
  (if-let [record (find-record store presented opts)]
    (revoke store (record :id))
    false))

(defn list-for
  "Every token of a subject — what a settings page lists. Records carry
  digests, never secrets."
  [store subject]
  ((store :list) subject))
