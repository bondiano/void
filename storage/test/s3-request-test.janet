# The half sigv4-test cannot pin and s3-test only pins when a minio is
# around: that what the store *signs* is what it *sends*. void's own
# http server stands in for the bucket, records the raw request target
# and headers, and the test then verifies the signature the way an S3
# end does — decode the target, canonicalize once, recompute. The key
# deliberately carries a space and a cyrillic word: exactly the bytes
# the double-encoding bug (sign `%2520`, send `%20`) turned into 403
# SignatureDoesNotMatch on every store but the one whose keys were all
# unreserved ASCII.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/crypto :as crypto)
(import void/http/ring :as ring)
(import void/http/server :as server)
(import void/storage/s3 :as s3)
(import void/storage/sigv4 :as sigv4)
(import void/storage/store :as store)

(log/set-level! "void" :error)
(crypto/load!)

(def access "AKIDEXAMPLE")
(def secret "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")

(defn- percent-decode
  # what a server does to the target before canonicalizing it again
  [s]
  (def out @"")
  (var i 0)
  (while (< i (length s))
    (def c (s i))
    (if (= c (chr "%"))
      (do (buffer/push-byte out (scan-number (string "0x" (string/slice s (inc i) (+ i 3)))))
          (+= i 3))
      (do (buffer/push-byte out c) (++ i))))
  (string out))

(var captured nil)

(def inst (server/start {:handler (fn fake-s3 [req]
                                    (set captured @{:method (req :method)
                                                    :path (req :path)
                                                    :headers (freeze (req :headers))})
                                    (ring/text 200 "ok"))
                         :port "0"
                         :idle-timeout 0.4}))

(def st (store/normalize
          (s3/store (s3/make {:endpoint (string "http://127.0.0.1:" (inst :port))
                              :bucket "shop"
                              :access-key access
                              :secret-key secret}))))

(def key "uploads/весенний прайс 2026.png")
(def raw-path (string "/shop/" key))

(defn- verify!
  # an S3 end's half of the handshake: take what arrived on the wire,
  # decode the target, rebuild the canonical request over the signed
  # headers, and demand the same Authorization — byte for byte
  [what]
  (def h (captured :headers))
  (def date (h "x-amz-date"))
  (def payload-hash (h "x-amz-content-sha256"))
  (def signed @{"host" (h "host")
                "x-amz-date" date
                "x-amz-content-sha256" payload-hash})
  (when-let [ct (h "content-type")] (put signed "content-type" ct))
  (def expect (sigv4/authorization {:method (captured :method)
                                    :path (percent-decode (captured :path))
                                    :query nil
                                    :headers signed
                                    :payload-hash payload-hash
                                    :date date
                                    :region "us-east-1"
                                    :service "s3"
                                    :access-key access
                                    :secret-key secret}))
  (assert (= expect (h "authorization"))
          (string what ": the signature the wire carries is the one its own bytes produce")))

(defer (do ((st :close)) (server/stop inst))

  # -- a GET signs what it sends -----------------------------------------

  (assert (= "ok" (string ((st :get) key))))
  (assert (= (sigv4/canonical-path raw-path) (captured :path))
          "the target is the canonical path — encoded exactly once")
  (assert (nil? (string/find "%25" (captured :path)))
          "no %25 on the wire: an encoded encoding is the bug this test pins")
  (verify! "GET")

  # -- and so does a PUT with a body and a content type ------------------

  ((st :put!) key "PNG-BYTES" {:content-type "image/png"})
  (assert (= :put (captured :method)))
  (assert (= (crypto/hex (crypto/sha256 "PNG-BYTES"))
             (get-in captured [:headers "x-amz-content-sha256"]))
          "the payload hash is the body's")
  (verify! "PUT")

  # -- a presigned URL minted for the same key ---------------------------

  (def signed-url ((st :url) key {:expires 300}))
  (def qpos (string/find "?" signed-url))
  (def url-path (string/slice signed-url (length (string "http://127.0.0.1:" (inst :port))) qpos))
  (assert (= (sigv4/canonical-path raw-path) url-path)
          "the URL's path is encoded exactly once too")
  (def params
    (tabseq [pair :in (string/split "&" (string/slice signed-url (inc qpos)))]
      (percent-decode (first (string/split "=" pair)))
      (percent-decode (get (string/split "=" pair) 1))))
  (def again (sigv4/presign-query {:method :get
                                   :path (percent-decode url-path)
                                   :host (string "127.0.0.1:" (inst :port))
                                   :date (params "X-Amz-Date")
                                   :expires 300
                                   :region "us-east-1"
                                   :service "s3"
                                   :access-key access
                                   :secret-key secret}))
  (assert (= (params "X-Amz-Signature") (again "X-Amz-Signature"))
          "a verifier that decodes the path and canonicalizes once agrees with the minted signature")

  # -- and a presigned URL does not outlive the cap ----------------------

  (def [ok err] (protect ((st :url) key {:expires (* 8 24 3600)})))
  (assert (not ok) "an :expires over [:storage-s3 :presign-max-expires] is refused")
  (assert (string/find ":presign-max-expires" (string err)) "by name"))

(printf "s3-request-test: ok")
