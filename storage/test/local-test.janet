# The disk store, against a real directory: what it writes, what it
# refuses, and the two properties that are not obvious from the
# contract — a write is atomic, and a read is not a path the caller
# controls.

(import ../test-support/paths)
(import void/storage/key :as key)
(import void/storage/local :as local)
(import void/storage/store :as store)

(def root (string "tmp/local-test-" (os/getpid)))

(defn- rm-rf [path]
  (case (os/stat path :mode)
    :directory (do (each e (os/dir path) (rm-rf (string path "/" e)))
                   (os/rmdir path))
    :file (os/rm path)
    nil))

(rm-rf root)
(os/mkdir "tmp")

(def st (store/normalize
          (local/store (local/make {:local {:root root}
                                    :serve {:prefix "/storage"}}))))

(defer (rm-rf root)

  (assert (= :directory (os/stat root :mode))
          "the root is created at make, not at the first upload")

  # -- put and get -------------------------------------------------------

  (def meta ((st :put!) "uploads/2026/09/a.png" "PNG-BYTES" {}))
  (assert (= "uploads/2026/09/a.png" (meta :key)))
  (assert (= 9 (meta :size)))
  (assert (= "image/png" (meta :content-type))
          "the content type falls back to what the extension says")
  (assert (= :file (os/stat (string root "/uploads/2026/09/a.png") :mode))
          "the intermediate directories were created")

  (assert (= "PNG-BYTES" (string ((st :get) "uploads/2026/09/a.png"))))
  (assert (nil? ((st :get) "uploads/none.png")) "a missing key reads as nil")

  # a caller's content-type wins over the extension's guess
  (def m2 ((st :put!) "b.bin" "x" {:content-type "application/x-thing"}))
  (assert (= "application/x-thing" (m2 :content-type)))

  # -- a write leaves nothing half-written -------------------------------

  (assert (empty? (filter |(string/find ".tmp." $) (os/dir root)))
          "the temporary sibling a write goes through is renamed away")

  ((st :put!) "b.bin" "yy" {})
  (assert (= "yy" (string ((st :get) "b.bin"))) "a second write replaces the first")

  # -- stat and stream ---------------------------------------------------

  (def s ((st :stat) "b.bin"))
  (assert (= 2 (s :size)) "stat answers the size without reading the object")
  (assert (= "application/octet-stream" (s :content-type)))
  (assert (nil? ((st :stat) "gone.bin")))

  ((st :put!) "big.txt" (string/repeat "x" (* 3 local/chunk-size)) {})
  (def chunks (seq [c :in ((st :stream) "big.txt")] (length c)))
  (assert (= 3 (length chunks)) "a stream is bounded reads, not one slurp")
  (assert (= (* 3 local/chunk-size) (sum chunks)) "and it hands over the whole object")
  (assert (nil? ((st :stream) "gone.txt")))

  # -- delete ------------------------------------------------------------

  (assert ((st :delete!) "b.bin") "deleting what is there answers true")
  (assert (not ((st :delete!) "b.bin")) "deleting it again answers false")
  (assert (nil? ((st :get) "b.bin")))

  # -- the key is the whole of what a caller controls --------------------

  (each bad ["../outside.txt" "/etc/passwd" "a/../../b"]
    (each [op args] [[(st :get) [bad]]
                     [(st :stat) [bad]]
                     [(st :delete!) [bad]]
                     [(st :url) [bad {}]]]
      (def [ok _] (protect (op ;args)))
      (assert (not ok) (string/format "%q never reaches the filesystem" bad))))

  # -- urls --------------------------------------------------------------

  (assert (= "/storage/uploads/2026/09/a.png" ((st :url) "uploads/2026/09/a.png" {}))
          "a plain url is the serve prefix and the key")
  (assert (= "/storage/a%20b.png" ((st :url) "a b.png" {}))
          "each segment is percent-encoded, and the slashes are not")

  # without a serve prefix there is no URL to give, and saying so is
  # better than naming a path nothing serves
  (def bare (store/normalize (local/store (local/make {:local {:root root} :serve {}}))))
  (assert (nil? ((bare :url) "a.png" {}))
          "a composition without void/storage-http gets nil, not a lie")

  # -- what it declares about replicas -----------------------------------

  (assert (not (store/shared? st)) "a disk is one machine's disk")
  (assert (string/find "storage-s3" (st :replacement))
          "and it names what to compose instead"))

(printf "local-test: ok")
