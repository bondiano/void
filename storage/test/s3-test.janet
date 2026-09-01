### The bucket store against a real S3-compatible server (minio in CI),
### which is the half `test/sigv4-test.janet` cannot check: AWS's
### vectors prove the signature is the one the specification describes,
### and only a server proves it is the one a server accepts.
###
### It is worth the service. The first version of this store signed
### correct-looking requests that every bucket answered
### `RequestTimeTooSkewed`, because `os/date`'s second argument is
### *local* rather than UTC — a mistake no unit test written in the
### same timezone as its author would have caught, and one this suite
### catches on the first PUT.
###
### Skipped, loudly, without VOID_TEST_S3 (see ../test-support/s3).

(import ../test-support/paths)
(import ../test-support/s3 :as s3env)
(import void/core/log :as log)
(import void/crypto :as crypto)
(import void/http/client :as client)
(import void/storage :as storage)
(import void/storage/state :as state)
(import void/storage/s3 :as s3)
(import void/storage/store :as store)

(log/set-level! "void" :error)

(defn- run []
  (crypto/load!)
  (def st (store/normalize (s3/store (s3/make (s3env/config)))))
  (def prefix (s3env/prefix "s3"))
  (def key (string prefix "products/a.png"))
  (def body (string "PNG-BYTES-" (string/repeat "x" 200)))

  (defer (do ((st :delete!) key) ((st :close)))

    # -- put, and what the server says it stored -------------------------

    (def meta ((st :put!) key body {:content-type "image/png"}))
    (assert (= key (meta :key)))
    (assert (= (length body) (meta :size)))
    (assert (meta :etag) "the server's etag rides back on the metadata")

    (assert (= body (string ((st :get) key)))
            "a signature this code produced is one the server accepted")

    (def stat ((st :stat) key))
    (assert (= (length body) (stat :size)) "HEAD answers the size")
    (assert (= "image/png" (stat :content-type))
            "and the content type the upload declared")

    (assert (= body (string/join (seq [c :in ((st :stream) key)] (string c))))
            "the stream hands over the whole object")

    # -- what is not there ------------------------------------------------

    (def missing (string prefix "products/none.png"))
    (assert (nil? ((st :get) missing)) "a missing key reads as nil, not as an error")
    (assert (nil? ((st :stat) missing)))
    (assert (not ((st :delete!) missing))
            "and deleting it answers false — S3 answers 204 either way, so the store asks")

    # -- a presigned URL is checked by the other end ---------------------

    (def signed ((st :url) key {:expires 300}))
    (assert (string/find "X-Amz-Signature=" signed))
    (def resp (client/request {:url signed}))
    (assert (= 200 (resp :status))
            (string "the server verified our presigned URL: " (resp :status)))
    (assert (= body (string (resp :body))))

    # the signature covers the key: point the same signature at another
    # object and the server refuses it
    (def other (string/replace "a.png" "b.png" signed))
    (assert (>= ((client/request {:url other}) :status) 400)
            "a presigned URL edited to name another object does not open it")

    # -- delete ------------------------------------------------------------

    (assert ((st :delete!) key) "deleting what is there answers true")
    (assert (nil? ((st :get) key)))

    # -- what it declares about replicas ----------------------------------

    (assert (store/shared? st) "a bucket is what every replica sees (ADR-0030)"))

  (printf "s3-test: ok (%s)" (s3env/endpoint)))

(if (s3env/available?)
  (run)
  (s3env/skip "s3-test"))
