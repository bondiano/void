### void/security/secret — the signing keys (ADR-0025 §2).
###
### Everything this package signs — the CSRF token today, whatever
### needs a MAC later — is signed with the first key in a list and
### verified against any key in it. That is the whole of key rotation:
### put the new key first, keep the old one until the longest-lived
### token has expired, then drop it. Two deploys, no invalidation.
###
### **In production a missing key is a boot error, not a warning.** A
### framework that quietly invents a key at startup gives every worker
### in a prefork setup (ADR-0010) and every machine in a fleet a
### *different* one, so a token issued by one is rejected by the next
### and the failure looks like anything but its cause. In dev the key
### is generated with a warning, because `void new` has to work before
### anybody has written a config.
###
### The key belongs in the environment, and the config layer already
### spells that: `{:security {:signing-key {:secret "VOID_SECRET"}}}` is
### an env-var reference (ADR-0007), and a resolved secret box is
### unwrapped here.
###
### **Why the config key is `:signing-key` and not `:secret`.** A
### dictionary shaped `{:secret "NAME"}` *is* the env reference, so
### `{:security {:secret "abc"}}` would be read as "the [:security]
### slice comes from the environment variable abc" — the literal form
### everybody writes first would be silently reinterpreted, and the
### error would name a variable nobody wrote. The key is spelled
### differently so that both forms mean what they look like.

(import void/core/config :as config)
(import void/core/log :as log)
(import void/crypto :as crypto)

(def log-ns "void.security.secret")

(def min-length
  "Shortest key we accept. 32 bytes is the HMAC-SHA256 block-ish size
  and the point past which guessing stops being a strategy; a shorter
  one is almost always a placeholder somebody meant to replace."
  32)

(var keys
  "Signing keys, newest first. The first signs; any of them verifies."
  @[])

(defn- reveal [value]
  (cond
    (nil? value) nil
    (config/secret? value) (config/reveal value)
    (bytes? value) (string value)
    (errorf "[:security :signing-key] must be a string or an env reference like {:secret \"VOID_SECRET\"}, got %q" value)))

(defn configure!
  ``Install the signing keys from the [:security] slice for `profile`.
  `:signing-key` is the current one, `:previous-keys` the ones still
  accepted. Returns the number of keys installed.``
  [cfg &opt profile]
  (default profile :dev)
  (def current (reveal (get cfg :signing-key)))
  (def previous (map reveal (get cfg :previous-keys [])))
  (cond
    current
    (do
      (when (< (length current) min-length)
        (log/warn "the signing key is shorter than recommended" :ns log-ns
                  :length (length current) :recommended min-length))
      (set keys (array current ;(filter truthy? previous))))

    (= :prod profile)
    (error (string "[:security :signing-key] is not set. In production the signing "
                   "key must be configured — a generated one differs between prefork "
                   "workers and between machines, so tokens issued by one process are "
                   "refused by the next. Use {:security {:signing-key {:secret "
                   "\"VOID_SECRET\"}}} and put the value in the environment"))

    (do
      (set keys (array (crypto/token 32)))
      (log/warn (string "no [:security :signing-key] — generated an ephemeral one. "
                        "Tokens do not survive a restart, and in prefork or a "
                        "fleet they do not survive the next request either")
                :ns log-ns :profile profile)))
  (length keys))

(defn signing-key
  "The key new signatures are made with."
  []
  (or (first keys)
      (error "void/security has no signing key — configure! has not run")))

(defn sign
  "MAC of `data` under the current key."
  [data]
  (crypto/hmac-sha256 (signing-key) data))

(defn valid?
  ``Does `mac` match `data` under **any** configured key? Constant-time
  per key, so a rotation costs one comparison more and leaks nothing.``
  [data mac]
  (var ok false)
  (each k keys
    (when (crypto/equal? mac (crypto/hmac-sha256 k data))
      (set ok true)))
  ok)

(defn rotated?
  "Is there more than one key — that is, is a rotation in progress?"
  []
  (> (length keys) 1))
