(import ../test-support/paths)
(import void/crypto :as crypto)
(import void/crypto/encode :as encode)
(import void/crypto/sign :as sign)
# the throwaway key pairs void/crypto's signature suite already carries:
# duplicating a PEM fixture in two packages is two things to regenerate,
# and these are public by construction (see that file's header)
(import ../../crypto/test-support/keys :as keys)
(import void/auth/jwt :as jwt)

(crypto/load!)

(def secret "a-test-signing-key")

# -- HS* round trip ------------------------------------------------------

(each algo [:hs256 :hs384 :hs512]
  (def t (jwt/encode-token {:sub "user:1"} {:key secret :alg algo :ttl 60}))
  (def out (jwt/decode-token t {:key secret :alg algo}))
  (assert (out :ok) (string/format "%q round trip: %q" algo (out :reason)))
  (assert (= "user:1" (get-in out [:claims :sub])))
  (assert (pos? (get-in out [:claims :iat])) "iat is always set: a token whose age cannot be told cannot be rotated")
  (assert (= 3 (length (string/split "." t))) "compact serialization"))

# -- what a token must not decide ----------------------------------------

(def t (jwt/encode-token {:sub "user:1"} {:key secret :ttl 60}))

(def [header payload sig] (string/split "." t))
(def none-header (encode/base64url `{"alg":"none","typ":"JWT"}`))
(def none-token (string none-header "." payload "."))
(def out-none (jwt/decode-token none-token {:key secret}))
(assert (not (out-none :ok)) "alg:none does not authenticate anybody")
(assert (string/find "unsupported alg" (out-none :reason)))

# the RS256 -> HS256 substitution: a verifier configured for RS256 must
# refuse an HS256 token even when the HMAC checks out under the public
# key used as a secret
(def rsa-pub-pem keys/rsa-public)
(def forged (jwt/encode-token {:sub "user:1"} {:key rsa-pub-pem :alg :hs256 :ttl 60}))
(def rsa-key (sign/public-key rsa-pub-pem))
(def out-sub (jwt/decode-token forged {:key rsa-key :alg :rs256}))
(assert (not (out-sub :ok)) "algorithm substitution is refused before any signature work")
(assert (string/find "not accepted" (out-sub :reason)))

(assert (not ((jwt/decode-token t {:key secret :alg :hs512}) :ok))
        "and a token signed with another accepted algorithm is not accepted under this one")
(assert ((jwt/decode-token t {:key secret :alg [:hs256 :hs512]}) :ok)
        "a list of acceptable algorithms is how a rotation is done")

# -- signatures and claims -----------------------------------------------

(assert (not ((jwt/decode-token t {:key "other-key"}) :ok)))
(assert (= "signature does not verify" ((jwt/decode-token t {:key "other-key"}) :reason)))
(assert (not ((jwt/decode-token (string t "x") {:key secret}) :ok)))
(assert (not ((jwt/decode-token "not.a.jwt" {:key secret}) :ok)))
(assert (= "not three segments" ((jwt/decode-token "nope" {:key secret}) :reason)))

(def expired (jwt/encode-token {:sub "u"} {:key secret :ttl 10 :now (- (os/time) 600)}))
(assert (= "expired" ((jwt/decode-token expired {:key secret}) :reason)))
(assert ((jwt/decode-token expired {:key secret :leeway 700}) :ok)
        "leeway is what keeps two machines with slightly different clocks from arguing")

(def future (jwt/encode-token {:sub "u" :nbf (+ (os/time) 600)} {:key secret :ttl 900}))
(assert (= "not valid yet" ((jwt/decode-token future {:key secret}) :reason)))

(def issued (jwt/encode-token {:sub "u"} {:key secret :ttl 60 :issuer "void" :audience "api"}))
(assert ((jwt/decode-token issued {:key secret :issuer "void" :audience "api"}) :ok))
(assert (= "wrong issuer" ((jwt/decode-token issued {:key secret :issuer "other"}) :reason)))
(assert (= "wrong audience" ((jwt/decode-token issued {:key secret :audience "web"}) :reason)))

(def multi (jwt/encode-token {:sub "u" :aud ["api" "web"]} {:key secret :ttl 60}))
(assert ((jwt/decode-token multi {:key secret :audience "web"}) :ok)
        "aud may be a list, and membership is the test")

# -- key ids -------------------------------------------------------------

(def kidded (jwt/encode-token {:sub "u"} {:key secret :ttl 60 :kid "k2"}))
(assert (= "k2" (get-in (jwt/peek kidded) [:header :kid])) "peek reads the header without verifying")
(assert ((jwt/decode-token kidded {:keys {"k2" secret}}) :ok) "a keyring is selected by kid")
(assert (= "no key for this token" ((jwt/decode-token kidded {:keys {"k9" secret}}) :reason)))

# -- asymmetric ----------------------------------------------------------

(def rsa-priv (sign/private-key keys/rsa-private))
(def rsa-pub (sign/public-key keys/rsa-public))
(def rt (jwt/encode-token {:sub "user:2"} {:key rsa-priv :alg :rs256 :ttl 60}))
(def rout (jwt/decode-token rt {:key rsa-pub :alg :rs256}))
(assert (rout :ok) (get rout :reason))
(assert (= "user:2" (get-in rout [:claims :sub])))

(def ec-priv (sign/private-key keys/ec-private))
(def ec-pub (sign/public-key keys/ec-public))
(def et (jwt/encode-token {:sub "user:3"} {:key ec-priv :alg :es256 :ttl 60}))
(assert ((jwt/decode-token et {:key ec-pub :alg :es256}) :ok))
(assert (not ((jwt/decode-token et {:key ec-pub :alg :es256 :now (+ (os/time) 600)}) :ok)))

(each k [rsa-priv rsa-pub ec-priv ec-pub rsa-key] (sign/free-key k))

(print "jwt-test ok")
