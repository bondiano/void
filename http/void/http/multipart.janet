### void/http/multipart — multipart/form-data, both ways (SPEC.md §5.1).
###
### Pure functions over a fully-read body buffer (the server enforces
### :void.http/max-body before anything lands here; streaming uploads
### are a later wave). parse returns one table per part: form fields
### carry :name/:value, file parts add :filename/:content-type. The
### parts middleware exposes them as (req :multipart) and folds plain
### fields into (req :form).
###
### `encode` is the same table list turned back into a body, which is
### what void/http/client posts when it uploads a file. It is here and
### not in the client for the reason the parser is here: the boundary
### rules, the header block and the CRLF framing are one format, and a
### second copy of them would drift from this one. It also makes the
### parser testable against its own output.

(def- disposition-peg
  # content-disposition: form-data; name="a"; filename="b.txt"
  (peg/compile
    ~{:ows (any (set " \t"))
      :token '(some (if-not (set ";= \t\"") 1))
      :quoted (* "\"" '(any (if-not "\"" 1)) "\"")
      :value (+ :quoted :token)
      :param (* :ows ";" :ows :token :ows "=" :ows :value)
      :main (* :ows :token (any :param) :ows -1)}))

(defn boundary
  "Extract the boundary from a multipart content-type header value, or
  nil when the header is not multipart or carries no boundary."
  [content-type]
  (when (and content-type
             (string/has-prefix? "multipart/" (string/ascii-lower content-type)))
    (when-let [m (peg/match disposition-peg content-type)]
      (var out nil)
      (loop [i :range [1 (length m) 2]]
        (when (= "boundary" (string/ascii-lower (m i)))
          (set out (m (inc i)))))
      out)))

(defn- parse-part-headers [chunk]
  (def headers @{})
  (each line (string/split "\r\n" chunk)
    (when-let [i (string/find ":" line)]
      (put headers
           (string/ascii-lower (string/slice line 0 i))
           (string/trim (string/slice line (inc i))))))
  headers)

(defn content-disposition
  ``Parse a `Content-Disposition` header value into
  `{:type "form-data" :name "avatar" :filename "me.png"}` — the
  parameters as keywords, the disposition type under `:type`. Returns
  an empty table for a value that parses as nothing.

  Public because it is not only a multipart concern: a *response*
  carries this header when a server hands over a download, and
  void/http/client's caller reads the filename out of it with the same
  function this module already needed.``
  [value]
  (def out @{})
  (when value
    (when-let [m (peg/match disposition-peg (string value))]
      (put out :type (first m))
      (loop [i :range [1 (length m) 2]]
        (put out (keyword (string/ascii-lower (m i))) (m (inc i))))))
  out)

(defn- parse-disposition [headers]
  (content-disposition (get headers "content-disposition")))

(defn parse
  ``Parse a multipart body against its boundary into parts:

      [{:name "avatar" :filename "me.png"
        :content-type "image/png" :headers {...} :value <bytes>} ...]

  Malformed framing is an error (the parsing middleware turns it into
  a 400).``
  [body bnd]
  (def dash (string "--" bnd))
  (def parts @[])
  (var pos (or (string/find dash body)
               (errorf "multipart body has no boundary %q" bnd)))
  (+= pos (length dash))
  (while true
    (when (= "--" (string/slice body pos (min (+ pos 2) (length body))))
      (break))
    (unless (= "\r\n" (string/slice body pos (min (+ pos 2) (length body))))
      (errorf "multipart: expected CRLF after boundary at byte %d" pos))
    (+= pos 2)
    (def hdr-end (or (string/find "\r\n\r\n" body pos)
                     (errorf "multipart: part headers not terminated")))
    (def headers (parse-part-headers (string/slice body pos hdr-end)))
    (def content-start (+ hdr-end 4))
    (def next-dash (or (string/find (string "\r\n" dash) body content-start)
                       (errorf "multipart: part content not terminated")))
    (def disp (parse-disposition headers))
    (array/push parts
                @{:name (disp :name)
                  :filename (disp :filename)
                  :content-type (get headers "content-type")
                  :headers headers
                  :value (string/slice body content-start next-dash)})
    (set pos (+ next-dash 2 (length dash))))
  parts)

(defn fields
  "Fold the non-file parts into a name -> value table (duplicate names
  accumulate into arrays), like a urlencoded form."
  [parts]
  (def out @{})
  (each p parts
    (when (and (p :name) (nil? (p :filename)))
      (def prev (get out (p :name)))
      (put out (p :name)
           (cond
             (nil? prev) (p :value)
             (indexed? prev) (array/push prev (p :value))
             @[prev (p :value)]))))
  out)

# -- building ------------------------------------------------------------

(defn new-boundary
  ``A boundary no body will contain: a fixed prefix and sixteen random
  hex characters. Random rather than derived from the content, because
  a boundary chosen by scanning the parts would have to scan them all
  again after every edit — and the parts are files.``
  []
  (string "----voidFormBoundary"
          (string/join (seq [x :in (os/cryptorand 8)] (string/format "%02x" x)))))

(defn- quote-param [s]
  # RFC 6266's quoted-string: a filename may carry a space, and a
  # backslash or a quote in one is escaped rather than refused —
  # the name comes from a caller who chose it, not from the wire
  (string "\"" (string/replace-all "\"" "\\\"" (string/replace-all "\\" "\\\\" (string s))) "\""))

(defn part-head
  ``The header block of one part, without the boundary line. `part` is
  the same table `parse` returns: `:name` (required), `:filename` and
  `:content-type` optional, plus any extra `:headers`.``
  [part]
  (def name (or (part :name) (error "multipart: a part needs a :name")))
  (def out @"")
  (buffer/format out "Content-Disposition: form-data; name=%s" (quote-param name))
  (when-let [f (part :filename)]
    (buffer/format out "; filename=%s" (quote-param f)))
  (buffer/push-string out "\r\n")
  (when-let [ct (part :content-type)]
    (buffer/format out "Content-Type: %s\r\n" ct))
  (eachp [k v] (get part :headers {})
    (def key (string/ascii-lower (string k)))
    (unless (or (= key "content-disposition") (= key "content-type"))
      (buffer/format out "%s: %V\r\n" key v)))
  (string out))

(defn encode
  ``Build a `multipart/form-data` body out of parts:

      (multipart/encode
        [{:name "title" :value "cat"}
         {:name "avatar" :filename "me.png"
          :content-type "image/png" :value bytes}])
      # -> {:body <bytes> :boundary "..." :content-type "multipart/form-data; boundary=..."}

  The inverse of `parse`, and what a client posts when it uploads a
  file. A value may be any byte sequence; a part with a `:filename`
  is a file part, one without is a form field.``
  [parts &opt bnd]
  (def boundary (or bnd (new-boundary)))
  (def out (buffer/new 1024))
  (each part parts
    (buffer/format out "--%s\r\n%s\r\n" boundary (part-head part))
    (buffer/push out (or (part :value) ""))
    (buffer/push-string out "\r\n"))
  (buffer/format out "--%s--\r\n" boundary)
  {:body (string out)
   :boundary boundary
   :content-type (string "multipart/form-data; boundary=" boundary)})
