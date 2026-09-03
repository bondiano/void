### void/storage/key — keys as data.
###
### A key is a relative, slash-separated string: what a text column
### stores, what a URL path carries, what every store addresses. The
### rules here are the traversal rules of void/http/static's safe-join,
### enforced at the contract boundary rather than at each backend: a
### key that passes `check!` cannot climb out of a local root and needs
### no second opinion from the s3 store.
###
### `generate` is the shape uploads land under —
### `<prefix>/<yyyy>/<mm>/<token><.ext>` — a date for the operator who
### looks at the bucket, a random token so two "logo.png" never fight,
### and the original extension because it is what carries the
### content-type through `static/mime-type`. The original *name* is
### metadata, not the key: filenames arrive from browsers, and a key
### derived from one would inherit its spelling, its length and its
### unicode.

(def max-length
  "Longest key we accept. S3 caps keys at 1024 bytes; a local path has
  OS limits of its own. One number, below both."
  512)

(defn valid?
  ``Is this a well-formed storage key? Non-empty, within `max-length`,
  no NUL, no backslash, relative (no leading /), slash-separated with
  no empty, "." or ".." segment.``
  [key]
  (and (string? key)
       (not (empty? key))
       (<= (length key) max-length)
       (nil? (string/find "\0" key))
       (nil? (string/find "\\" key))
       (not (string/has-prefix? "/" key))
       (all |(not (or (empty? $) (= "." $) (= ".." $)))
            (string/split "/" key))))

(defn check!
  "Refuse a malformed key with the reason in the text. Returns the key."
  [key]
  (unless (valid? key)
    (errorf (string "storage key %q is not valid: a key is a non-empty relative "
                    "path of at most %d bytes — slash-separated, no empty, \".\" "
                    "or \"..\" segment, no NUL, no backslash")
            key max-length))
  key)

(def- safe-char
  # what survives sanitize: the character classes that mean the same
  # thing in a URL, on every filesystem and in a Content-Disposition
  (do
    (def t @{})
    (loop [c :range-to [(chr "a") (chr "z")]] (put t c true))
    (loop [c :range-to [(chr "A") (chr "Z")]] (put t c true))
    (loop [c :range-to [(chr "0") (chr "9")]] (put t c true))
    (each c [(chr "-") (chr "_") (chr ".")] (put t c true))
    (freeze t)))

(defn- clean
  ``One path segment reduced to what a key may carry: every character
  outside [A-Za-z0-9._-] collapsed to "-", runs collapsed, leading and
  trailing dots and dashes stripped — which is also what turns ".."
  into nothing. May return "".``
  [s]
  (def out @"")
  (var dash false)
  (each c (string s)
    (if (in safe-char c)
      (do (buffer/push-byte out c) (set dash false))
      (unless dash (buffer/push-byte out (chr "-")) (set dash true))))
  (string/trim (string out) ".-"))

(defn sanitize-filename
  ``A browser-supplied filename reduced to something a key may carry:
  the last path segment, cleaned by `clean`. Empty in, "file" out — a
  part with no usable name still needs a key.``
  [name]
  (def base
    # browsers may send a full client path; cut at either separator
    (let [s (string (or name ""))
          cut (max (or (last (string/find-all "/" s)) -1)
                   (or (last (string/find-all "\\" s)) -1))]
      (string/slice s (inc cut))))
  (def cleaned (clean base))
  (if (empty? cleaned) "file" cleaned))

(defn extension
  "The lowercase extension of a filename, dot included — or \"\"."
  [name]
  (def s (sanitize-filename name))
  (if-let [i (last (string/find-all "." s))]
    (if (pos? i) (string/ascii-lower (string/slice s i)) "")
    ""))

(defn- token []
  (string/join (seq [x :in (os/cryptorand 8)] (string/format "%02x" x))))

(defn generate
  ``A fresh key for an upload: `<prefix>/<yyyy>/<mm>/<token><.ext>`.
  opts: :prefix (default "uploads" — sanitized segments, so a prefix is
  data too), :ext (the extension to use, dot included — what a caller
  who derived the type by other means than the filename passes; "" for
  none), :filename (only its extension survives, see the module
  docstring; :ext wins over it), :now (seconds, for tests).``
  [&opt opts]
  (default opts {})
  (def prefix
    # a prefix is data too: each segment is cleaned and the ones that
    # clean away — ".." above all — are dropped rather than defaulted
    (let [p (string (get opts :prefix "uploads"))]
      (string/join (filter |(not (empty? $)) (map clean (string/split "/" p)))
                   "/")))
  (def d (os/date (get opts :now (os/time))))
  (def ext
    # :ext is a caller's word for what the object *is* (upload derives
    # it from the declared content type); a filename is only consulted
    # without one — and either way it is cleaned like any extension
    (if-let [e (get opts :ext)]
      (extension (string "x" e))
      (extension (get opts :filename))))
  (check!
    (string (if (empty? prefix) "uploads" prefix)
            "/" (string/format "%04d/%02d" (d :year) (inc (d :month)))
            "/" (token)
            ext)))
