### void/auth/jwt — JSON Web Tokens, the half that is worth having.
###
### JWS compact serialization: `header.payload.signature`, each segment
### base64url without padding. HS256/384/512 through HMAC, RS256/384/512
### and ES256/384/512 through `void/crypto/sign` — asymmetric
### verification is here from the first version because libcrypto made
### it four bindings rather than a project, and the common case for
### JWT in an application is *verifying somebody else's* token.
###
### **`alg` comes from the configuration, never from the token.** The
### two classic JWT breaks are `{"alg":"none"}` and handing an RS256
### verifier an HS256 token signed with the public key as an HMAC
### secret — both are attacks on implementations that ask the token
### which algorithm to use. `decode` is told which algorithms are
### acceptable and refuses everything else before it looks at the
### signature. There is a test for each.
###
### Claims are validated the way RFC 7519 §4.1 defines them: `exp`,
### `nbf`, `iss`, `aud`, with a configurable clock skew. A token that
### fails any of them comes back as `{:ok false :reason ...}` rather
### than as an exception: an invalid token is an ordinary event on a
### public endpoint, and the reason is for the log, never for the
### client.

(import spork/json)
(import void/crypto/digest :as digest)
(import void/crypto/encode :as encode)
(import void/crypto/ct :as ct)
(import void/crypto/sign :as sign)

(def algorithms
  ``Supported algorithms: the JWS name, how it signs, and which digest
  or signature algorithm it maps to.``
  {:hs256 {:kind :hmac :digest :sha256}
   :hs384 {:kind :hmac :digest :sha384}
   :hs512 {:kind :hmac :digest :sha512}
   :rs256 {:kind :key :sign :rs256}
   :rs384 {:kind :key :sign :rs384}
   :rs512 {:kind :key :sign :rs512}
   :es256 {:kind :key :sign :es256}
   :es384 {:kind :key :sign :es384}
   :es512 {:kind :key :sign :es512}})

(def default-leeway
  "Seconds of clock skew tolerated on exp/nbf. Small enough to matter,
  large enough that two machines with NTP never disagree."
  30)

(defn- alg-name [algo]
  (string/ascii-upper (string algo)))

(defn- alg-of [name]
  (def k (keyword (string/ascii-lower (string name))))
  (when (algorithms k) k))

(defn- spec-of [algo]
  (or (algorithms algo)
      (errorf "unknown JWT algorithm %q (have %s)" algo
              (string/join (map |(alg-name $) (sorted (keys algorithms))) " "))))

(defn- segment [value]
  (encode/base64url (json/encode value)))

(defn- signature [algo key input]
  (def spec (spec-of algo))
  (if (= :hmac (spec :kind))
    (digest/hmac (spec :digest) key input)
    (sign/sign key (spec :sign) input)))

(defn- signature-ok? [algo key input sig]
  (def spec (spec-of algo))
  (if (= :hmac (spec :kind))
    (ct/equal? sig (digest/hmac (spec :digest) key input))
    (sign/verify key (spec :sign) input sig)))

(defn encode-token
  ``Sign claims into a JWT. Options:

    :alg      :hs256 (default) .. :es512
    :key      HMAC secret (bytes) or a void/crypto key object
    :ttl      seconds — sets `exp` from now
    :issuer   sets `iss`
    :audience sets `aud`
    :subject  sets `sub`
    :kid      key id, into the header, for a verifier with several keys

  `iat` is always set: a token whose age cannot be told is a token
  that cannot be rotated.``
  [claims &opt opts]
  (default opts {})
  (def algo (get opts :alg :hs256))
  (spec-of algo)
  (def key (or (opts :key) (error "jwt/encode needs a :key")))
  (def now (get opts :now (os/time)))
  (def header
    (merge {:alg (alg-name algo) :typ "JWT"}
           (if-let [kid (opts :kid)] {:kid kid} {})))
  (def payload
    (merge
      (table ;(kvs claims))
      {:iat now}
      (if-let [ttl (opts :ttl)] {:exp (+ now ttl)} {})
      (if-let [iss (opts :issuer)] {:iss iss} {})
      (if-let [aud (opts :audience)] {:aud aud} {})
      (if-let [sub (opts :subject)] {:sub sub} {})))
  (def input (string (segment header) "." (segment payload)))
  (string input "." (encode/base64url (signature algo key input))))

