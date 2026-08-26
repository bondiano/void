### void/http/multipart — multipart/form-data parsing (SPEC.md §5.1).
###
### Pure functions over a fully-read body buffer (the server enforces
### :void.http/max-body before anything lands here; streaming uploads
### are a later wave). parse returns one table per part: form fields
### carry :name/:value, file parts add :filename/:content-type. The
### parts middleware exposes them as (req :multipart) and folds plain
### fields into (req :form).

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

(defn- parse-disposition [headers]
  (def out @{})
  (when-let [d (get headers "content-disposition")]
    (when-let [m (peg/match disposition-peg d)]
      (loop [i :range [1 (length m) 2]]
        (put out (keyword (string/ascii-lower (m i))) (m (inc i))))))
  out)

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
