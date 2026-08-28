(import ../test-support/paths)
(import void/crypto/encode :as encode)

# -- base64url (RFC 4648 §5) ---------------------------------------------

(assert (= "" (encode/base64url "")))
(assert (= "Zg" (encode/base64url "f")) "no padding — a token is not a MIME body")
(assert (= "Zm8" (encode/base64url "fo")))
(assert (= "Zm9v" (encode/base64url "foo")))

# the two characters that make it URL-safe, and the whole reason this
# module exists rather than a call to spork's encoder
(assert (= "-_-_" (encode/base64url "\xfb\xff\xbf")))
(assert (nil? (string/find "+" (encode/base64url "\xfb\xff\xbf"))))
(assert (nil? (string/find "/" (encode/base64url "\xfb\xff\xbf"))))

(each s ["" "f" "fo" "foo" "foob" "fooba" "foobar" "\x00\x01\xfe\xff"]
  (assert (= s (encode/base64url-decode (encode/base64url s)))
          (string/format "round trip: %q" s)))

(assert (= "\xfb\xff\xbf" (encode/base64url-decode "-_-_")))
(assert (= "foo" (encode/base64url-decode "Zm9v")))
(assert (= "fo" (encode/base64url-decode "Zm8=")) "padding is accepted on the way in — other stacks send it")

(def [ok] (protect (encode/base64url-decode "Z")))
(assert (not ok) "one character is not a valid base64 length")

# -- base64 with the standard alphabet (what PHC strings carry) ----------

(assert (= "Zm9v" (encode/base64 "foo")))
(assert (= "Zm8" (encode/base64 "fo")) "no padding — an = inside a $-separated PHC field is what other stacks choke on")
(assert (= "+/+/" (encode/base64 "\xfb\xff\xbf")) "the standard alphabet, not the URL-safe one")
(each s ["" "f" "fo" "foo" "foob" "\x00\xfe\xff"]
  (assert (= s (encode/base64-decode (encode/base64 s)))))
(assert (= "fo" (encode/base64-decode "Zm8=")) "padding accepted on the way in")

# -- hex -----------------------------------------------------------------

(assert (= "" (encode/hex "")))
(assert (= "00ff10" (encode/hex "\x00\xff\x10")))
(assert (= "\x00\xff\x10" (encode/unhex "00ff10")))
(assert (= "deadbeef" (encode/hex (encode/unhex "deadbeef"))))

(each bad ["0" "abc" "zz"]
  (def [ok] (protect (encode/unhex bad)))
  (assert (not ok) (string/format "%q is not hex" bad)))

(print "encode-test ok")
