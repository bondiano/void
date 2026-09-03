### void/storage/store — the :void/storage-store contract.
###
### Two interfaces, deliberately — the split void/cache proved out:
###
###   :void/storage        what you depend on — the active store behind
###                        `storage/put!`, `storage/url` and the upload
###                        seam (the :storage/store component, see ./state)
###   :void/storage-store  what you implement — five functions over
###                        keys and bytes (this module)
###
### A store is a plain dictionary produced by a store component's :start;
### the component declares :provides [:void/storage-store], so the config
### picks the implementation and no code above names one. A key is a
### string like "products/2026/09/4f2a1c.png" — relative, slash-separated,
### validated by ./key — and metadata is a plain struct; neither is an
### object with behavior, which is what lets a key live in a text column
### and ride a form. Required keys:
###
###   :put!    (fn [key bytes opts] meta)  — write, whole; opts may carry
###            :content-type. Returns {:key :size :content-type ...} —
###            whatever else the backend knows (an etag) rides along
###   :get     (fn [key] bytes-or-nil)     — nil is "not here"
###   :stream  (fn [key] iterable-or-nil)  — chunks for a response body
###            (the ring model streams any iterable as chunked coding);
###            a backend that cannot stream returns the whole object as
###            one chunk and says so in its docstring
###   :delete! (fn [key] deleted?)
###   :url     (fn [key opts] string-or-nil) — where a browser reads the
###            object. opts {:expires seconds} asks for a temporary URL
###            (signed; ./sign for the local store, SigV4 query auth for
###            s3); nil means this store cannot produce one and the
###            caller serves the bytes itself
###
### Optional keys, each with a documented fallback, so a working store
### stays five functions:
###
###   :stat    (fn [key] meta-or-nil)      — falls back to :get and
###            measuring, which reads the whole object; a backend with a
###            cheaper answer (HEAD, os/stat) implements it
###   :close   (fn [])                     — falls back to nothing
###
### plus two declarations:
###
###   :name    keyword, for logs, health and `void deploy check`
###   :shared? boolean (default false) — do several processes see the
###            same objects? A local disk is one machine's disk, which
###            is the same answer as one process's heap once there is a
###            second replica: a file uploaded to one is a 404 on the
###            next. `[:deploy :shape] :fleet` refuses a store that does
###            not say `true`, and `:replacement` (a string)
###            is the line the refusal prints.

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(def- required [:put! :get :stream :delete! :url])

(def- optional [:stat :close])

(defn normalize
  ``Validate a store dictionary and fill in the documented fallbacks.
  Returns a frozen store value; throws with the offending key on any
  contract violation.``
  [st]
  (unless (dictionary? st)
    (errorf "storage store must be a dictionary, got %q" st))
  (def name (get st :name :anonymous))
  (unless (keyword? name)
    (errorf "storage store :name must be a keyword, got %q" name))
  (each k required
    (unless (callable? (get st k))
      (errorf "storage store %q: %q must be a function, got %q" name k (get st k))))
  (each k optional
    (when-let [f (get st k)]
      (unless (callable? f)
        (errorf "storage store %q: %q must be a function, got %q" name k f))))
  (def get- (st :get))
  (freeze
    (merge
      @{:name name
        :shared? false
        # honest, and expensive: the fallback reads the whole object to
        # answer "how big". A backend that can do better (HEAD, os/stat)
        # implements :stat itself — both shipped stores do
        :stat (fn stat [k]
                (when-let [bytes (get- k)]
                  {:key k :size (length bytes)}))
        :close (fn close [] nil)}
      st)))

(defn shared?
  "True when several processes see the same objects — the question
  `[:deploy :shape] :fleet` asks of every store it can reach
."
  [st]
  (truthy? (get st :shared?)))
