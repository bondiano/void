# Is there an S3-compatible server to test the bucket store against?
#
# Everything that can be tested without one is (the key rules, the
# contract, the disk store, the upload seam, the signing, and SigV4
# itself against AWS's published vectors), and it runs everywhere. What
# needs a real server is the half no vector can check: that a signature
# this code produced is a signature the *other end* accepts. So the
# suite asks for a server by name, the way void/cache asks for a redis:
#
#     docker run -d -p 9000:9000 -e MINIO_ROOT_USER=void \
#       -e MINIO_ROOT_PASSWORD=void-void-void minio/minio server /data
#     VOID_TEST_S3="http://127.0.0.1:9000" \
#     VOID_TEST_S3_KEY=void VOID_TEST_S3_SECRET=void-void-void jpm test
#
# The bucket is created by the suite if the server lets it, and every
# object goes under a prefix carrying this process's pid — nothing here
# empties a bucket, because the bucket named may be someone's.

(def env-var "VOID_TEST_S3")

(defn endpoint
  "The configured server, or nil."
  []
  (when-let [v (os/getenv env-var)]
    (unless (empty? (string/trim v)) (string/trim v))))

(defn available?
  "Is there a server to test against?"
  []
  (not (nil? (endpoint))))

(defn config
  "The [:storage-s3] slice for it."
  []
  {:endpoint (endpoint)
   :bucket (or (os/getenv "VOID_TEST_S3_BUCKET") "void-test")
   :region (or (os/getenv "VOID_TEST_S3_REGION") "us-east-1")
   :access-key (or (os/getenv "VOID_TEST_S3_KEY") "minioadmin")
   :secret-key (or (os/getenv "VOID_TEST_S3_SECRET") "minioadmin")})

(defn skip
  "Announce a skipped suite the way a passing one announces itself, so
  a scrolled-past CI log still says which is which."
  [suite]
  (printf "%s: SKIPPED (set %s to an http:// endpoint, plus VOID_TEST_S3_KEY / _SECRET)"
          suite env-var)
  nil)

(defn prefix
  "A key prefix nothing else is using: the suite name and this process."
  [suite]
  (string "void-test/" suite "/" (os/getpid) "/"))
