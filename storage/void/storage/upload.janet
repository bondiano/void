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

(import void/http/errors :as errors)
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
    (string/trim (first (string/split ";" (string ct))))))

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
  one file part. Throws readable text; returns the part.``
  [part &opt opts]
  (default opts {})
  (when-let [limit (opts :max-bytes)]
    (when (> (length (part :value)) limit)
      (errorf "the file %q is %d bytes — over this field's limit of %d"
              (string (part :filename)) (length (part :value)) limit)))
  (when-let [accept (opts :accept)]
    (def ct (content-type-of part))
    (unless (accepted? ct accept)
      (errorf "the file %q is %s — this field takes %s"
              (string (part :filename)) (or ct "of no declared type")
              (string/join (map string accept) ", "))))
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
  (def k (or (opts :key)
             (key/generate {:prefix (opts :prefix)
                            :filename (part :filename)})))
  (def meta (state/put! k (part :value)
                        {:content-type (content-type-of part)}))
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
