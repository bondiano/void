(import ../test-support/paths)
(import void/crypto :as crypto)
(import void/crypto/kdf :as kdf)
(import void/core/log :as log)
(import void/auth/store :as store)
(import void/auth/hash :as hash)
(import void/auth/password :as password)

(log/set-level! "void.auth" :error)
(log/set-level! "void.auth.password" :error)
(log/set-level! "void.auth.hash" :error)
(crypto/load!)
(set kdf/in-thread false)
(set hash/settings {:hasher :scrypt
                    :scrypt {:ln 10 :r 8 :p 1 :length 32 :salt-bytes 16}})

(def stored (hash/hash "hunter2"))

(defn- users [&opt extra]
  (store/normalize-user-store
    (merge (store/memory-user-store
             {"user:1" {:subject "user:1" :email "a@b.c" :password-hash stored
                        :claims {:role :admin}}
              "user:2" {:subject "user:2" :email "sso@b.c"}})
           (or extra {}))))

# -- the four answers ----------------------------------------------------

(def ok (password/check (users) {:email "a@b.c" :password "hunter2"}))
(assert (= :ok (ok :reason)))
(assert (= "user:1" (get-in ok [:identity :subject])))
(assert (= :password (get-in ok [:identity :via])))
(assert (deep= {:role :admin} (get-in ok [:identity :claims])) "the store's claims ride along")
(assert (not (get-in ok [:identity :cookie])) "a password is not a cookie credential")

(assert (= :bad-password ((password/check (users) {:email "a@b.c" :password "wrong"}) :reason)))
(assert (= :no-such-user ((password/check (users) {:email "z@z.z" :password "x"}) :reason)))
(assert (= :no-password ((password/check (users) {:email "sso@b.c" :password "x"}) :reason))
        "a user who has no password (SSO, tokens only) cannot log in with one")

(each result [(password/check (users) {:email "a@b.c" :password "wrong"})
              (password/check (users) {:email "z@z.z" :password "x"})]
  (assert (nil? (result :identity)) "and none of the failures produces an identity"))

# -- string keys, because a form has them --------------------------------

(assert (= :ok ((password/check (users) @{"email" "a@b.c" "password" "hunter2"}) :reason))
        "a submitted form goes straight in")

# -- selectors -----------------------------------------------------------

(assert (= :ok ((password/check (users) {:by :subject :value "user:1" :password "hunter2"}) :reason)))
(assert (= :no-such-user ((password/check (users) {:by :username :value "ann" :password "x"}) :reason))
        "an index the store does not keep finds nobody, and says so as nobody")
(assert (= :no-such-user ((password/check (users) {:password "hunter2"}) :reason))
        "no selector at all is not a login")

# :by comes off the submitted form, so it is a closed list: an open one
# would let a visitor pick the WHERE column of the user query
(def probed (password/check (users) {:by :role :value "admin" :password "hunter2"}))
(assert (= :bad-selector (probed :reason))
        "a selector outside the whitelist is refused, not looked up")
(assert (nil? (probed :identity)))
(assert (= :bad-selector ((password/check (users) @{"by" "claims" "value" "x" "password" "x"}) :reason))
        "string keys included — that is exactly how a form would spell it")

# -- rehashing -----------------------------------------------------------

(def written @[])
(def writable
  (users {:update-secret (fn [record phc] (array/push written [(record :subject) phc]) phc)}))

(assert (empty? written))
(assert (= :ok ((password/check writable {:email "a@b.c" :password "hunter2"}) :reason)))
(assert (empty? written) "a hash at the configured cost is not rewritten")

(set hash/settings {:hasher :scrypt :scrypt {:ln 12 :r 8 :p 1 :length 32 :salt-bytes 16}})
(def raised (password/check writable {:email "a@b.c" :password "hunter2"}))
(assert (= :ok (raised :reason)) "a raised cost does not lock anybody out")
(assert (raised :needs-rehash))
(assert (= 1 (length written)) "the login is the only moment the plaintext exists, so the rehash happens here")
(assert (= "user:1" (get-in written [0 0])))
(assert (string/has-prefix? "$scrypt$ln=12," (get-in written [0 1])) "and it is written at the new cost")

# a store that cannot write keeps its old hashes and says so
(def read-only (password/check (users) {:email "a@b.c" :password "hunter2"}))
(assert (read-only :needs-rehash) "without :update-secret the flag is the whole answer")

(set hash/settings {:hasher :scrypt :scrypt {:ln 10 :r 8 :p 1 :length 32 :salt-bytes 16}})

# -- the strategy wrapper ------------------------------------------------

(def s (password/strategy (users)))
(assert (= :password (s :name)))
(assert (nil? (s :authenticate)) "the password strategy never runs on the hot path")
(assert (= "user:1" (((s :verify) {:email "a@b.c" :password "hunter2"}) :subject)))
(assert (nil? ((s :verify) {:email "a@b.c" :password "no"})))

(print "password-test ok")
