### void/storage — files and uploads (ADR-0039).
###
### Two interfaces and a seam on each side. `:void/storage-store` is a
### backend — five functions over keys and bytes (./store);
### `:void/storage` is what an application depends on: the active
### store behind `storage/put!`, `storage/url` and the upload helpers.
### Between multipart parsing and a URL on a page there used to be
### nothing; now there is exactly this:
###
###   ./key      keys as data: validation, sanitized filenames,
###              generated upload keys
###   ./store    the :void/storage-store contract and its fallbacks
###   ./local    the disk store — the default backend
###   ./state    the active store and the functions applications call
###   ./upload   one multipart file part -> a stored object
###   ./sign     temporary URLs for the local store (void/security keys)
###   ./sigv4    AWS Signature v4, pure functions over void/crypto
###
### Three more plugins live in this package, the void/cache —
### void/cache-http split, so nothing is paid for what is not
### composed: void/storage-http serves the local store's files
### (./http), void/storage-s3 keeps them in a bucket (./s3), and
### void/storage-admin draws and parses the upload widget (./admin).
###
###     (void/run! {:plugins [:void/storage :void/storage-http ...]})
###     # config/prod.janet, once void/storage-s3 is composed:
###     {:void/storage-store {:impl :storage/s3}
###      :storage-s3 {:endpoint "http://minio:9000" :bucket "shop"
###                   :access-key {:secret "MINIO_ACCESS_KEY"}
###                   :secret-key {:secret "MINIO_SECRET_KEY"}}}
###
### The `{:impl ...}` line is not boilerplate: two components provide
### `:void/storage-store` once the s3 plugin is composed, and a kernel
### that picked one for you would pick differently the day a
### dependency changes.
###
### A schema field says `[:file {...}]` and the rest is projections:
### void/html renders the file input (and flips the form to
### multipart), void/storage-admin stores what was submitted, the
### entity keeps the key in a text column, `storage/url` turns it back
### into an address. The `:storage/*` props (`:storage/accept`,
### `:storage/max-bytes`, `:storage/prefix`) are annotations in the
### ADR-0008 sense — parsed and stored, never consulted by validation,
### read by the widgets that act on them.

(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import ./key :as key)
(import ./local :as local)
(import ./schema :as sschema)
(import ./sign :as sign)
(import ./state :as state)
(import ./store :as store)
(import ./upload :as upload)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.storage")

# -- the interfaces ------------------------------------------------------

(plugin/contribute! :void.core/interface
  {:name :void/storage
   :doc "Files and uploads: the :storage/store component's value — the normalized active store. Depend on the interface rather than the key to let a test stand a stub in its place."
   :methods {:put! "(fn [key bytes opts] meta)"
             :get "(fn [key] bytes-or-nil)"
             :url "(fn [key opts] string-or-nil)"}})

(plugin/contribute! :void.core/interface
  {:name :void/storage-store
   :doc "A storage backend: {:put! :get :stream :delete! :url} plus the optional :stat and :close keys (see void/storage/store). A store component declares :provides [:void/storage-store]; {:void/storage-store {:impl <key>}} picks between several."
   :methods {:put! "(fn [key bytes opts] meta)"
             :get "(fn [key] bytes-or-nil)"
             :stream "(fn [key] iterable-or-nil)"
             :delete! "(fn [key] deleted?)"
             :url "(fn [key opts] string-or-nil)"}})

# -- the :file schema type -----------------------------------------------
#
# ./schema registers it at module load, because an entity is declared
# while a module loads and `[:file {...}]` normalizes right then — long
# before a bootstrap could resolve an extension point (the void/proto
# pose). It is declared here as well so `plugin/inspect` and
# CONTRACTS.md show it next to every other custom type.

