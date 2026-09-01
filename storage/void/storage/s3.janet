### void/storage-s3 — the S3-compatible store (ADR-0039 §4).
###
### One bucket behind an endpoint, spoken to with void's own stack and
### nothing else: `http/client` carries the requests, `void/tls` makes
### an https endpoint possible (the client refuses one without it,
### naming the plugin — ADR-0038), and the SigV4 in ./sigv4 is
### `void/crypto` all the way down. No SDK, no XML: the four object
### operations and HEAD are status codes and headers, which is the
### slice of S3 a storage store needs. Listing a bucket is an XML
### document — deliberately not here until something needs it.
###
### **Path-style, on purpose.** Requests go to
### `<endpoint>/<bucket>/<key>` rather than to a bucket-named host:
### minio and every self-hosted S3 answer path-style out of the box,
### and virtual-host style would put the bucket into TLS certificates
### and DNS — a deployment concern void has no business guessing.
### AWS itself still answers path-style.
###
### **The object rides through memory.** The client's request body is
### bytes and its response is buffered; `stream` hands the whole object
### back as one chunk so callers written against the contract stay
### portable. `[:storage-s3 :max-object]` caps what a `get` will hold
### (64 MB default); past that size the answer is a presigned URL and
### the browser fetching it, not this process proxying.
###
### **A temporary URL is SigV4 query auth** — minted here, verified by
### the S3 end, no shared state with ./sign. A plain `url` needs
### `:public-url` (a CDN, or the endpoint itself when the bucket
### policy allows anonymous reads) or falls back to the endpoint
### path — what a storefront uses with a public bucket, while a
### private bucket answers only presigned links.

(import void/core/config :as config)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/http/client :as client)
(import ./key :as key)
(import ./sigv4 :as sigv4)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.storage.s3")

(def Config
  "Schema of the [:storage-s3] config slice."
  {:endpoint [:optional :string]
   :bucket [:optional :string]
   :region [:optional :string]
   # a string in dev, a {:secret "MINIO_SECRET_KEY"} reference
   # everywhere it matters — the resolved box is unwrapped at :start
   # and never printed (ADR-0007 §5). :any because a secret box is an
   # opaque table the schema layer has no name for
   :access-key [:optional :any]
   :secret-key [:optional :any]
   # where a browser reads a public object: a CDN, or the endpoint
   # itself when the bucket policy allows anonymous reads. Left out,
   # `url` without :expires answers the endpoint path
   :public-url [:optional :string]
   :timeout [:optional [:number {:min 0.001}]]
   :max-object [:optional [:int {:min 1}]]})

(def defaults
  "Defaults of the [:storage-s3] slice."
  {:region "us-east-1"
   :timeout 30
   :max-object (* 64 1024 1024)})

(defn- reveal
  "A credential out of the config: a plain string, or a resolved
  secret box."
  [what value]
  (cond
    (config/secret? value) (config/reveal value)
    (bytes? value) (string value)
    (nil? value) (errorf "storage-s3: [:storage-s3 %q] is not set" what)
    (errorf "storage-s3: [:storage-s3 %q] must be a string or a {:secret \"NAME\"} reference, got %q"
            what value)))

(defn- require-str [cfg k]
  (def v (get cfg k))
  (unless (and (string? v) (not (empty? v)))
    (errorf "storage-s3: [:storage-s3 %q] must be set (a minio on a laptop is {:endpoint \"http://127.0.0.1:9000\" :bucket \"...\"})" k))
  v)

(defn make
  ``The store table for one [:storage-s3] slice: the parsed endpoint,
  the client, the revealed credentials. Parsing the endpoint is the
  https gate — a composition without void/tls is refused here, at
  :start, with the plugin named (ADR-0038).``
  [cfg0]
  (def cfg (merge defaults (or cfg0 {})))
  (def endpoint (require-str cfg :endpoint))
  (def bucket (require-str cfg :bucket))
  (def u (client/parse-url endpoint))
  (unless (= "/" (u :target))
    (errorf "storage-s3: [:storage-s3 :endpoint] carries a path (%q) — it names a server; the bucket has its own key" (u :target)))
  (def c (client/open {:url endpoint
                       :timeout (cfg :timeout)
                       :max-body (cfg :max-object)}))
  @{:client c
    :scheme (u :scheme)
    :authority (c :authority)
    :bucket bucket
    :region (cfg :region)
    :access-key (reveal :access-key (cfg :access-key))
    :secret-key (reveal :secret-key (cfg :secret-key))
    :public-url (when-let [p (cfg :public-url)] (string/trimr p "/"))
    :max-object (cfg :max-object)})

(defn- object-path [s k]
  # raw, then encoded once by canonical-path — the same string is
  # signed and sent, which is the whole trick of getting SigV4 right
  (sigv4/canonical-path (string "/" (s :bucket) "/" k)))

