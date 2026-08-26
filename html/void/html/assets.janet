### void/html/assets — the asset pipeline (SPEC.md §5.4, ROADMAP 1.2).
###
### Production: build! walks the asset root, copies every file to its
### fingerprinted name (crc32 of the content in the filename) and
### writes a manifest mapping logical -> fingerprinted paths; href
### resolves through that manifest, so a changed file changes its URL
### and far-future caching is safe. Development: no manifest, href
### passes the logical path through unchanged and void/http's static
### middleware serves the source directory directly — no build step in
### the dev loop.

(import spork/crc)

(def- crc32 (crc/named-variant :crc32))

(defn fingerprint
  "Fingerprinted filename for a logical path: name-<crc32hex>.ext."
  [path content]
  (def dot (last (string/find-all "." path)))
  (def sum (string/format "%08x" (crc32 content)))
  (if (or (nil? dot) (zero? dot))
    (string path "-" sum)
    (string (string/slice path 0 dot) "-" sum (string/slice path dot))))

(defn- ensure-dir
  "mkdir -p for the directory that will hold `path`."
  [path]
  (def slash (last (string/find-all "/" path)))
  (when (and slash (pos? slash))
    (var acc "")
    (each part (string/split "/" (string/slice path 0 slash))
      (set acc (if (empty? acc) part (string acc "/" part)))
      (unless (or (empty? acc) (= "." acc))
        (os/mkdir acc)))))

(defn- walk-files [root &opt rel out]
  (default rel "")
  (default out @[])
  (each name (sorted (os/dir root))
    (def full (string root "/" name))
    (def sub (if (empty? rel) name (string rel "/" name)))
    (case (get (os/stat full) :mode)
      :directory (walk-files full sub out)
      :file (array/push out sub)
      nil))
  out)

(defn build!
  ``Build fingerprinted assets:

      (assets/build! {:root "assets" :out "public/assets"})

  Copies every file under :root to :out under its fingerprinted name
  and writes the manifest (logical path -> fingerprinted path) as
  janet data to :manifest (default <out>/manifest.jdn). Returns the
  manifest table.``
  [opts]
  (def root (or (opts :root) (error "assets/build! needs a :root directory")))
  (def out (or (opts :out) (error "assets/build! needs an :out directory")))
  (unless (= :directory (get (os/stat root) :mode))
    (errorf "asset root %q is not a directory" root))
  (def manifest @{})
  (each logical (walk-files root)
    (def content (slurp (string root "/" logical)))
    (def target (fingerprint logical content))
    (ensure-dir (string out "/" target))
    (spit (string out "/" target) content)
    (put manifest logical target))
  (def man-path (or (opts :manifest) (string out "/manifest.jdn")))
  (ensure-dir man-path)
  (spit man-path (string/format "%j" (freeze manifest)))
  manifest)

(defn load-manifest
  "Read a manifest written by build!."
  [path]
  (unless (os/stat path)
    (errorf "asset manifest %q does not exist — run the asset build first" path))
  (parse (slurp path)))

(defn href
  ``URL for a logical asset path: prefix + the manifest's fingerprinted
  path, or prefix + the logical path itself when there is no manifest
  (dev passthrough). An entry missing from a present manifest is an
  error — a typo, not a fallback.``
  [manifest prefix logical]
  (def resolved
    (if (nil? manifest)
      logical
      (or (get manifest logical)
          (errorf "asset %q is not in the manifest (assets: %s)"
                  logical
                  (string/join (sorted (keys manifest)) " ")))))
  (string prefix resolved))
