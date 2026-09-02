### void/auth/hash — password hashes as PHC strings (ADR-0023 §4).
###
### What is stored is not a hash but a **PHC string**:
###
###     $scrypt$ln=14,r=8,p=1$c2FsdHNhbHRzYWx0$aGFzaGhhc2hoYXNo
###     $argon2id$v=19$m=65536,t=2,p=1$c2FsdA$aGFzaA
###
### The cost parameters live *in the string*, and that is the whole
### design. Raising the cost is then a config change that applies to
### everybody who logs in next, not a migration that cannot be written
### (nobody can re-derive a hash without the password). Moving to or
### from another stack is an `UPDATE`, not a password reset, because
### this is the format Python's passlib, Go's argon2 and PHP's
### password_hash already read.
###
### `verify` picks the algorithm **from the stored string**, never from
### the configuration: while `[:auth :hasher]` says argon2id, every
### scrypt hash written before that keeps working, and `needs-rehash?`
### is how they migrate — one at a time, on successful logins, with the
### plaintext in hand for the only moment it ever exists.
###
### **Timing.** `verify` against a user that does not exist still
### computes a hash (`dummy-verify`): without it, "no such account"
### answers in 200 µs and "wrong password" in 25 ms, which enumerates
### every registered address at leisure. The comparison itself is
### `crypto/equal?` — constant-time — for the same reason.
###
### Every primitive comes from `void/crypto` (ADR-0022). This module
### derives nothing itself; it decides what to derive, how to spell it,
### and when to spell it again.

(import void/crypto/kdf :as kdf)
(import void/crypto/random :as random)
(import void/crypto/encode :as encode)
(import void/crypto/ct :as ct)
(import void/core/log :as log)

(def log-ns "void.auth.hash")

(def defaults
  ``Default hasher and its cost.

  `:scrypt` is the default rather than argon2id because argon2id
  needs OpenSSL 3.2 and an LTS distribution may ship 3.0 (ADR-0022
  §2) — a default that fails to start on Ubuntu 24.04 is not a
  default. An application on a newer library sets `[:auth :hasher
  :argon2id]` and, ideally, `[:crypto :require [:argon2id]]` so the
  choice is checked at boot.

  ln=14 is N=16384: ~25 ms and 16 MiB per hash, the interactive
  setting from RFC 7914 §2 raised a notch. argon2id m=64 MiB t=2 p=1
  is OWASP's second profile.``
  {:hasher :scrypt
   :scrypt {:ln 14 :r 8 :p 1 :length 32 :salt-bytes 16}
   :argon2id {:m 65536 :t 2 :p 1 :length 32 :salt-bytes 16}})

(var settings
  "The [:auth] hashing slice, set by the plugin at :before-start; the
  module works on the defaults without one."
  defaults)

# -- the PHC string ------------------------------------------------------

(defn- format-params [pairs]
  (string/join (map (fn [[k v]] (string/format "%s=%d" k v)) pairs) ","))

(defn- parse-params [text]
  (def out @{})
  (each field (string/split "," text)
    (def i (first (string/find-all "=" field)))
    (unless i (errorf "PHC parameter %q has no value" field))
    (def key (keyword (string/slice field 0 i)))
    (def value (scan-number (string/slice field (inc i))))
    (unless (and (number? value) (int? value))
      (errorf "PHC parameter %q is not an integer" field))
    (put out key value))
  out)

(defn parse
  ``Parse a PHC string into {:id :version :params :salt :hash}. Throws
  on anything that is not one — a stored value that will not parse is
  a data problem, and the callers below turn it into a failed login
  rather than a 500.``
  [encoded]
  (unless (and (bytes? encoded) (string/has-prefix? "$" (string encoded)))
    (errorf "not a PHC string: %q" encoded))
  (def fields (string/split "$" (string encoded)))
  # a leading $ makes the first field empty
  (def fields (array/slice fields 1))
  (unless (>= (length fields) 4)
    (errorf "not a PHC string: %q" encoded))
  (def id (keyword (first fields)))
  (def rest (array/slice fields 1))
  (def version
    (when (string/has-prefix? "v=" (first rest))
      (scan-number (string/slice (first rest) 2))))
  (def rest (if version (array/slice rest 1) rest))
  (unless (= 3 (length rest))
    (errorf "not a PHC string: %q" encoded))
  {:id id
   :version version
   :params (parse-params (rest 0))
   :salt (encode/base64-decode (rest 1))
   :hash (encode/base64-decode (rest 2))})

# -- the hashers ---------------------------------------------------------

(defn- scrypt-derive [password salt params]
  (kdf/scrypt password salt
              {:n (blshift 1 (params :ln))
               :r (params :r)
               :p (params :p)
               :length (get params :length 32)
               # 128 * N * r, with room to spare: the library refuses
               # rather than swaps, and a limit that tracks the cost is
               # one thing an operator never has to know about
               :maxmem (* 4 128 (blshift 1 (params :ln)) (params :r))}))

