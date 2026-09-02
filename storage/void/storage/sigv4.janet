### void/storage/sigv4 — AWS Signature Version 4, as pure functions
### (ADR-0039 §4).
###
### The whole scheme is deterministic string assembly over
### `crypto/hmac-sha256` and `crypto/sha256`, which is why this module
### has no I/O and no state: every step — canonical request, string to
### sign, signing key, signature — is a function a test asserts on
### against AWS's own published vectors (test/sigv4-test.janet). The
### s3 store (./s3) is the only caller today, but nothing here knows
### about buckets: SigV4 signs any AWS-shaped API.
###
### Two encodings that look like the kernel's and are not: the
### canonical *path* keeps its slashes and the canonical *query*
### spells `k=` for a bare key and sorts by encoded key then encoded
### value — both stricter than wire/encode-query, so they are written
### here rather than borrowed and bent.

(import void/crypto :as crypto)

(def algorithm "AWS4-HMAC-SHA256")

(def unsigned-payload
  "The payload hash of a presigned URL: the bytes are not known when
  the URL is minted, and S3 accepts exactly this marker in their
  place."
  "UNSIGNED-PAYLOAD")

(def- unreserved
  # RFC 3986 unreserved — the only bytes SigV4 leaves bare
  (do
    (def t @{})
    (loop [c :range-to [(chr "a") (chr "z")]] (put t c true))
    (loop [c :range-to [(chr "A") (chr "Z")]] (put t c true))
    (loop [c :range-to [(chr "0") (chr "9")]] (put t c true))
    (each c [(chr "-") (chr "_") (chr ".") (chr "~")] (put t c true))
    (freeze t)))

(defn uri-encode
  "Percent-encode for SigV4: unreserved bytes bare, everything else
  %XX with uppercase hex. `keep-slash` leaves / alone (path segments)."
  [s &opt keep-slash]
  (def out @"")
  (each c (string s)
    (cond
      (in unreserved c) (buffer/push-byte out c)
      (and keep-slash (= c (chr "/"))) (buffer/push-byte out c)
      (buffer/format out "%%%02X" c)))
  (string out))

(defn canonical-path
  "The canonical URI: the path with each segment percent-encoded and
  the slashes kept; \"/\" for an empty path."
  [path]
  (def p (string path))
  (if (empty? p) "/" (uri-encode p true)))

(defn canonical-query
  ``The canonical query string out of a params dictionary
  (string/keyword keys; a value may be an indexed of values): every key
  and value percent-encoded, `k=` even for an empty value, pairs sorted
  by encoded key then encoded value.``
  [params]
  (def pairs @[])
  (eachp [k v] (or params {})
    (def ek (uri-encode (string k)))
    (each one (if (indexed? v) v [v])
      (array/push pairs [ek (uri-encode (string (if (true? one) "" one)))])))
  (string/join (seq [[k v] :in (sorted pairs)] (string k "=" v)) "&"))

(defn hashed-payload
  "Lowercase hex sha256 of the request body (\"\" for none)."
  [body]
  (crypto/hex (crypto/sha256 (or body ""))))

(defn- collapse-ws
  # SigV4 canonicalizes a header value by trimming it and collapsing
  # every internal run of whitespace to one space — a value the far
  # end normalizes differently is a signature that does not match
  [s]
  (string (peg/replace-all ~(some (set " \t")) " " s)))

(defn- header-lines
  "[[lower-name trimmed-and-collapsed-value] ...] sorted by name."
  [headers]
  (sorted-by first
             (seq [[k v] :pairs (or headers {})]
               [(string/ascii-lower (string k)) (collapse-ws (string/trim (string v)))])))

(defn signed-headers
  "The SignedHeaders list: sorted lowercase names joined with ;."
  [headers]
  (string/join (map first (header-lines headers)) ";"))