(defn- request!
  "One signed request. Returns the client response, whatever the
  status — the operations decide what a 404 means."
  [s method k &opt opts]
  (default opts {})
  (def path (object-path s k))
  (def date (sigv4/amz-date (os/time)))
  (def payload-hash (sigv4/hashed-payload (opts :body)))
  (def headers @{"host" (s :authority)
                 "x-amz-date" date
                 "x-amz-content-sha256" payload-hash})
  (when-let [ct (opts :content-type)]
    (put headers "content-type" ct))
  (put headers "authorization"
       (sigv4/authorization {:method method
                             :path path
                             :query nil
                             :headers headers
                             :payload-hash payload-hash
                             :date date
                             :region (s :region)
                             :service "s3"
                             :access-key (s :access-key)
                             :secret-key (s :secret-key)}))
  (client/send! (s :client)
                {:method method
                 :target path
                 :headers headers
                 :body (opts :body)}))

(defn- refuse
  "A non-answer from the S3 end, with the useful line of its XML body."
  [s what k resp]
  (def body (string/slice (string (or (resp :body) "")) 0
                          (min 300 (length (string (or (resp :body) ""))))))
  (errorf "storage-s3: %s %q against %s/%s answered %d%s"
          what k (s :authority) (s :bucket) (resp :status)
          (if (empty? body) "" (string " — " body))))

(defn store
  "The :void/storage-store dictionary over one `make` table."
  [s]

  (defn s3-put! [k value opts]
    (key/check! k)
    (def ct (get (or opts {}) :content-type))
    (def resp (request! s :put k {:body value :content-type ct}))
    (unless (= 200 (resp :status))
      (refuse s "PUT" k resp))
    {:key k
     :size (length value)
     :content-type ct
     :etag (client/header resp "etag")})

  (defn s3-get [k]
    (key/check! k)
    (def resp (request! s :get k))
    (case (resp :status)
      200 (resp :body)
      404 nil
      (refuse s "GET" k resp)))

  (defn s3-stream [k]
    # one chunk: the client buffers the response whole (see the module
    # docstring), and pretending otherwise here would not change that
    (when-let [bytes (s3-get k)]
      [bytes]))

  (defn s3-delete! [k]
    (key/check! k)
    # S3 answers 204 whether or not the key held anything, so "was it
    # there" costs a HEAD first — and is worth it: the contract's
    # deleted? is what lets a caller tell a cleanup from a no-op
    (def there (do (def head (request! s :head k))
                   (= 200 (head :status))))
    (def resp (request! s :delete k))
    (unless (in {200 true 204 true} (resp :status))
      (refuse s "DELETE" k resp))
    there)

  (defn s3-stat [k]
    (key/check! k)
    (def resp (request! s :head k))
    (case (resp :status)
      200 {:key k
           :size (when-let [cl (client/header resp "content-length")]
                   (scan-number (string cl)))
           :content-type (client/header resp "content-type")
           :etag (client/header resp "etag")}
      404 nil
      (refuse s "HEAD" k resp)))

  (defn s3-url [k opts]
    (key/check! k)
    (def path (object-path s k))
    (if-let [expires (get (or opts {}) :expires)]
      (do
        (unless (and (number? expires) (pos? expires))
          (errorf "storage: :expires must be a positive number of seconds, got %q" expires))
        (def q (sigv4/presign-query {:method :get
                                     :path path
                                     :host (s :authority)
                                     :date (sigv4/amz-date (os/time))
                                     :expires (math/trunc expires)
                                     :region (s :region)
                                     :service "s3"
                                     :access-key (s :access-key)
                                     :secret-key (s :secret-key)}))
        (string (s :scheme) "://" (s :authority) path "?" (sigv4/canonical-query q)))
      (if-let [public (s :public-url)]
        (string public "/" (sigv4/uri-encode k true))
        (string (s :scheme) "://" (s :authority) path))))

  @{:name :s3
    :shared? true
    :put! s3-put!
    :get s3-get
    :stream s3-stream
    :delete! s3-delete!
    :stat s3-stat
    :url s3-url
    :close (fn s3-close [] (client/close! (s :client)))})

# -- the component -------------------------------------------------------

(def s3-component
  (system/component :storage/s3
    :doc "The S3-compatible store: one bucket behind [:storage-s3
    :endpoint], SigV4 over void/crypto, requests over void/http/client
    (and void/tls when the endpoint is https). Selecting it is one
    config line — {:void/storage-store {:impl :storage/s3}} — and it is
    the line `[:deploy :shape] :fleet` asks for, because a bucket is
    what every replica sees (ADR-0030)."
    :provides [:void/storage-store]
    :config {:key :storage-s3 :schema Config}
    :start
    (fn start [_ cfg]
      (def s (make cfg))
      (log/info "storage s3 store ready" :ns log-ns
                :endpoint (string (s :scheme) "://" (s :authority))
                :bucket (s :bucket)
                :region (s :region))
      (store s))
    :stop
    (fn stop [st]
      ((st :close)))
    :health
    (fn health [_]
      {:status :up})))

(plugin/defplugin void/storage-s3
  :doc "The S3-compatible storage store: put/get/delete/stat against one bucket over void's own HTTP client with SigV4 on void/crypto, presigned temporary URLs, https through void/tls. The shared answer to [:deploy :shape] :fleet for uploads."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/storage ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :storage-s3
  :config-schema Config
  :config-defaults defaults
  :components [s3-component])
