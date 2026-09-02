(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/storage :as storage)
(import void/storage/state :as state)
(import void/storage/s3 :as s3)

(log/set-level! "void" :error)

(def root (string "tmp/plugin-test-" (os/getpid)))

(defn- rm-rf [path]
  (case (os/stat path :mode)
    :directory (do (each e (os/dir path) (rm-rf (string path "/" e)))
                   (os/rmdir path))
    :file (os/rm path)
    nil))

(rm-rf root)
(os/mkdir "tmp")

(def plugins ["void/storage/init"])

(defn- config [extra]
  # the [:storage] slice is merged a level down on purpose: `merge`
  # replaces whole values, and a caller passing {:storage {:serve ...}}
  # would otherwise drop the root and write into the package directory
  {:env @{}
   :cli (merge {:log {:level :error}} extra
               {:storage (merge {:local {:root root}} (get extra :storage {}))})})

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "the plugin composes on its own")
(assert (index-of :storage/local (report :components)) "the disk store is in the graph")
(assert (index-of :storage/store (report :components)) "and the storage over it")

(def interfaces (get-in report [:extensions :void.core/interface :contributions]))
(assert (and interfaces (>= interfaces 2))
        "both interfaces are declared — the one you depend on and the one you implement")

(each [slice reason]
  [[{:storage {:local {:root 42}}} "a root that is not a path"]
   [{:storage {:serve {:signed "yes"}}} "a :signed that is not a boolean"]
   [{:storage {:serve {:max-file-size 0}}} "a file cap of nothing"]]
  (def [ok] (protect (plugin/dry-run {:plugins plugins :profile :test
                                      :config (config slice)})))
  (assert (not ok) (string reason " fails the boot")))

# -- started -------------------------------------------------------------

(def boot (plugin/start! {:plugins plugins :profile :test
                          :config (config {:storage {:serve {:prefix "/files"}}})}))
(defer (do (plugin/shutdown! boot 3) (rm-rf root))
  (def st (get-in boot [:system :instances :storage/store]))
  (assert st "the storage component started")
  (assert (= :local (st :name)) "over the store this plugin ships")
  (assert (= st (state/active-store)) "and it is what the module-level functions reach for")

  # -- the surface applications import ------------------------------------

  (def meta (storage/put! "docs/readme.txt" "hello" {}))
  (assert (= 5 (meta :size)))
  (assert (= "hello" (string (storage/get "docs/readme.txt"))))
  (assert (storage/exists? "docs/readme.txt"))
  (assert (= 5 ((storage/stat "docs/readme.txt") :size)))
  (assert (= "/files/docs/readme.txt" (storage/url "docs/readme.txt")))
  (assert (not (storage/shared?)) "a disk is not shared, and the surface says so")

  (assert (= "hello" (string/join (seq [c :in (storage/stream "docs/readme.txt")] (string c)))))
  (assert (storage/delete! "docs/readme.txt"))
  (assert (not (storage/exists? "docs/readme.txt")))

  # a malformed key never reaches a store
  (def [ok] (protect (storage/put! "../escape.txt" "x" {})))
  (assert (not ok) "the key is checked on the way in, not by each backend")

  # -- the :file schema type ----------------------------------------------

  (def types (get-in boot [:extensions :void.core/schema-type :contributions]))
  (assert (and types (pos? types)) ":file is contributed as a schema type")

  # -- health -------------------------------------------------------------

  (def h ((system/health (boot :system)) :components))
  (assert (= :up (get-in h [:storage/store :status])))
  (assert (= :local (get-in h [:storage/store :store])))
  (assert (= false (get-in h [:storage/store :shared])))
  (assert (= :up (get-in h [:storage/local :status])))

  # -- what `void deploy check` is told ------------------------------------

  (def stores (boot :stores))
  (def entry (find |(= :void/storage-store ($ :name)) stores))
  (assert entry "the store declares itself to the deployment survey (ADR-0030)")
  (assert (= "uploaded files" (entry :what)))
  (assert (= false (entry :shared?)) "and answers the question honestly")
  (assert (string/find "storage-s3" (entry :replacement))
          "with the line that says what to compose instead")

  # -- the CLI commands ---------------------------------------------------

  (def cli (get-in boot [:extensions :void.core/cli :resolved]))
  (def names (map |($ :name) cli))
  (each n [:storage/info :storage/put :storage/url :storage/rm]
    (assert (index-of n names) (string/format "%q is contributed" n)))
  (each entry cli
    (when (index-of (entry :name) [:storage/info :storage/put :storage/url :storage/rm])
      (assert (deep= [:storage/store] (entry :needs))
              "and asks for the storage component and nothing else")))

  (defn- command [name] (find |(= name ($ :name)) cli))
  (spit "tmp/cli-src.txt" "from the cli")
  (each [name args] [[:storage/info []]
                     [:storage/put ["tmp/cli-src.txt" "cli/a.txt"]]
                     [:storage/url ["cli/a.txt"]]
                     [:storage/rm ["cli/a.txt"]]
                     [:storage/rm ["cli/a.txt"]]]
    (def [ok err] (protect (with-dyns [:out @""] (((command name) :fn) st ;args))))
    (assert ok (string/format "%q %j runs: %q" name args err)))
  (each [name args] [[:storage/info ["extra"]]
                     [:storage/put []]
                     [:storage/put ["tmp/no-such-file"]]
                     [:storage/url []]
                     [:storage/url ["k" "soon"]]
                     [:storage/rm []]]
    (def [ok] (protect (with-dyns [:out @""] (((command name) :fn) st ;args))))
    (assert (not ok) (string/format "%q %j is a usage error, not a surprise" name args)))
  (os/rm "tmp/cli-src.txt"))

# -- the plugin leaves no trace when it is not there ---------------------

(def bare (plugin/dry-run {:plugins [] :profile :test :config (config {})}))
(assert (empty? (filter |(string/has-prefix? "storage" (string $)) (bare :components)))
        "drop it from :plugins and no component of it remains")

(assert (nil? state/current-store) "shutdown leaves no store behind")
(def [gone] (protect (storage/get "docs/readme.txt")))
(assert (not gone) "and the surface says so instead of pretending")

# -- a disk under a fleet is refused at start ----------------------------
#
# Last, because the refusal happens *after* :after-start (ADR-0030):
# the components are up when it fires, and this test does not tidy them
# away — in a deployment the process is on its way down.

(def [fok ferr]
  (protect (plugin/start! {:plugins plugins :profile :test
                           :config (config {:deploy {:shape :fleet}})})))
(assert (not fok) "the local store does not start under [:deploy :shape] :fleet")
(assert (string/find "uploaded files" (string ferr))
        "and the refusal names what would be lost")
(assert (string/find "storage-s3" (string ferr))
        "and what to compose instead (ADR-0030)")

# -- what the bucket store needs open ------------------------------------
#
# Every request the S3 store makes is signed, and SigV4 is HMAC over
# void/crypto. A CLI command starts what it declared in `:needs` plus
# that closure, so a store that did not name the library was a `void
# jobs work` (or a `void hub replay`) that fetched an object and failed
# on libcrypto — with the store itself started and looking fine.
(assert (index-of :crypto/lib (get s3/s3-component :deps []))
        "the bucket store declares the library it signs with, so a partial bootstrap opens it")

(rm-rf root)
(printf "plugin-test: ok")