(defn peek
  ``The header and payload of a token **without verifying anything** —
  for picking a key by `kid` before the signature is checked. Never
  trust what it returns: that is the entire point of the signature.``
  [token]
  (def parts (string/split "." (string token)))
  (unless (= 3 (length parts)) (break nil))
  (def [ok header] (protect (json/decode (encode/base64url-decode (parts 0)) true)))
  (def [ok2 payload] (protect (json/decode (encode/base64url-decode (parts 1)) true)))
  (when (and ok ok2) {:header header :claims payload}))

(defn decode-token
  ``Verify a token and its claims. Returns `{:ok true :claims :header}`
  or `{:ok false :reason "..."}` — the reason is for the log, not for
  the client.

  Options:

    :alg       the algorithm, or a list of acceptable ones. **The
               token's own `alg` header is only ever compared against
               this**, never obeyed.
    :key       HMAC secret or key object; or :keys, a table of kid -> key
    :issuer    required `iss`, when given
    :audience  required `aud`, when given
    :leeway    clock skew in seconds (default 30)
    :now       for tests``
  [token &opt opts]
  (default opts {})
  (def accepted
    (let [a (get opts :alg :hs256)]
      (if (indexed? a) a [a])))
  (each a accepted (spec-of a))
  (def leeway (get opts :leeway default-leeway))
  (def now (get opts :now (os/time)))
  (def parts (string/split "." (string token)))
  (defn no [reason] {:ok false :reason reason})
  (cond
    (not= 3 (length parts)) (no "not three segments")

    (let [[ok header] (protect (json/decode (encode/base64url-decode (parts 0)) true))]
      (cond
        (not ok) (no "header is not base64url JSON")

        (let [named (alg-of (get header :alg ""))]
          (cond
            (nil? named)
            # this is where {"alg":"none"} dies, and it dies before any
            # signature work happens
            (no (string/format "unsupported alg %q" (get header :alg)))

            (not (index-of named accepted))
            # and this is where RS256 -> HS256 substitution dies: the
            # verifier was told what to accept and the token does not
            # get a vote
            (no (string/format "alg %q is not accepted here" (get header :alg)))

            (let [key (if-let [keys (opts :keys)]
                        (get keys (get header :kid))
                        (opts :key))]
              (cond
                (nil? key) (no "no key for this token")

                (let [input (string (parts 0) "." (parts 1))
                      [ok-sig sig] (protect (encode/base64url-decode (parts 2)))]
                  (cond
                    (not ok-sig) (no "signature is not base64url")

                    (not (signature-ok? named key input sig)) (no "signature does not verify")

                    (let [[ok-p payload]
                          (protect (json/decode (encode/base64url-decode (parts 1)) true))]
                      (cond
                        (not ok-p) (no "payload is not base64url JSON")
                        (not (dictionary? payload)) (no "payload is not an object")

                        (and (payload :exp) (< (+ (payload :exp) leeway) now)) (no "expired")
                        (and (payload :nbf) (> (- (payload :nbf) leeway) now)) (no "not valid yet")

                        (and (opts :issuer) (not= (payload :iss) (opts :issuer)))
                        (no "wrong issuer")

                        (and (opts :audience)
                             (let [aud (payload :aud)]
                               (not (if (indexed? aud)
                                      (index-of (opts :audience) aud)
                                      (= aud (opts :audience))))))
                        (no "wrong audience")

                        {:ok true :claims payload :header header}))))))))))))