(defn- argon2-derive [password salt params]
  (kdf/argon2id password salt
                {:m (params :m)
                 :t (params :t)
                 :lanes (params :p)
                 :length (get params :length 32)}))

(def hashers
  ``The built-in hashers, by PHC identifier. Each knows how to derive,
  how to spell its parameters and how to read them back — nothing
  else about a hasher is this module's business.``
  {:scrypt
   {:name :scrypt
    :derive scrypt-derive
    :encode-params (fn [p] (format-params [["ln" (p :ln)] ["r" (p :r)] ["p" (p :p)]]))
    :version nil
    :cost-keys [:ln :r :p]}

   :argon2id
   {:name :argon2id
    :derive argon2-derive
    :encode-params (fn [p] (format-params [["m" (p :m)] ["t" (p :t)] ["p" (p :p)]]))
    # 19 is 0x13, the argon2 version every current implementation writes
    :version 19
    :cost-keys [:m :t :p]}})

(defn- hasher-for [id]
  (or (hashers id)
      (errorf "no hasher for %q (have %s)" id
              (string/join (map string (sorted (keys hashers))) " "))))

(defn- params-for [name]
  (merge (get defaults name {}) (get settings name {})))

(defn active-hasher
  "The hasher new passwords are stored with — [:auth :hasher]."
  []
  (get settings :hasher (defaults :hasher)))

(defn hash
  ``Hash a password into a PHC string with the configured hasher (or
  the one named in `opts`). Every call uses a fresh random salt, so
  two identical passwords never collide in the database.

  Hash *before* opening a transaction. The KDF is a deliberately slow,
  CPU-bound wait (off the event loop, but tens to hundreds of ms), and
  a route under `:void.db/txn` has already taken its BEGIN — on sqlite
  that is the database's one writer lock held for the whole derivation,
  and every other writer queues behind a password. A register is one
  INSERT: hash first, let the statement be its own transaction, and
  leave the duplicate address to the unique index.``
  [password &opt opts]
  (default opts {})
  (def name (get opts :hasher (active-hasher)))
  (def h (hasher-for name))
  (def params (merge (params-for name) (get opts :params {})))
  (def salt (random/bytes (get params :salt-bytes 16)))
  (def raw ((h :derive) password salt params))
  (string "$" name "$"
          (if-let [v (h :version)] (string "v=" v "$") "")
          ((h :encode-params) params) "$"
          (encode/base64 salt) "$"
          (encode/base64 raw)))

(defn- recompute [password parsed]
  (def h (hasher-for (parsed :id)))
  ((h :derive) password (parsed :salt)
   (merge (parsed :params) {:length (length (parsed :hash))})))

(defn needs-rehash?
  ``Was this hash written with something other than what is configured
  now — another algorithm, or a lower cost? Rehash on the next
  successful login, which is the only moment the plaintext exists.``
  [encoded]
  (def [ok parsed] (protect (parse encoded)))
  (cond
    (not ok) true
    (not= (parsed :id) (active-hasher)) true
    (let [want (params-for (parsed :id))
          have (parsed :params)]
      # `some` answers nil rather than false when nothing matches, and
      # this is a predicate somebody will store in a database column
      (truthy? (some |(< (get have $ 0) (get want $ 0))
                     (get (hasher-for (parsed :id)) :cost-keys []))))))

(var- dummy-cache nil)

(defn dummy-verify
  ``Burn the time a real verification would take, and answer false.
  Call it where there is no stored hash to check — an unknown account,
  a user with no password set — or the difference between 200 µs and
  25 ms enumerates every registered address (ADR-0023 §4).``
  [&opt password]
  (default password "void-dummy-password")
  (unless (and dummy-cache (= (dummy-cache :hasher) (active-hasher)))
    (set dummy-cache {:hasher (active-hasher)
                      :encoded (hash "void-dummy-reference-password")}))
  (def [ok] (protect (recompute password (parse (dummy-cache :encoded)))))
  (unless ok
    (log/warn "dummy verify failed to compute" :ns log-ns))
  false)

(defn verify
  ``Check a password against a stored PHC string. Returns
  `[ok? needs-rehash?]`.

  The algorithm comes from the stored string, never from the
  configuration, so hashes written by an older setting keep verifying
  while `needs-rehash?` marks them for replacement. A nil or
  unparseable stored value answers `[false false]` **after** spending
  the time a real check would have taken.``
  [password encoded]
  (if (nil? encoded)
    (do (dummy-verify password) [false false])
    (let [[ok parsed] (protect (parse encoded))]
      (if (not ok)
        (do
          (log/warn "stored password hash is not a PHC string" :ns log-ns)
          (dummy-verify password)
          [false false])
        (let [[computed raw] (protect (recompute password parsed))]
          (if (not computed)
            (do
              (log/warn "stored password hash cannot be recomputed"
                        :ns log-ns :hasher (parsed :id) :err (string raw))
              [false false])
            (if (ct/equal? raw (parsed :hash))
              [true (needs-rehash? encoded)]
              [false false])))))))