(eachp [name spec] sschema/types
  (plugin/contribute! :void.core/schema-type {:name name :spec spec}))

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:storage] config slice."
  {:local [:optional {:root [:optional :string]}]
   :serve [:optional {:prefix [:optional :string]
                      # true turns the serve prefix private: every GET
                      # must carry the exp/sig pair a temporary URL
                      # mints (void/storage-http)
                      :signed [:optional :boolean]
                      # the policy the serve route carries
                      # (:void.authz/policy). Left out, the route
                      # carries none — which is the same as every other
                      # route under [:authz :default :allow], and a
                      # refusal to start under :deny
                      :policy [:optional :keyword]
                      :max-file-size [:optional [:int {:min 1}]]}]})

(def defaults
  ``Defaults of the [:storage] slice. The root is relative to the
  working directory the way [:http :static :root] is — a deployment
  that keeps uploads on a mounted volume names it here.

  `:policy` has no default on purpose: under `[:authz :default :allow]`
  a route without one is ordinary, and under `:deny` the boot refuses
  until somebody names it — which is the whole point of that posture.``
  {:local {:root "storage"}
   :serve {:prefix "/storage"
           :signed false
           :max-file-size 10485760}})

(defn- slice [cfg0]
  (def cfg (merge defaults (or cfg0 {})))
  (put cfg :local (merge (defaults :local) (get (or cfg0 {}) :local {})))
  (put cfg :serve (merge (defaults :serve) (get (or cfg0 {}) :serve {})))
  cfg)

# -- public surface (re-exports) -----------------------------------------

(def Store "See store/normalize — the :void/storage-store contract." store/normalize)
(def store-shared? "See store/shared?." store/shared?)

(def valid-key? "See key/valid? — is this a well-formed storage key?" key/valid?)
(def check-key! "See key/check!." key/check!)
(def generate-key "See key/generate — a fresh key for an upload." key/generate)
(def sanitize-filename "See key/sanitize-filename." key/sanitize-filename)

(def local-store "See local/store — the disk store." local/store)

(def storage-dyn "See state/storage-dyn — the store override." state/storage-dyn)
(def active-store "See state/active-store." state/active-store)
(def put! "See state/put! — store bytes under a key." state/put!)
(def fetch "See state/fetch — the object's bytes, or nil." state/fetch)
(def stream "See state/stream — the object as a ring response body." state/stream)
(def delete! "See state/delete!." state/delete!)
(def stat "See state/stat — metadata without the bytes." state/stat)
(def exists? "See state/exists?." state/exists?)
(def url "See state/url — where a browser reads the object." state/url)
(def shared? "See state/shared? — does every replica see this store?" state/shared?)

(def file-part? "See upload/file-part? — is this part an actual upload?" upload/file-part?)
(def find-part "See upload/find-part." upload/find-part)
(def save-part! "See upload/save-part! — one file part into the store." upload/save-part!)
(def save-upload! "See upload/save-upload! — the controller one-liner." upload/save-upload!)

(def sign-params "See sign/params — the exp/sig pair of a temporary URL." sign/params)
(def sign-valid? "See sign/valid?." sign/valid?)

(def annotations "See schema/annotations — a node's :storage/* props." sschema/annotations)

# -- the local store component -------------------------------------------

(def local-component
  (system/component :storage/local
    :doc "The disk store: keys as relative paths under [:storage :local
    :root], atomic writes (tmp + rename), served through
    void/storage-http when it is composed. The default backend, and
    per-machine on purpose — [:deploy :shape] :fleet refuses it and
    names void/storage-s3 (ADR-0030)."
    :provides [:void/storage-store]
    :config {:key :storage :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (def m (local/make cfg))
      (log/info "storage local store ready" :ns log-ns
                :root (m :root)
                :prefix (get-in cfg [:serve :prefix]))
      (local/store m))
    :health
    (fn health [_]
      {:status :up})))

# -- the storage component -----------------------------------------------

(def storage-component
  (system/component :storage/store
    :doc "The active store over whichever :void/storage-store the
    config picked, normalized against the contract — the value behind
    storage/put!, storage/url and the upload seam."
    :deps [:void/storage-store]
    :provides [:void/storage]
    :config {:key :storage :schema Config}
    :start
    (fn start [deps _cfg]
      (def st (store/normalize (deps :void/storage-store)))
      (set state/current-store st)
      (log/info "storage ready" :ns log-ns
                :store (st :name)
                :shared (store/shared? st))
      st)
    :stop
    (fn stop [_]
      (set state/current-store nil))
    :health
    (fn health [st]
      {:status :up :store (st :name) :shared (store/shared? st)})))