(defn canonical-request
  "The canonical request string of {:method :path :query :headers
  :payload-hash}."
  [req]
  (string/join
    [(string/ascii-upper (string (get req :method :get)))
     (canonical-path (req :path))
     (canonical-query (req :query))
     (string/join (seq [[k v] :in (header-lines (req :headers))]
                    (string k ":" v "\n"))
                  "")
     (signed-headers (req :headers))
     (or (req :payload-hash) (hashed-payload nil))]
    "\n"))

(defn amz-date
  ``An os/time instant as SigV4 spells it: YYYYMMDDTHHMMSSZ. UTC, and
  that is not a preference: the scope carries the date, so a process
  in a westward zone would sign yesterday's credential for an hour
  every night.``
  [time]
  # `os/date`'s second argument is *local*, not UTC — left out, the
  # struct is UTC, which is the only thing this may render
  (def d (os/date time))
  (string/format "%04d%02d%02dT%02d%02d%02dZ"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))

(defn datestamp
  "The date half of `amz-date`: YYYYMMDD."
  [date]
  (string/slice date 0 8))

(defn scope
  "The credential scope: date/region/service/aws4_request."
  [date region service]
  (string (datestamp date) "/" region "/" service "/aws4_request"))

(defn string-to-sign
  "What the derived key actually signs."
  [date region service creq]
  (string algorithm "\n"
          date "\n"
          (scope date region service) "\n"
          (crypto/hex (crypto/sha256 creq))))

(defn signing-key
  "The derived key: HMAC chain from the secret through date, region
  and service. Raw bytes."
  [secret date region service]
  (def k-date (crypto/hmac-sha256 (string "AWS4" secret) (datestamp date)))
  (def k-region (crypto/hmac-sha256 k-date region))
  (def k-service (crypto/hmac-sha256 k-region service))
  (crypto/hmac-sha256 k-service "aws4_request"))

(defn signature
  "Lowercase hex signature of one string-to-sign."
  [secret date region service sts]
  (crypto/hex (crypto/hmac-sha256 (signing-key secret date region service) sts)))

(defn authorization
  ``The Authorization header for a request. `req` is canonical-request's
  input plus :date (amz-date), :region, :service, :access-key,
  :secret-key. The caller has already put `host`, `x-amz-date` and
  `x-amz-content-sha256` into :headers — what is signed is what is
  sent.``
  [req]
  (def creq (canonical-request req))
  (def sts (string-to-sign (req :date) (req :region) (req :service) creq))
  (string algorithm
          " Credential=" (req :access-key) "/"
          (scope (req :date) (req :region) (req :service))
          ", SignedHeaders=" (signed-headers (req :headers))
          ", Signature=" (signature (req :secret-key) (req :date)
                                    (req :region) (req :service) sts)))

(defn presign-query
  ``The query parameters of a presigned URL (query auth, ADR-0039 §5):
  X-Amz-Algorithm/-Credential/-Date/-Expires/-SignedHeaders plus the
  computed X-Amz-Signature. `req`: :method :path :date :expires
  :region :service :access-key :secret-key and :host (the one signed
  header). The payload rides as UNSIGNED-PAYLOAD — the URL is minted
  before the bytes exist, and S3's contract says exactly this marker.``
  [req]
  (def base
    {"X-Amz-Algorithm" algorithm
     "X-Amz-Credential" (string (req :access-key) "/"
                                (scope (req :date) (req :region) (req :service)))
     "X-Amz-Date" (req :date)
     "X-Amz-Expires" (string (req :expires))
     "X-Amz-SignedHeaders" "host"})
  (def creq (canonical-request {:method (req :method)
                                :path (req :path)
                                :query base
                                :headers {"host" (req :host)}
                                :payload-hash unsigned-payload}))
  (def sts (string-to-sign (req :date) (req :region) (req :service) creq))
  (merge base
         {"X-Amz-Signature" (signature (req :secret-key) (req :date)
                                       (req :region) (req :service) sts)}))
