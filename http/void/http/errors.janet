### void/http/errors — exception -> response mapping (SPEC.md §5.1,
### ROADMAP 1.1).
###
### wrap-panic is the phase-0 panic guard: everything a route chain
### throws becomes a response instead of a dropped connection. A
### structured throw `(error {:http/status 422 :message "..."})` — the
### `abort` helper — keeps its status; anything else is a 500. The
### response is produced by the :void.http/error-renderer contributions
### in priority order (first non-nil wins) with the built-in renderer
### as the floor: a terse text/plain in prod, a full HTML page with the
### stacktrace and request summary in dev. Renderer contract:
### (fn [err req ctx] response|nil), ctx = {:status :dev :stacktrace}.

(import ./ring :as ring)
(import ./wire :as wire)

(defn abort
  "Throw a structured HTTP error caught by wrap-panic:
  (abort 404) (abort 422 \"invalid state\")."
  [status &opt message]
  (error {:http/status status :message message}))

(defn- html-escape [s]
  (->> (string s)
       (string/replace-all "&" "&amp;")
       (string/replace-all "<" "&lt;")
       (string/replace-all ">" "&gt;")))

(defn stacktrace-str
  "Render a fiber's stacktrace for an error value into a string."
  [fib err]
  (def out @"")
  (with-dyns [*err* out *err-color* false]
    (debug/stacktrace fib err ""))
  (string out))

(defn- err-message [err]
  (cond
    (and (dictionary? err) (err :message)) (string (err :message))
    (dictionary? err) (get wire/status-messages
                           (get err :http/status 500) "error")
    (string? err) err
    (describe err)))

(defn dev-page
  "The dev error page: message, stacktrace, request summary."
  [err req ctx]
  (def title (string (ctx :status) " — " (err-message err)))
  (ring/html (ctx :status)
    (string
      "<!doctype html><html><head><meta charset=\"utf-8\">"
      "<title>" (html-escape title) "</title>"
      "<style>body{font:14px/1.5 monospace;margin:2rem;background:#181820;color:#e8e8f0}"
      "h1{font-size:1.2rem;color:#ff6b6b}pre{background:#22222c;padding:1rem;"
      "overflow-x:auto;border-radius:4px}dt{color:#8be9fd}</style></head><body>"
      "<h1>" (html-escape title) "</h1>"
      "<pre>" (html-escape (or (ctx :stacktrace) "")) "</pre>"
      "<dl><dt>method</dt><dd>" (html-escape (string (req :method))) "</dd>"
      "<dt>path</dt><dd>" (html-escape (string (req :path))) "</dd>"
      "<dt>route</dt><dd>" (html-escape (string (get-in req [:void/route :name]))) "</dd></dl>"
      "</body></html>")))

(defn default-renderer
  "The floor renderer: dev page in dev, terse text otherwise."
  [err req ctx]
  (if (ctx :dev)
    (dev-page err req ctx)
    (ring/text (ctx :status)
               (string (ctx :status) " "
                       (get wire/status-messages (ctx :status) "Error")))))

(defn render
  "Run the renderers (sorted contributions of :void.http/error-renderer)
  over an error; the first response wins, default-renderer is the
  guaranteed fallback."
  [renderers err req ctx]
  (or (some (fn [r]
              (def [ok resp] (protect ((r :fn) err req ctx)))
              (if ok
                resp
                (do (eprintf "error renderer %q failed: %s"
                             (r :name) (if (string? resp) resp (describe resp)))
                    nil)))
            (or renderers []))
      (default-renderer err req ctx)))

(defn wrap-panic
  ``The phase-0 panic guard. Options:
    :renderers  :void.http/error-renderer contributions, priority order
    :dev        truthy exposes stacktraces (dev error page)
    :log        (fn [err req trace]) — 500s reach it (aborts do not);
                default prints to stderr``
  [handler &opt opts]
  (default opts {})
  (def log (get opts :log
                (fn [err req trace]
                  (eprintf "http panic on %q %s: %s\n%s"
                           (req :method) (req :path) (err-message err)
                           (or trace "")))))
  (fn panic-guard [req]
    (try
      (handler req)
      ([err fib]
        (def status
          (if (and (dictionary? err) (int? (err :http/status)))
            (err :http/status)
            500))
        (def trace (when fib (stacktrace-str fib err)))
        (when (>= status 500)
          (log err req trace))
        (render (opts :renderers) err req
                {:status status
                 :dev (opts :dev)
                 :stacktrace trace})))))
