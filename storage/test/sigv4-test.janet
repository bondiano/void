# SigV4 against AWS's own published vectors. Every step of the
# signature is a pure function, so every step is asserted separately:
# when a bucket answers 403 the failing line is in this file, not in a
# packet capture.
#
# The vector is the `get-vanilla-query` shape from AWS's SigV4 test
# suite, in the documented walkthrough form (Signing AWS requests,
# "Example: Signature calculation"): the IAM ListUsers request of
# 30 August 2015.

(import ../test-support/paths)
(import void/crypto :as crypto)
(import void/storage/sigv4 :as sigv4)

(crypto/load!)

(def secret "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
(def access "AKIDEXAMPLE")
(def date "20150830T123600Z")

(def headers
  {"host" "iam.amazonaws.com"
   "content-type" "application/x-www-form-urlencoded; charset=utf-8"
   "x-amz-date" date})

(def creq
  (sigv4/canonical-request {:method :get
                            :path "/"
                            :query {"Action" "ListUsers" "Version" "2010-05-08"}
                            :headers headers
                            :payload-hash (sigv4/hashed-payload "")}))

(assert (= (string "GET\n"
                   "/\n"
                   "Action=ListUsers&Version=2010-05-08\n"
                   "content-type:application/x-www-form-urlencoded; charset=utf-8\n"
                   "host:iam.amazonaws.com\n"
                   "x-amz-date:20150830T123600Z\n"
                   "\n"
                   "content-type;host;x-amz-date\n"
                   "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
           creq)
        "the canonical request is AWS's, byte for byte")

(def sts (sigv4/string-to-sign date "us-east-1" "iam" creq))
(assert (= (string "AWS4-HMAC-SHA256\n"
                   "20150830T123600Z\n"
                   "20150830/us-east-1/iam/aws4_request\n"
                   "f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59")
           sts)
        "and so is the string to sign")

(assert (= "5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7"
           (sigv4/signature secret date "us-east-1" "iam" sts))
        "and the signature the derived key produces")

(assert (= (string "AWS4-HMAC-SHA256 "
                   "Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, "
                   "SignedHeaders=content-type;host;x-amz-date, "
                   "Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
           (sigv4/authorization {:method :get :path "/"
                                 :query {"Action" "ListUsers" "Version" "2010-05-08"}
                                 :headers headers
                                 :payload-hash (sigv4/hashed-payload "")
                                 :date date :region "us-east-1" :service "iam"
                                 :access-key access :secret-key secret}))
        "which is what the Authorization header carries")

# -- the encodings that are not the kernel's -----------------------------

(assert (= "abc-_.~" (sigv4/uri-encode "abc-_.~"))
        "unreserved bytes stay bare")
(assert (= "%20" (sigv4/uri-encode " ")) "a space is %20, never a plus")
(assert (= "%2F" (sigv4/uri-encode "/")) "a slash is encoded in a value")
(assert (= "a/b" (sigv4/uri-encode "a/b" true)) "and kept in a path")
(assert (= "%E2%82%AC" (sigv4/uri-encode "€")) "utf-8 goes out byte by byte, uppercase hex")

(assert (= "/" (sigv4/canonical-path "")) "an empty path canonicalizes to /")
(assert (= "/bucket/a%20b/c.png" (sigv4/canonical-path "/bucket/a b/c.png")))

(assert (= "a=&b=2" (sigv4/canonical-query {"b" "2" "a" ""}))
        "a bare key still spells its =, and pairs are sorted by encoded key")
(assert (= "k=1&k=2" (sigv4/canonical-query {"k" ["2" "1"]}))
        "a repeated key sorts by encoded value")
(assert (= "" (sigv4/canonical-query nil)) "no query is the empty string")

# -- dates ---------------------------------------------------------------

# os/mktime's second argument is *local* — left out, this instant is
# 2015-08-30T12:36:00Z, and the assertion below stands in any timezone.
# The whole point is that a process in a westward zone must not sign
# yesterday's credential scope for an hour every night.
(def at (os/mktime {:year 2015 :month 7 :month-day 29 :hours 12 :minutes 36}))
(assert (= date (sigv4/amz-date at)) "an instant renders as YYYYMMDDTHHMMSSZ, in UTC")
(assert (= date (sigv4/amz-date (os/mktime {:year 2015 :month 7 :month-day 29
                                            :hours 12 :minutes 36})))
        "and the rendering does not depend on the machine's timezone")
(assert (= "20150830" (sigv4/datestamp date)))
(assert (= "20150830/us-east-1/s3/aws4_request" (sigv4/scope date "us-east-1" "s3")))

# -- presigned urls ------------------------------------------------------

(def q (sigv4/presign-query {:method :get
                             :path "/shop/uploads/a.png"
                             :host "minio:9000"
                             :date date
                             :expires 600
                             :region "us-east-1"
                             :service "s3"
                             :access-key access
                             :secret-key secret}))

(assert (= sigv4/algorithm (q "X-Amz-Algorithm")))
(assert (= "AKIDEXAMPLE/20150830/us-east-1/s3/aws4_request" (q "X-Amz-Credential")))
(assert (= "600" (q "X-Amz-Expires")))
(assert (= "host" (q "X-Amz-SignedHeaders"))
        "a presigned URL signs the host and nothing else — a browser sends the rest")
(assert (= 64 (length (q "X-Amz-Signature"))) "the signature is hex sha256")

# the signature covers the parameters: change one, and it is a different
# URL — which is the whole point of the scheme
(def q2 (sigv4/presign-query {:method :get :path "/shop/uploads/a.png"
                              :host "minio:9000" :date date :expires 601
                              :region "us-east-1" :service "s3"
                              :access-key access :secret-key secret}))
(assert (not= (q "X-Amz-Signature") (q2 "X-Amz-Signature"))
        "one more second of validity is a different signature")

(def q3 (sigv4/presign-query {:method :get :path "/shop/uploads/b.png"
                              :host "minio:9000" :date date :expires 600
                              :region "us-east-1" :service "s3"
                              :access-key access :secret-key secret}))
(assert (not= (q "X-Amz-Signature") (q3 "X-Amz-Signature"))
        "and so is another key")

(printf "sigv4-test: ok")
