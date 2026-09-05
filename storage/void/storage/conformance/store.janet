### void/storage/conformance/store — the :void/storage-store conformance suite.
###
### One set of assertions, run against every backend there is. The
### contract (void/storage/store) says a store is five functions over
### keys and bytes, that `normalize` fills `:stat` and `:close` in, and
### that two declarations — `:shared?` and `:replacement` — are what
### `[:deploy :shape]` reads instead of the store's name. A suite that
### only ever ran against the disk store would be a suite that never
### checked the claim, so this file holds the assertions and each
### backend's own test hands it a store:
###
###     (import void/storage/conformance/store :as conformance)
###     (conformance/run! "local" (local/store (local/make cfg)))
###
### It ships with void/storage, not with the tests, so a store written
### outside this repository runs the same suite against the same
### contract it will be plugged into.
###
### It takes the store **un-normalized** and normalizes it itself, the
### way ./state does — a suite handed the normalized value would be a
### suite testing a store nobody plugs in.
###
### Everything branches on declarations rather than on the store's
### name. `url` answering nil is not a failure: the contract says nil
### means "this store cannot produce one and the caller serves the
### bytes itself", which is what a local store without void/storage-http
### answers. `:shared?` false is not a failure either — it is a
### deployment fact, and the assertion is that the store also names its
### `:replacement`, because that string is the line the refusal prints.
###
### It runs in a bucket somebody else is also in. Every key carries a
### prefix with this process's pid and a `defer` deletes exactly those
### keys on the way out — nothing here empties a bucket or a directory,
### because the one named may be production's.
###
### What it does NOT test is what a backend does not share: path
### traversal against a real root, SigV4 against a real server, the
### atomic rename, the etag. Those live in the backend's own suite,
### next to the thing that has them.

(import ../store :as store)

(def- unreserved
  # RFC 3986's unreserved set, plus the separator a key is built out of
  (do
    (def t @{})
    (loop [c :range-to [(chr "a") (chr "z")]] (put t c true))
    (loop [c :range-to [(chr "A") (chr "Z")]] (put t c true))
    (loop [c :range-to [(chr "0") (chr "9")]] (put t c true))
    (each c [(chr "-") (chr "_") (chr ".") (chr "~") (chr "/")] (put t c true))
    (freeze t)))

(defn- percent-encoded
  ``The key as it appears inside a URL path: every byte outside the
  unreserved set percent-encoded, the slashes kept. Both shipped stores
  spell it this way — one through wire/url-encode, the other through
  SigV4's canonical path — and a store that spells it differently still
  passes, because the assertion accepts the raw key too.``
  [k]
  (def out @"")
  (each c k
    (if (in unreserved c)
      (buffer/push-byte out c)
      (buffer/push-string out (string/format "%%%02X" c))))
  (string out))

(defn- names-key?
  "Does this URL name the key — literally, or percent-encoded?"
  [url k]
  (truthy? (or (string/find k url)
               (string/find (percent-encoded k) url))))

