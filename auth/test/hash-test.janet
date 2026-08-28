(import ../test-support/paths)
(import void/crypto :as crypto)
(import void/crypto/kdf :as kdf)
(import void/core/log :as log)
(import void/auth/hash :as hash)

(log/set-level! "void.auth.hash" :error)
(crypto/load!)
(set kdf/in-thread false)

# the suite hashes dozens of times and measures none of them: the real
# cost is pinned by void/crypto's own tests
(def cheap {:hasher :scrypt
            :scrypt {:ln 10 :r 8 :p 1 :length 32 :salt-bytes 16}
            :argon2id {:m 512 :t 1 :p 1 :length 32 :salt-bytes 16}})
(set hash/settings cheap)

# -- the PHC string ------------------------------------------------------

(def h (hash/hash "hunter2"))
(assert (string/has-prefix? "$scrypt$ln=10,r=8,p=1$" h) h)
(assert (= 5 (length (string/split "$" h))) "id, params, salt, hash — and the empty field before the leading $")

(def parsed (hash/parse h))
(assert (= :scrypt (parsed :id)))
(assert (= 10 (get-in parsed [:params :ln])))
(assert (= 8 (get-in parsed [:params :r])))
(assert (= 16 (length (parsed :salt))) "a 16-byte salt, decoded from the string")
(assert (= 32 (length (parsed :hash))))
(assert (nil? (parsed :version)) "scrypt PHC carries no version field")

(assert (not= h (hash/hash "hunter2"))
        "every hash gets a fresh salt, so two identical passwords never collide in the database")

(each bad ["" "not-a-phc" "$scrypt$" "$scrypt$ln=10$salt" "$scrypt$ln$c2E$c2E"]
  (def [ok] (protect (hash/parse bad)))
  (assert (not ok) (string/format "%q is not a PHC string" bad)))

# -- verify --------------------------------------------------------------

(assert (deep= [true false] (hash/verify "hunter2" h)))
(assert (deep= [false false] (hash/verify "hunter3" h)))
(assert (deep= [false false] (hash/verify "" h)))
(assert (deep= [false false] (hash/verify "hunter2" nil))
        "no stored hash is a failed login, not a crash — and it still costs the time (see dummy-verify)")
(assert (deep= [false false] (hash/verify "hunter2" "$scrypt$garbage"))
        "and so is a stored value that will not parse")

# -- the algorithm comes from the string, not from the settings ----------

(when ((crypto/algorithms) :argon2id)
  (def a (hash/hash "hunter2" {:hasher :argon2id}))
  (assert (string/has-prefix? "$argon2id$v=19$m=512,t=1,p=1$" a) a)
  (assert (= 19 ((hash/parse a) :version)) "argon2 PHC carries v=19")
  (assert (deep= [true true] (hash/verify "hunter2" a))
          "an argon2id hash verifies while :scrypt is configured — and is marked for rehashing")
  (assert (deep= [false false] (hash/verify "wrong" a)))

  # and the other way round: with argon2id configured, an old scrypt
  # hash keeps working
  (set hash/settings (merge cheap {:hasher :argon2id}))
  (assert (deep= [true true] (hash/verify "hunter2" h))
          "old hashes are not invalidated by changing the setting — that is the whole point of PHC")
  (assert (deep= [true false] (hash/verify "hunter2" a)))
  (set hash/settings cheap))

# -- rehashing on a raised cost ------------------------------------------

(assert (not (hash/needs-rehash? h)) "a hash written at the configured cost needs nothing")
(set hash/settings (merge cheap {:scrypt (merge (cheap :scrypt) {:ln 12})}))
(assert (hash/needs-rehash? h) "raising the cost marks every older hash for replacement")
(assert (deep= [true true] (hash/verify "hunter2" h))
        "and it still verifies while it waits — a raised cost must not lock anybody out")
(set hash/settings cheap)
(assert (hash/needs-rehash? "not-a-phc") "an unparseable stored value certainly needs rehashing")

# -- dummy verify --------------------------------------------------------

(assert (= false (hash/dummy-verify "anything")) "it answers false, always")
(assert (= false (hash/dummy-verify)))

# the timing claim, loosely: an unknown user must not be an order of
# magnitude faster than a wrong password. The bar is deliberately weak
# (a factor of five) so that a loaded CI machine does not fail the
# suite, while a dummy verify that did nothing at all — the bug this
# guards — would be a factor of a thousand.
(defn- micros [thunk]
  # the fastest of three: a GC pause or a busy machine inflates one
  # sample by an order of magnitude, and this assertion is about what
  # the work costs, not about what the scheduler did
  (min ;(seq [_ :range [0 3]]
          (def t0 (os/clock :monotonic))
          (thunk)
          (* 1e6 (- (os/clock :monotonic) t0)))))

(def real (micros (fn [] (hash/verify "hunter2" h))))
(def dummy (micros (fn [] (hash/dummy-verify "hunter2"))))
(assert (> dummy (/ real 5))
        (string/format "dummy verify (%.0f µs) is in the same order as a real one (%.0f µs)" dummy real))

(print "hash-test ok")
