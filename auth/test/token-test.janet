(import ../test-support/paths)
(import void/crypto :as crypto)
(import void/auth/store :as store)
(import void/auth/token :as token)

(crypto/load!)

(def tokens (store/normalize-token-store (store/memory-token-store)))
(def issued (token/issue tokens "service:billing" {:name "ci" :scopes [:read]}))
(def value (issued :token))
(def record (issued :record))

# -- the shape -----------------------------------------------------------

(assert (string/has-prefix? "vt_" value) value)
(assert (= 2 (length (string/split "." (string/slice value 3)))))
(def [id secret] (token/parse value))
(assert (= id (record :id)))
(assert (= 16 (length id)) "8 random bytes as hex")
(assert (= 43 (length secret)) "32 random bytes as base64url")

(assert (not= secret (record :digest)) "the store never holds the secret")
(assert (= 64 (length (record :digest))) "it holds a SHA-256 of it, in hex")
(assert (nil? (record :used)))

(each bad ["" "nope" "vt_" "vt_abc" "vt_.secret" "vt_abc." "abc.def" nil 42]
  (assert (nil? (token/parse bad)) (string/format "%q is not a token" bad)))

# -- verification --------------------------------------------------------

(def id1 (token/verify tokens value))
(assert (= "service:billing" (id1 :subject)))
(assert (= :bearer (id1 :via)))
(assert (not (id1 :cookie))
        "a bearer token does not ride on a cookie, so a request holding one is not subject to CSRF")
(assert (deep= [:read] (get-in id1 [:claims :scopes])))
(assert (= (record :id) (get-in id1 [:claims :token])) "the identity says which token it came from")

(assert (truthy? ((tokens :find) (record :id))))
(assert (pos? (((tokens :find) (record :id)) :used)) "and the use was recorded")

(assert (nil? (token/verify tokens (string value "x"))) "a changed secret does not verify")
(assert (nil? (token/verify tokens (string "vt_" (record :id) ".wrong"))))
(assert (nil? (token/verify tokens "vt_0000000000000000.whatever")) "an unknown id is not a token")
(assert (nil? (token/verify tokens "not-a-token")))
(assert (nil? (token/verify tokens (string/slice value 3)))
        "the prefix is part of the token: without it, the bearer strategy declines and JWT gets a look")

# -- expiry --------------------------------------------------------------

(def short (token/issue tokens "user:1" {:ttl 60}))
(assert (token/verify tokens (short :token)))
(assert (nil? (token/verify tokens (short :token) {:now (+ 3600 (os/time))}))
        "an expired token is not an identity")

# -- revocation ----------------------------------------------------------

(assert (= 1 (length (token/list-for tokens "service:billing")))
        "the store lists a subject's tokens — records, never secrets")
(assert (nil? (get (first (token/list-for tokens "service:billing")) :secret)))
(assert (token/revoke tokens (record :id)))
(assert (nil? (token/verify tokens value))
        "revocation is immediate — a token is a store lookup, not a signature that has to expire")
(assert (not (token/revoke tokens (record :id))))

(def own (token/issue tokens "user:9"))
(assert (token/revoke-presented tokens (own :token)) "a client can revoke the token it is holding")
(assert (nil? (token/verify tokens (own :token))))
(assert (not (token/revoke-presented tokens "vt_0000000000000000.x")))

(print "token-test ok")
