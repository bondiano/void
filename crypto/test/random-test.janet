(import ../test-support/paths)
(import void/crypto/random :as random)

(assert (= 32 (length (random/bytes))) "256 bits is the size nobody has to think about")
(assert (= 8 (length (random/bytes 8))))

(each bad [0 -1 1.5]
  (def [ok] (protect (random/bytes bad)))
  (assert (not ok) (string/format "%q is not a byte count" bad)))

# uniqueness is not randomness, but a generator that repeats is broken
(def seen @{})
(for i 0 200 (put seen (random/token) true))
(assert (= 200 (length seen)) "200 tokens, 200 distinct values")

(def t (random/token))
(assert (= 43 (length t)) "32 bytes of base64url, unpadded")
(assert (nil? (string/find "=" t)))
(assert (nil? (string/find "+" t)))
(assert (nil? (string/find "/" t)))
(assert (= 22 (length (random/token 16))))

(assert (= 64 (length (random/hex-token))) "hex doubles the length")

# -- one-time codes ------------------------------------------------------

(assert (= 6 (length (random/digits))))
(assert (= 8 (length (random/digits 8))))
(each c (random/digits 32)
  (assert (and (>= c (chr "0")) (<= c (chr "9"))) "digits are digits"))

(each bad [0 33 -1]
  (def [ok] (protect (random/digits bad)))
  (assert (not ok) (string/format "%q digits is not a code" bad)))

# rejection sampling, not modulo: over 6000 digits every value should
# appear, and none should be half again as common as another. `(% b 10)`
# over a byte would make 0-5 about 20% more likely than 6-9, which this
# margin catches without being flaky
(def counts (array/new-filled 10 0))
(for i 0 600
  (each c (random/digits 10)
    (update counts (- c (chr "0")) inc)))
(def total (sum counts))
(assert (= 6000 total))
(each n counts
  (assert (pos? n) "every digit occurs")
  (assert (< (math/abs (- n 600)) 120)
          (string/format "digit counts stay near uniform (got %d of 6000, expected ~600)" n)))

(print "random-test ok")
