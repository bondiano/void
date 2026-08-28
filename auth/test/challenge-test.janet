(import ../test-support/paths)
(import void/crypto :as crypto)
(import void/auth/store :as store)
(import void/auth/challenge :as challenge)

(crypto/load!)

(def codes (store/normalize-challenge-store (store/memory-challenge-store)))

# -- magic links ---------------------------------------------------------

(def link (challenge/issue codes "user:1" {:claims {:next "/dashboard"}}))
(assert (= :link (link :kind)))
(assert (= 16 (length (link :handle))) "a fresh handle, which is what goes in the URL")
(assert (= 43 (length (link :code))) "256 bits, because nobody types a link")
(assert (> (link :expires) (os/time)))

(def stored (get (get codes :rows) (link :handle)))
(assert (not (string/find (link :code) (string/format "%q" stored)))
        "the store holds a digest, so its contents cannot be replayed as codes")

(def id (challenge/redeem codes (link :handle) (link :code)))
(assert (= "user:1" (id :subject)))
(assert (= :magic-link (id :via)))
(assert (= "/dashboard" (get-in id [:claims :next])) "the claims issued with the challenge come back")
(assert (nil? (challenge/redeem codes (link :handle) (link :code)))
        "and a redeemed challenge is gone — single-use is the entire property")

# -- one-time codes ------------------------------------------------------

(def otp (challenge/issue codes "user:2" {:kind :otp}))
(assert (= :otp (otp :kind)))
(assert (= "user:2" (otp :handle)) "an OTP is keyed by subject, so asking again replaces the old code")
(assert (= 6 (length (otp :code))))
(assert (all |(and (>= $ (chr "0")) (<= $ (chr "9"))) (otp :code)))

(def otp2 (challenge/issue codes "user:2" {:kind :otp}))
(assert (nil? (challenge/redeem codes (otp :handle) (otp :code)))
        "the second code replaced the first — asking for a new code invalidates the one already sent (and, being an attempt, burns the new one too)")

(def otp3 (challenge/issue codes "user:2" {:kind :otp}))
(assert (= "user:2" ((challenge/redeem codes (otp3 :handle) (otp3 :code)) :subject)))

# -- a wrong code burns the challenge ------------------------------------

(def burned (challenge/issue codes "user:3" {:kind :otp}))
(assert (nil? (challenge/redeem codes (burned :handle) "000000")) "a wrong code does not redeem")
(assert (nil? (challenge/redeem codes (burned :handle) (burned :code)))
        "and it burned the challenge: a code gets one attempt, by construction (see the module docstring)")

# -- expiry and nonsense -------------------------------------------------

(def old (challenge/issue codes "user:4" {:ttl -1}))
(assert (nil? (challenge/redeem codes (old :handle) (old :code))) "an expired challenge is not redeemable")

(assert (nil? (challenge/redeem codes nil "123456")))
(assert (nil? (challenge/redeem codes "nothing" "123456")))
(assert (nil? (challenge/redeem codes "user:2" nil)))

(print "challenge-test ok")
