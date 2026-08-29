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

# -- issuing and delivering in one call ----------------------------------
#
# `challenge!` is the half that waited for a delivery to exist (3.5,
# ADR-0026 §6). It reads the stores and the deliverers off the running
# auth value, and the dyn is the seam that stands one in front of it
# without booting anything.

(import void/auth :as auth)
(import void/auth/state :as state)
(import void/core/log :as log)

(log/set-level! "void" :fatal)

(defn- with-deliverers [ds f]
  (with-dyns [state/auth-dyn (state/make {:challenges codes :deliver ds})]
    (f)))

(def seen @[])
(def issued
  (with-deliverers [{:name :test/mail
                     :fn (fn [ch] (array/push seen ch) :sent)}
                    {:name :test/sms
                     # a deliverer that is not for this payload does
                     # nothing and says nothing
                     :fn (fn [ch] (when (= :sms (ch :channel)) :sent))}]
    (fn [] (auth/challenge! "user:9" {:to "ada@example.com" :claims {:name "Ada"}}))))

(assert (deep= @[:test/mail] (issued :delivered)) "only the deliverer that took it is reported")
(assert (nil? (issued :code))
        "the code is not in the return value: it exists inside the call and inside whatever carried it away")

(def payload (first seen))
(assert (= "ada@example.com" (payload :to)))
(assert (= "user:9" (payload :subject)))
(assert (= "Ada" (get-in payload [:claims :name])))
(assert (payload :code) "the deliverer is the one place the code exists")

(def id (with-deliverers [] (fn [] (auth/redeem! (issued :handle) (payload :code)))))
(assert (= "user:9" (id :subject)) "and the code it carried is the one that redeems")

(def [ok err]
  (protect (with-deliverers [{:name :test/sms :fn (fn [ch] nil)}]
             (fn [] (auth/challenge! "user:9" {:to "ada@example.com"})))))
(assert (not ok)
        "a challenge nobody delivered is an error: the visitor is waiting for a code that is not coming")
(assert (string/find "nobody delivered it" (string err)))

(assert (not (first (protect (with-deliverers []
                               (fn [] (auth/challenge! "user:9" {}))))))
        "and so is one in a composition with no deliverer at all")

(assert (not (first (protect (with-deliverers [{:name :test/boom
                                                :fn (fn [_] (error "smtp is down"))}]
                               (fn [] (auth/challenge! "user:9" {:to "a@b.co"}))))))
        "a deliverer that failed is a failure of the call — the caller is telling somebody to check their mail")

(print "challenge-test ok")
