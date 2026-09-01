### void/http/static — static file serving (SPEC.md §5.1).
###
### file-response serves one file with a strong ETag (size-mtime),
### If-None-Match conditional GETs and single-part Range requests;
### wrap-static mounts a directory under a URL prefix in front of a
### handler. Percent-encoded paths are decoded and any dot-dot segment
### is rejected before the filesystem is consulted — traversal is cut
### at the path level, symlinks inside the root are the deployer's
### policy. Files are read whole (buffer body); files larger than
### :max-file-size (10 MB default) are refused in favor of a CDN/proxy
### story rather than quietly ballooning the heap.

(import ./ring :as ring)

(def mime-types
  "File extension -> content-type."
  {"html" "text/html; charset=utf-8"
   "htm" "text/html; charset=utf-8"
   "css" "text/css; charset=utf-8"
   "js" "text/javascript; charset=utf-8"
   "mjs" "text/javascript; charset=utf-8"
   "json" "application/json"
   "map" "application/json"
   "txt" "text/plain; charset=utf-8"
   "md" "text/markdown; charset=utf-8"
   "xml" "application/xml"
   "svg" "image/svg+xml"
   "png" "image/png"
   "jpg" "image/jpeg"
   "jpeg" "image/jpeg"
   "gif" "image/gif"
   "webp" "image/webp"
   "avif" "image/avif"
   "ico" "image/x-icon"
   "woff" "font/woff"
   "woff2" "font/woff2"
   "ttf" "font/ttf"
   "otf" "font/otf"
   "wasm" "application/wasm"
   "pdf" "application/pdf"
   "zip" "application/zip"
   "gz" "application/gzip"
   "mp3" "audio/mpeg"
   "mp4" "video/mp4"
   "webm" "video/webm"})

(def- fallback-mime "application/octet-stream")

(defn mime-type
  "content-type for a file path, by extension."
  [path]
  (def ext
    (if-let [i (last (seq [j :range [0 (length path)]
                           :when (= (chr ".") (path j))] j))]
      (string/ascii-lower (string/slice path (inc i)))
      ""))
  (get mime-types ext fallback-mime))

(def- decode-peg
  (peg/compile
    ~{:chr (+ (* "%" (/ (number (* :h :h) 16) ,string/from-bytes)) '1)
      :main (% (any :chr))}))

(defn path-decode
  "Percent-decode a URL path (no +-to-space — that is query syntax).
  Returns nil on a malformed escape."
  [path]
  (when-let [m (peg/match decode-peg path)]
    (first m)))

(defn safe-join
  ``Resolve a decoded URL path under a root directory, or nil when the
  path escapes it (.. segments) or contains NUL. Empty segments
  collapse ("//" is fine, it cannot climb).``
  [root path]
  (when (and path (nil? (string/find "\0" path)))
    (def segs (filter |(not (or (empty? $) (= "." $)))
                      (string/split "/" path)))
    (unless (some |(= ".." $) segs)
      (string root "/" (string/join segs "/")))))

(defn etag
  "Strong ETag from a file's stat: \"<size>-<mtime>\"."
  [st]
  (string/format "\"%x-%x\"" (st :size) (math/trunc (* 1000 (st :modified)))))

(def- range-peg
  (peg/compile
    ~(* "bytes=" (+ (* (number :d+) "-" (+ (number :d+) (constant :eof)))
                    (* (constant :suffix) "-" (number :d+)))
        -1)))

(defn- parse-range
  "One satisfiable [start end-inclusive] from a Range header against a
  file size, nil to serve the whole file, :unsatisfiable for a 416.
  Multi-range requests are ignored (whole file) — valid per RFC 9110."
  [header size]
  (cond
    (nil? header) nil
    (string/find "," header) nil
    (do
      (def m (peg/match range-peg header))
      (cond
        (nil? m) nil
        (= :suffix (m 0))
        (if (or (zero? (m 1)) (zero? size))
          :unsatisfiable
          [(max 0 (- size (m 1))) (dec size)])
        (let [[start end] m]
          (cond
            (>= start size) :unsatisfiable
            [start (if (= :eof end) (dec size) (min end (dec size)))]))))))

(defn file-response
  ``Serve one file: 200 (or 206 on a satisfiable Range), 304 on a
  matching If-None-Match, 416 with content-range on an unsatisfiable
  range, nil when the path is not a regular file. Options: :mime
  (override), :max-file-size (bytes, default 10485760), :headers
  (extra response headers).``
  [req path &opt opts]
  (default opts {})
  (def st (os/stat path))
  (when (and st (= :file (st :mode)))
    (def tag (etag st))
    (def base @{"etag" tag
                "accept-ranges" "bytes"
                "content-type" (or (opts :mime) (mime-type path))})
    (when-let [extra (opts :headers)] (merge-into base extra))
    (if (= tag (ring/request-header req "if-none-match"))
      (ring/response 304 nil base)
      (do
        (when (> (st :size) (get opts :max-file-size 10485760))
          (errorf "static file %s is %d bytes — over :max-file-size; serve it from a proxy/CDN"
                  path (st :size)))
        (def range (parse-range (ring/request-header req "range") (st :size)))
        (case range
          :unsatisfiable
          (ring/response 416 nil
                         @{"content-range" (string/format "bytes */%d" (st :size))})

          nil
          (ring/response 200 (slurp path) base)

          (let [[start end] range]
            (ring/response 206
                           (string/slice (slurp path) start (inc end))
                           (merge-into base
                                       @{"content-range"
                                         (string/format "bytes %d-%d/%d"
                                                        start end (st :size))}))))))))

(defn wrap-static
  ``Middleware serving files from :root under :prefix (default "/") in
  front of the handler; GET and HEAD only. A directory path serves its
  :index (default "index.html") when present. Falls through to the
  handler on any miss.``
  [handler opts]
  (def root (or (opts :root) (error "wrap-static requires :root")))
  (def prefix (get opts :prefix "/"))
  (def index (get opts :index "index.html"))
  (fn static-handler [req]
    (def path (req :path))
    (if (and (in {:get true :head true} (req :method))
             (string/has-prefix? prefix path))
      (do
        (def rel (path-decode (string/slice path (length prefix))))
        (def full (safe-join root rel))
        (def target
          (when full
            (if (= :directory (get (os/stat full) :mode))
              (string full "/" index)
              full)))
        (or (when target (file-response req target opts))
            (handler req)))
      (handler req))))
