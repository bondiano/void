### void/storage/local — the disk store.
###
### The default backend, and the one `void new && void dev` starts
### with: a root directory, keys as relative paths under it, nothing to
### install. Three decisions worth stating.
###
### **A write is a rename.** `put!` writes to a `.tmp.<random>` sibling
### and `os/rename`s it into place: a reader never sees half an upload,
### and a crash leaves a tmp file to sweep rather than a truncated
### object being served with a 200. Rename is atomic on one filesystem,
### which a sibling guarantees.
###
### **File I/O is blocking, and this module inherits the kernel's
### position on it.** void/http/static slurps the file it serves;
### `get`/`put!` here do the same, and `stream` reads 64 KB at a time —
### bounded slices of blocking work between yields, the same budget a
### template render costs. When void grows a readiness-based file story
### it lands in the kernel first, and this module follows it.
###
### **`url` is a relative URL, and only when there is a route.** The
### local store serves through void/storage-http (the existing static
### machinery: etag, range); its URL is `[:storage :serve :prefix]` + the
### encoded key, plus `exp`/`sig` query parameters when the caller asked
### for a temporary one (./sign). A composition without void/storage-http
### still stores and reads files — `url` answering a path nothing serves
### would be a lie, so without the serve prefix it is nil.

(import void/http/static :as static)
(import void/http/wire :as wire)
(import ./key :as key)
(import ./sign :as sign)

(defn- mkdirs!
  {:params [:string] :ret :string :throws [:string]}
  "Create every missing directory on the way to `dir`."
  [dir]
  (var built (if (string/has-prefix? "/" dir) "/" ""))
  (each seg (string/split "/" dir)
    (unless (empty? seg)
      (set built (string built (if (or (= "/" built) (empty? built)) "" "/") seg))
      (os/mkdir built)))
  (unless (= :directory (os/stat dir :mode))
    (errorf "storage: cannot create directory %s" dir))
  dir)

(defn- path-of
  {:params [:string :string] :ret :string}
  "The filesystem path for `k` under `root`. The key is validated at
  the contract boundary (key/check!), so a plain join cannot climb —
  the same property static/safe-join enforces for URL paths."
  [root k]
  (string root "/" k))

(defn- dirname
  {:params [:string] :ret :string}
  "The directory part of a path — everything before the last slash,
  or \"\" when there is none."
  [p]
  (def idxs (string/find-all "/" p))
  (if (empty? idxs) "" (string/slice p 0 (last idxs))))

(defn- tmp-name
  {:params [:string] :ret :string}
  "A sibling temp path `put!` writes to before the atomic rename."
  [p]
  (string p ".tmp."
          (string/join (seq [x :in (os/cryptorand 4)] (string/format "%02x" x)))))

(defn encoded-path
  {:params [:string] :ret :string}
  "A key as URL path segments: each segment percent-encoded, the
  slashes kept."
  [k]
  (string/join (map wire/url-encode (string/split "/" k)) "/"))

(def chunk-size
  "How much one `stream` read pulls off the disk between yields."
  65536)

(defn make
  {:params [{:local {:root :any & r} :serve :any? & r}] :ret @{:root :string :serve :any}
   :throws [:string]}
  ``The store table for the [:storage] slice: {:root :serve}. The root
  is created eagerly — a store that cannot write is a :start error, not
  a 500 on the first upload.``
  [cfg]
  (def root (get-in cfg [:local :root]))
  (unless (and (string? root) (not (empty? root)))
    (error "storage: [:storage :local :root] must be a non-empty path"))
  (mkdirs! root)
  (def serve (get cfg :serve {}))
  @{:root root :serve serve})

(defn store
  {:params [@{:root :string :serve (or {:prefix :string? & r} :nil) & r}]
   :ret {:name (enum :local) :shared? :boolean :replacement :string :put! (fn [a b c] d)
         :get (fn [a] b) :stream (fn [a] b) :delete! (fn [a] b) :stat (fn [a] b)
         :url (fn [a b] c)}}
  "The :void/storage-store dictionary over one `make` table."
  [m]
  (def root (m :root))
  (def prefix (get-in m [:serve :prefix]))

  (defn local-put!
    {:params [:string :any (or {:content-type :any? & r} :nil)]
     :ret {:key :string :size :number :content-type :any}}
    [k value opts]
    (key/check! k)
    (def path (path-of root k))
    (def dir (dirname path))
    (unless (empty? dir) (mkdirs! dir))
    (def tmp (tmp-name path))
    (spit tmp value)
    (os/rename tmp path)
    {:key k
     :size (length value)
     :content-type (or (get (or opts {}) :content-type)
                       (static/mime-type k))})

  (defn local-get
    {:params [:string] :ret :any}
    [k]
    (key/check! k)
    (def path (path-of root k))
    (when (= :file (os/stat path :mode))
      (slurp path)))

  (defn local-stream
    {:params [:string] :ret :any}
    [k]
    (key/check! k)
    (def path (path-of root k))
    (when (= :file (os/stat path :mode))
      (coro
        (with [f (file/open path :rb)]
          (forever
            (def chunk (file/read f chunk-size))
            (when (or (nil? chunk) (empty? chunk)) (break))
            (yield chunk))))))

  (defn local-delete!
    {:params [:string] :ret :boolean}
    [k]
    (key/check! k)
    (def path (path-of root k))
    (if (= :file (os/stat path :mode))
      (do (os/rm path) true)
      false))

  (defn local-stat
    {:params [:string] :ret :any}
    [k]
    (key/check! k)
    (def path (path-of root k))
    (when-let [st (os/stat path)]
      (when (= :file (st :mode))
        {:key k
         :size (st :size)
         :modified (st :modified)
         :content-type (static/mime-type k)})))

  (defn local-url
    {:params [:string (or {:expires :number? & r} :nil)] :ret :string?}
    [k opts]
    (key/check! k)
    (when prefix
      (def base (string prefix "/" (encoded-path k)))
      (if-let [expires (get (or opts {}) :expires)]
        (let [p (sign/params k expires)]
          (string base "?exp=" (p "exp") "&sig=" (p "sig")))
        base)))

  @{:name :local
    :shared? false
    :replacement (string "compose void/storage-s3 and set {:void/storage-store "
                         "{:impl :storage/s3}} — a file uploaded to one replica "
                         "is a 404 on every other, and a redeploy that replaces "
                         "the container loses every upload. A volume every "
                         "replica mounts is a deployment that says "
                         "[:deploy :shape] :single")
    :put! local-put!
    :get local-get
    :stream local-stream
    :delete! local-delete!
    :stat local-stat
    :url local-url})