(plugin/contribute! :void.core/store
  {:name :void/storage-store
   :what "uploaded files"
   :needs [:storage/store]
   :doc "Where uploads live — a local disk is one machine's disk, which is one process's heap as far as a second replica is concerned"
   :ask (fn ask-storage [boot]
          (when-let [st (get-in boot [:system :instances :storage/store])]
            {:store (get st :name :anonymous)
             :shared? (store/shared? st)
             :replacement (get st :replacement
                               "a store every replica reads — compose void/storage-s3 and set {:void/storage-store {:impl :storage/s3}}")}))})

# -- CLI -----------------------------------------------------------------

(defn- with-store [st f]
  (with-dyns [state/storage-dyn st] (f)))

(plugin/contribute! :void.core/cli
  {:name :storage/info
   :read-only? true
   :doc "Show the active store: void storage info"
   :needs [:storage/store]
   :fn (fn cli-info [st & args]
         (unless (empty? args)
           (errorf "void storage info takes no arguments (got %q)" (string/join args " ")))
         (printf "store    %q" (st :name))
         (printf "shared   %q" (store/shared? st)))})

(plugin/contribute! :void.core/cli
  {:name :storage/put
   :read-only? false
   :doc "Store a file: void storage put SRC [KEY] — the key is generated from the filename when left out"
   :needs [:storage/store]
   :fn (fn cli-put [st & args]
         (unless (or (= 1 (length args)) (= 2 (length args)))
           (error "usage: void storage put SRC [KEY]"))
         (def [src k0] args)
         (unless (= :file (os/stat src :mode))
           (errorf "no such file: %s" src))
         (def k (or k0 (key/generate {:filename src})))
         (def meta (with-store st (fn [] (state/put! k (slurp src)))))
         (printf "%s (%d bytes)" (meta :key) (meta :size))
         (when-let [u (with-store st (fn [] (state/url k)))]
           (print u)))})

(plugin/contribute! :void.core/cli
  {:name :storage/url
   :read-only? true
   :doc "The URL of an object: void storage url KEY [EXPIRES-SECONDS]"
   :needs [:storage/store]
   :fn (fn cli-url [st & args]
         (unless (or (= 1 (length args)) (= 2 (length args)))
           (error "usage: void storage url KEY [EXPIRES-SECONDS]"))
         (def [k expires] args)
         (def opts (if expires
                     {:expires (or (scan-number expires)
                                   (errorf "EXPIRES-SECONDS must be a number, got %q" expires))}
                     {}))
         (if-let [u (with-store st (fn [] (state/url k opts)))]
           (print u)
           (print "this store has no URL for it — compose void/storage-http, or read it with the store")))})

(plugin/contribute! :void.core/cli
  {:name :storage/rm
   :read-only? false
   :doc "Drop an object: void storage rm KEY"
   :needs [:storage/store]
   :fn (fn cli-rm [st & args]
         (unless (= 1 (length args))
           (error "usage: void storage rm KEY"))
         (def k (first args))
         (if (with-store st (fn [] (state/delete! k)))
           (printf "dropped %s" k)
           (printf "%s held nothing" k)))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/storage
  :doc "Files and uploads: the :void/storage-store contract, a local disk store with atomic writes, keys and metadata as data, the multipart -> store seam (save-upload!), temporary URLs, and the :file schema type the form and admin widgets project."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :storage
  :config-schema Config
  :config-defaults defaults
  :components [local-component storage-component])

# -- names that shadow the core ------------------------------------------
#
# Last, and deliberately: `get` is a core function, and a module that
# shadows it before its own code is written is a module that cannot
# use it. Everything above is defined; from here nothing is.

(def get "See state/fetch — the object's bytes, or nil." state/fetch)
