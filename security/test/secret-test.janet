(import ../test-support/paths)
(import void/core/log :as log)
(import void/crypto :as crypto)
(import void/security/secret :as secret)

(log/set-level! "void.security.secret" :error)
(crypto/load!)

# -- dev generates, prod refuses -----------------------------------------

(assert (= 1 (secret/configure! {} :dev)) "dev generates an ephemeral key")
(assert (not (secret/rotated?)))
(def generated (secret/sign "x"))
(secret/configure! {} :dev)
(assert (not= generated (secret/sign "x"))
        "and a new one every boot — which is exactly why prod must not do this")

(def [ok err] (protect (secret/configure! {} :prod)))
(assert (not ok) "in production a missing key stops the boot")
(each part ["VOID_SECRET" "prefork" "signing-key"] (assert (string/find part (string err)) part))

# -- signing and verifying -----------------------------------------------

(def key1 (string/repeat "k" 32))
(def key2 (string/repeat "j" 32))
(secret/configure! {:signing-key key1} :prod)
(def mac (secret/sign "message"))
(assert (secret/valid? "message" mac))
(assert (not (secret/valid? "other" mac)) "a different message does not verify")
(assert (not (secret/valid? "message" (secret/sign "other"))))

# -- rotation ------------------------------------------------------------

(secret/configure! {:signing-key key2 :previous-keys [key1]} :prod)
(assert (secret/rotated?))
(assert (secret/valid? "message" mac)
        "a token signed with the previous key still verifies — that is the whole of rotation")
(def fresh (secret/sign "message"))
(assert (not= fresh mac) "and new ones are signed with the new key")

(secret/configure! {:signing-key key2} :prod)
(assert (not (secret/valid? "message" mac))
        "dropping the old key retires every token it signed")

# an env reference resolves through the config layer's secret box
(assert (= 1 (secret/configure! {:signing-key key1} :prod)))

(print "secret-test ok")
