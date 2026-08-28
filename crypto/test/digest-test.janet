(import ../test-support/paths)
(import void/crypto/lib :as lib)
(import void/crypto/digest :as digest)
(import void/crypto/encode :as encode)

(lib/load!)

(defn- hex-of [algo data] (encode/hex (digest/digest algo data)))

# -- FIPS 180-4 / RFC 6234 vectors ---------------------------------------

(assert (= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
           (hex-of :sha256 "")))
(assert (= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
           (hex-of :sha256 "abc")))
(assert (= (string "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
           (hex-of :sha256 "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")))
(assert (= (string "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed"
                   "8086072ba1e7cc2358baeca134c825a7")
           (hex-of :sha384 "abc")))
(assert (= (string "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a"
                   "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
           (hex-of :sha512 "abc")))
(assert (= "a9993e364706816aba3e25717850c26c9cd0d89d" (hex-of :sha1 "abc"))
        "SHA-1 is here for TOTP (RFC 6238 fixed it) and for nothing void stores")

# -- shapes --------------------------------------------------------------

(each [algo size] (pairs digest/sizes)
  (assert (= size (length (digest/digest algo "x")))
          (string/format "%q is %d raw bytes" algo size)))

(assert (= (digest/sha256 "abc") (digest/digest :sha256 "abc")))
(assert (= (digest/sha256 "abc") (digest/sha256 @"abc")) "buffers hash like strings")
(assert (not= (digest/sha256 "abc") (digest/sha256 "abd")))

(def [ok err] (protect (digest/digest :sha3 "x")))
(assert (not ok) "an unknown digest is an error")
(assert (string/find "sha256" (string err)) "and the message lists what there is")

# -- HMAC, RFC 4231 ------------------------------------------------------

(def case1-key (string/repeat "\x0b" 20))
(assert (= "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
           (encode/hex (digest/hmac-sha256 case1-key "Hi There"))))
(assert (= (string "afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59c"
                   "faea9ea9076ede7f4af152e8b2fa9cb6")
           (encode/hex (digest/hmac :sha384 case1-key "Hi There"))))
(assert (= (string "87aa7cdea5ef619d4ff0b4241a1d6cb02379f4e2ce4ec2787ad0b30545e17cde"
                   "daa833b7d6b8a702038b274eaea3f4e4be9d914eeb61f1702e696c203a126854")
           (encode/hex (digest/hmac :sha512 case1-key "Hi There"))))

(assert (= "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
           (encode/hex (digest/hmac-sha256 "Jefe" "what do ya want for nothing?"))))

# case 6: a key longer than the block size is hashed first — the branch
# most hand-written HMACs get wrong
(assert (= "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
           (encode/hex (digest/hmac-sha256
                         (string/repeat "\xaa" 131)
                         "Test Using Larger Than Block-Size Key - Hash Key First"))))

(assert (= 32 (length (digest/hmac-sha256 "k" "m"))) "raw bytes, never hex")
(assert (not= (digest/hmac-sha256 "k1" "m") (digest/hmac-sha256 "k2" "m")))

(print "digest-test ok")
