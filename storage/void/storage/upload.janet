### void/storage/upload — the seam between multipart and a store
### (ADR-0039 §6).
###
### void/http parses `multipart/form-data` into parts; a store keeps
### bytes under keys. What was missing between them is this file: take
### one file part, enforce what the field's schema annotated
### (`:storage/accept`, `:storage/max-bytes`), generate a key
### (./key), `put!` it, hand back the metadata. The stored *value* is
### the key string — what a text column holds and what `storage/url`
### takes; the filename and the rest of the metadata are returned to
### whoever wants to keep them, because a column for them is the
### application's decision (ADR-0039 §2).
###
### The refusals throw with readable text and land as the 4xx of
### whoever called — the admin widget aborts with 422, a controller
### re-renders its form. What they enforce is the *server's* half of
### the `accept` attribute the form already rendered: a browser filters
### politely, a request is bytes anybody assembled.
###
### **The stored key's extension comes from the declared content type,
### never from the filename.** Serving decides a file's type by its
### extension (`static/mime-type`), so a filename is a type claim —
### and `filename="x.html"` next to `Content-Type: image/png` would
### pass an `image/*` accept list and then be *served* as text/html:
### a stored XSS on the application's origin. A filename whose
### extension names a different type than the part declares is refused
### outright; a type this module has no extension for stores the key
### bare and is served as application/octet-stream.

(import void/http/errors :as errors)
(import void/http/static :as static)
(import ./key :as key)
(import ./state :as state)

(defn file-part?
  "Is this multipart part an actual upload — a filename and bytes? A
  file input left empty submits a part with an empty filename and an
  empty value, and that is \"no file\", not a zero-byte upload."
  [part]
  (and (dictionary? part)
       (bytes? (part :filename))
       (not (empty? (part :filename)))
       (bytes? (part :value))
       (not (empty? (part :value)))))

(defn find-part
  "The file part named `name` among a request's parts, or nil."
  [parts name]
  (def wanted (string name))
  (first (filter |(and (= wanted (string (or ($ :name) ""))) (file-part? $))
                 (or parts []))))

(defn- content-type-of [part]
  (when-let [ct (part :content-type)]
    # the bare media type: browsers may append parameters
    (string/ascii-lower (string/trim (first (string/split ";" (string ct)))))))

(def extension-for-type
  ``Media type -> the extension a stored key gets, dot included — the
  inverse of `static/mime-type`, over the types an upload plausibly
  declares. A type not here stores the key without an extension, and
  serving answers application/octet-stream.``
  {"image/png" ".png"
   "image/jpeg" ".jpg"
   "image/gif" ".gif"
   "image/webp" ".webp"
   "image/avif" ".avif"
   "image/svg+xml" ".svg"
   "image/x-icon" ".ico"
   "text/plain" ".txt"
   "text/markdown" ".md"
   "text/css" ".css"
   "text/html" ".html"
   "text/javascript" ".js"
   "text/csv" ".csv"
   "application/json" ".json"
   "application/xml" ".xml"
   "application/pdf" ".pdf"
   "application/zip" ".zip"
   "application/gzip" ".gz"
   "application/wasm" ".wasm"
   "font/woff" ".woff"
   "font/woff2" ".woff2"
   "font/ttf" ".ttf"
   "font/otf" ".otf"
   "audio/mpeg" ".mp3"
   "video/mp4" ".mp4"
   "video/webm" ".webm"})

(defn- filename-type
  ``The media type the part's filename *extension* would be served as,
  or nil for no extension or one serving does not know. This is the
  claim the filename makes, checked against the declared type.``
  [part]
  (def ext (key/extension (part :filename)))
  (when (not (empty? ext))
    (when-let [mt (get static/mime-types (string/slice ext 1))]
      (string/trim (first (string/split ";" mt))))))

(defn- accepted? [ct accept]
  (some (fn [a]
          (def want (string a))
          (or (= want ct)
              # "image/*" accepts the whole top-level type
              (and (string/has-suffix? "/*" want)
                   ct
                   (string/has-prefix? (string/slice want 0 -2) ct))))
        accept))

(defn check-part!
  ``Enforce :accept (media types, `image/*` allowed) and :max-bytes on
  one file part, and — always — that the filename's extension does not
  claim a different type than the part declares (see the module
  docstring). Throws readable text; returns the part.``
  [part &opt opts]
  (default opts {})
  (when-let [limit (opts :max-bytes)]
    (when (> (length (part :value)) limit)
      (errorf "the file %q is %d bytes — over this field's limit of %d"
              (string (part :filename)) (length (part :value)) limit)))
  (def ct (content-type-of part))
  (when-let [accept (opts :accept)]
    (unless (accepted? ct accept)
      (errorf "the file %q is %s — this field takes %s"
              (string (part :filename)) (or ct "of no declared type")
              (string/join (map string accept) ", "))))
  # octet-stream is "no claim", not a type to contradict
  (when (and ct (not= "application/octet-stream" ct))
    (when-let [claimed (filename-type part)]
      (unless (= claimed ct)
        (errorf "the file %q is named as %s but declares itself %s — the name and the type disagree, and this field refuses to guess"
                (string (part :filename)) claimed ct))))
  part)

(defn save-part!
  ``One file part into the active store: check, generate a key, put!.
  opts: :prefix (key namespace, default "uploads"), :key (skip
  generation), :accept, :max-bytes. Returns the store's metadata plus
  :filename — the key is under :key, and the key is the value an
  entity column stores.``
  [part &opt opts]
  (default opts {})
  (unless (file-part? part)
    (error "storage: save-part! wants a file part — a table with :filename and :value"))
  (check-part! part opts)
  (def ct (content-type-of part))
  (def k (or (opts :key)
             # the extension — the type the object will be *served*
             # as — comes from the declared type, never the filename
             (key/generate {:prefix (opts :prefix)
                            :ext (get extension-for-type ct "")})))
  (def meta (state/put! k (part :value) {:content-type ct}))
  (merge meta {:filename (string (part :filename))}))

(defn save-upload!
  ``The controller-side one-liner: the file part named `name` out of
  `(req :multipart)`, saved. Returns the metadata, or nil when the
  request carries no such file — an optional upload left empty is not
  an error. opts are `save-part!`'s.``
  [req name &opt opts]
  (when-let [part (find-part (req :multipart) name)]
    (save-part! part opts)))

(defn abort-invalid!
  ``Re-raise a `check-part!` refusal as a 422 with the message in the
  body — for a controller that saves an upload outside a form it
  re-renders. Inside an admin widget the refusal belongs on the field
  instead (`widget/refuse!`), which is where the operator is looking.``
  [err]
  (errors/abort 422 (string err)))
