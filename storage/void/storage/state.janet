### void/storage/state — the active store.
###
### One store per process, the void/cache pose: the :storage/store
### component's :start sets `current-store`, a dyn overrides it for a
### scope (tests, tooling, a second store), and everything an
### application calls — `storage/put!`, `storage/url`, the upload seam
### — funnels through `active-store`. Application code depends on
### functions over keys, never on which backend the composition picked.

(import ./key :as key)
(import ./store :as store)

(def storage-dyn
  "Dynamic binding: storage override — set it to run a scope against a
  store other than the started :storage/store component (tests,
  tooling, a migration between stores)."
  :void.storage/store)

(var current-store
  "The value of the running :storage/store component (set by its
  :start). One per process, like plugin/current-boot."
  nil)

(defn active-store
  "The store this fiber runs against: the `storage-dyn` override, else
  the started component."
  []
  (or (dyn storage-dyn)
      current-store
      (error (string "void/storage is not started — no :storage/store component "
                     "(or bind the storage-dyn dynamic)"))))

(defn put!
  ``Store `value` (bytes) under `key`. opts: :content-type. Returns the
  store's metadata — {:key :size :content-type ...}.``
  [k value &opt opts]
  (((active-store) :put!) (key/check! k) value (or opts {})))

(defn fetch
  "The object's bytes, or nil when the key holds nothing."
  [k]
  (((active-store) :get) (key/check! k)))

(defn stream
  "An iterable of the object's chunks — a ring response body — or nil."
  [k]
  (((active-store) :stream) (key/check! k)))

(defn delete!
  "Drop the object. True when there was one."
  [k]
  (((active-store) :delete!) (key/check! k)))

(defn stat
  "The object's metadata without its bytes, or nil."
  [k]
  (((active-store) :stat) (key/check! k)))

(defn exists?
  "Does the key hold an object?"
  [k]
  (not (nil? (stat k))))

(defn url
  ``Where a browser reads the object. opts {:expires seconds} asks for
  a temporary URL. nil when this store cannot produce one (a local
  store in a composition without void/storage-http).``
  [k &opt opts]
  (((active-store) :url) (key/check! k) (or opts {})))

(defn shared?
  "Does every replica see the objects of the active store?"
  []
  (store/shared? (active-store)))