(defn run!
  ``Assert that `store0` behaves like a `:void/storage-store`. `name`
  names the backend in the failure messages, because "the stream did
  not hand over the whole object" is a different bug in each of them.

  `store0` is the raw store dictionary, not a normalized one — see the
  module docstring.

  The suite works under `void-conformance/<pid>/` and deletes exactly
  the keys it wrote; the rest of the bucket is untouched, so it can
  share one with a package's other suites.

  opts:
    :size  how large the object used for the streaming section is, in
           bytes (default 131073 — two of the local store's 64 KB reads
           and one byte, so a store that streams does more than one
           read). A backend on a slow link asks for less.``
  [name store0 &opt opts]
  (default opts {})
  (def st (store/normalize store0))
  (defn note [msg] (string name ": " msg))

  (def base (string "void-conformance/" (os/getpid) "/"))
  (defn k [s] (string base s))

  (def object (k "objects/a.png"))
  (def big (k "objects/big.bin"))
  (def spaced (k "objects/two words.txt"))
  (def missing (k "objects/none.png"))

  # bytes, not text: an object store that went through a string
  # somewhere truncates at the NUL and nobody notices until a PNG
  (def body (string "PNG\0\xff\x01-" (string/repeat "ab" 40) "-end"))
  (def big-size (get opts :size 131073))

  (defer (each key [object big spaced] (protect ((st :delete!) key)))

    # -- the shape -------------------------------------------------------

    (assert (keyword? (st :name)) (note "a store names itself with a keyword"))
    (each key [:put! :get :stream :delete! :url :stat :close]
      (assert (function? (st key))
              (note (string key " is callable after normalize — the caller never checks"))))
    # normalize checked :shared?; what is left to say is that it is an
    # answer when the store speaks (nil is the documented "no")
    (unless (nil? (get store0 :shared?))
      (assert (boolean? (get store0 :shared?))
              (note ":shared? is declared as a boolean — several replicas either see one set of objects or they do not")))
    (unless (store/shared? st)
      (assert (string? (get st :replacement))
              (note (string "a store that is not shared names its :replacement — that string is "
                            "the line [:deploy :shape] :fleet prints when it refuses the store"))))
    # :close is not called: it is the component's to call, and it takes
    # the HTTP client with it — a suite that closed the store it was
    # handed could not be run twice against one.

    # -- put! and what it says it stored ----------------------------------

    (def meta ((st :put!) object body {:content-type "image/png"}))
    (assert (dictionary? meta) (note "put! answers metadata"))
    (assert (= object (meta :key)) (note "naming the key it wrote"))
    (assert (= (length body) (meta :size)) (note "and how many bytes went"))
    (assert (= "image/png" (meta :content-type))
            (note "a declared content type rides back on the metadata"))

    # -- get ---------------------------------------------------------------

    (def read-back ((st :get) object))
    (assert (not (nil? read-back)) (note "what was written reads back"))
    (assert (= (length body) (length read-back))
            (note "the whole object, not a prefix of it"))
    (assert (= body (string read-back))
            (note "byte for byte — NUL and high bytes included"))

    (assert (nil? ((st :get) missing)) (note "a missing key reads as nil, not as an error"))
    (assert (nil? ((st :stat) missing)) (note "and stats as nil"))
    (assert (nil? ((st :stream) missing)) (note "and streams as nil"))

    ((st :put!) object "replaced" {})
    (assert (= "replaced" (string ((st :get) object)))
            (note "a second write to one key replaces the first"))
    ((st :put!) object body {:content-type "image/png"})

    # -- stat ---------------------------------------------------------------

    (def stat ((st :stat) object))
    (assert (dictionary? stat) (note "stat answers metadata for an object that is there"))
    (assert (= object (stat :key)) (note "naming the key"))
    (assert (= (length body) (stat :size))
            (note "and its size — without the caller reading the object to find out"))

    # -- stream --------------------------------------------------------------
    #
    # How many chunks is the backend's business: the disk store reads
    # 64 KB at a time, the s3 store buffers the response and hands the
    # object over as one. What the contract promises is that they are
    # bytes, that they are bounded, and that they are the object.
    ((st :put!) big (string/repeat "x" big-size) {})
    (def chunks (seq [c :in ((st :stream) big)] c))
    (assert (not (empty? chunks)) (note "a stream of an object that is there yields something"))
    (each c chunks
      (assert (bytes? c) (note "every chunk is bytes"))
      (assert (pos? (length c)) (note "and none of them is empty"))
      (assert (<= (length c) big-size) (note "no chunk is larger than the object")))
    (assert (= big-size (sum (map length chunks)))
            (note "the chunks are exactly as long as the object"))
    (assert (= (string/repeat "x" big-size) (string/join (map string chunks)))
            (note "and joined they are the object"))

    # -- delete! ---------------------------------------------------------------

    (assert ((st :delete!) big) (note "deleting what is there answers true"))
    (assert (not ((st :delete!) big))
            (note "deleting it again is not an error, just false"))
    (assert (nil? ((st :get) big)) (note "and it is gone"))

    # -- url ---------------------------------------------------------------------
    #
    # nil is an answer, not a failure: a composition with nothing
    # serving the store has no URL to give, and saying so is better
    # than naming a path nothing serves.
    ((st :put!) spaced body {})

    (each key [object spaced]
      (def plain ((st :url) key {}))
      (assert (or (nil? plain) (string? plain))
              (note "url answers a string, or nil when the store cannot produce one"))
      (when (string? plain)
        (assert (names-key? plain key)
                (note (string "a url names the object it opens — literally or encoded, got " plain))))

      # a store that signs needs its keys: one composed without them
      # raises here by contract (see ../store), which is a composition
      # error of the test, not a finding about the store — so it is
      # named as such rather than left as a signing error
      (def [sok signed] (protect ((st :url) key {:expires 300})))
      (assert sok (note (string "a temporary url is answered — a store that signs must be "
                                "handed its keys before the suite runs (compose :void/security); "
                                "it raised: " signed)))
      (assert (or (nil? signed) (string? signed))
              (note "and the same when a temporary one is asked for"))
      (when (string? signed)
        (assert (names-key? signed key)
                (note (string "a temporary url names the object too, got " signed)))))

    (assert (= body (string ((st :get) spaced)))
            (note "a key with a space in it round-trips like any other")))

  (printf "%s: storage-store conformance OK" name)
  true)
