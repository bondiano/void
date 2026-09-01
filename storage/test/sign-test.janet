# Temporary URLs for the local store: the same construction as the CSRF
# token, on the same keys — so what is asserted here is that expiry,
# tampering and rotation all behave the way a signed link has to.

(import ../test-support/paths)
(import void/crypto :as crypto)
(import void/security/secret :as secret)
(import void/storage/sign :as sign)

(crypto/load!)

# -- without keys nothing is signed, and it says so ----------------------

(set secret/keys @[])
(def [ok err] (protect (sign/params "a.png" 60)))
(assert (not ok) "asking for a temporary URL without signing keys is an error")
(assert (string/find "void/security" (string err))
        "and it names the plugin that carries them")
(assert (not (sign/valid? "a.png" "99999999999" "whatever"))
        "and nothing verifies against no keys")

# -- the round trip ------------------------------------------------------

(secret/configure! {:signing-key (string/repeat "k" 32)} :test)

(def now 1_800_000_000)
(def p (sign/params "uploads/a.png" 600 now))

(assert (= (string (+ now 600)) (p "exp")) "exp is the absolute instant, not a duration")
(assert (string? (p "sig")))

(assert (sign/valid? "uploads/a.png" (p "exp") (p "sig") now)
        "a fresh signature verifies")
(assert (sign/valid? "uploads/a.png" (p "exp") (p "sig") (+ now 599))
        "and keeps verifying until it expires")
(assert (not (sign/valid? "uploads/a.png" (p "exp") (p "sig") (+ now 601)))
        "a second past the expiry it does not")

# -- what a signature is bound to ----------------------------------------

(assert (not (sign/valid? "uploads/b.png" (p "exp") (p "sig") now))
        "the key is in the signature, so a link cannot be pointed at another object")
(assert (not (sign/valid? "uploads/a.png" (string (+ now 6000)) (p "sig") now))
        "and so is the expiry, so a link cannot be extended by editing it")
(assert (not (sign/valid? "uploads/a.png" (p "exp") "AAAA" now))
        "a forged signature does not verify")
(assert (not (sign/valid? "uploads/a.png" (p "exp") "not base64url!!" now))
        "and neither does one that is not even decodable")
(assert (not (sign/valid? "uploads/a.png" nil (p "sig") now))
        "a link with no exp is not a signed link")
(assert (not (sign/valid? "uploads/a.png" "soon" (p "sig") now))
        "and neither is one whose exp is not a number")

# -- rotation ------------------------------------------------------------

(def old p)
(secret/configure! {:signing-key (string/repeat "n" 32)
                    :previous-keys [(string/repeat "k" 32)]}
                   :test)
(assert (sign/valid? "uploads/a.png" (old "exp") (old "sig") now)
        "a link signed with the previous key still verifies during a rotation")

(secret/configure! {:signing-key (string/repeat "n" 32)} :test)
(assert (not (sign/valid? "uploads/a.png" (old "exp") (old "sig") now))
        "and stops the moment the old key is dropped")

# -- what a caller may ask for -------------------------------------------

(each bad [0 -60 "600" nil]
  (def [ok _] (protect (sign/params "a.png" bad now)))
  (assert (not ok) (string/format ":expires %q is refused" bad)))

(printf "sign-test: ok")
