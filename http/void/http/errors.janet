### void/http/errors — exception -> response mapping.
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

(def- page-css
  ``The error pages' one style block — the control-room language of
  void/dash, self-contained because the kernel serves no assets: dark
  by default, light when the OS asks, mono for anything traced.``
  `:root{--bg:#101418;--panel:#171c22;--line:#2a323c;--line-soft:#232b34;
--fg:#dde4ec;--muted:#93a2b3;--accent:#4cc2ff;--danger:#f47067;color-scheme:dark}
@media (prefers-color-scheme: light){:root{--bg:#f6f7f9;--panel:#fff;--line:#d9dfe6;
--line-soft:#e6eaef;--fg:#1d242c;--muted:#5d6b7a;--accent:#0b7cc4;--danger:#c2362f;color-scheme:light}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);-webkit-font-smoothing:antialiased;
font:14px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
min-height:100vh;display:flex;align-items:center;justify-content:center;padding:2rem}
main{max-width:56rem;width:100%}
.status{font:200 4.5rem/1 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
color:var(--danger);letter-spacing:-.03em;margin:0}
h1{font-size:1.15rem;font-weight:600;letter-spacing:-.01em;margin:.5rem 0 0}
p.hint{color:var(--muted);margin:.5rem 0 0}
pre{font:12px/1.55 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
background:var(--panel);border:1px solid var(--line);border-radius:10px;
padding:1rem 1.2rem;overflow-x:auto;margin:1.5rem 0 0;white-space:pre-wrap;word-break:break-word}
dl{display:grid;grid-template-columns:auto 1fr;gap:.2rem 1.25rem;margin:1.5rem 0 0;
border-top:1px solid var(--line-soft);padding-top:1rem}
dt{color:var(--muted);font-size:.72rem;font-weight:600;letter-spacing:.08em;
text-transform:uppercase;align-self:baseline}
dd{margin:0;font:12px/1.6 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
::selection{background:rgba(76,194,255,.25)}`)

(defn- html-error-page
  ``One self-contained error page. It carries its own <style>, so it
  also carries its own Content-Security-Policy — the tightest one an
  inline-styled page can have. The security middleware keeps a CSP a
  response already set (its `unless`), so the application's policy —
  which rightly refuses inline style — never strips this page bare.``
  [status inner]
  (def resp
    (ring/html status
      (string
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        "<title>" status " " (html-escape (get wire/status-messages status "Error")) "</title>"
        "<style>" page-css "</style></head><body><main>"
        inner
        "</main></body></html>")))
  (ring/header resp "content-security-policy"
               "default-src 'none'; style-src 'unsafe-inline'"))

(defn dev-page
  "The dev error page: status, message, stacktrace, request summary."
  [err req ctx]
  (def trace (string/trim (or (ctx :stacktrace) "")))
  (html-error-page (ctx :status)
    (string
      "<p class=\"status\">" (ctx :status) "</p>"
      "<h1>" (html-escape (err-message err)) "</h1>"
      # an abort has no trace worth a panel — an empty box is noise
      (if (empty? trace) "" (string "<pre>" (html-escape trace) "</pre>"))
      "<dl><dt>method</dt><dd>" (html-escape (string (req :method))) "</dd>"
      "<dt>path</dt><dd>" (html-escape (string (req :path))) "</dd>"
      "<dt>route</dt><dd>" (html-escape (string (get-in req [:void/route :name]))) "</dd></dl>")))

(defn wants-html?
  "Is this a browser? The Accept header says text/html; an API client,
  a curl and a health probe do not. Public because the 404/405 path
  (init's route-or-404) is outside every renderer and asks the same
  question."
  [req]
  (def accept (get-in req [:headers "accept"]))
  (and (string? accept) (truthy? (string/find "text/html" accept))))

(def- status-hints
  "One human sentence under the code — recovery, not internals."
  {404 "There is nothing at this address. Check the URL, or start from the front page."
   403 "You are signed in as somebody this page is not for."
   401 "Signing in is what this page is waiting for."
   405 "This address exists, but not for the method the request used."
   408 "The request took too long to arrive. Try again."
   429 "Too many requests in a row — give it a moment, then retry."
   503 "The server is catching its breath. It answers again in a few seconds."})

(defn prod-page
  ``The error page a browser gets outside dev: the status, the
  standard phrase, one sentence of recovery — and none of the detail,
  which is the same rule problem+json follows for a 5xx.``
  [status]
  (html-error-page status
    (string
      "<p class=\"status\">" status "</p>"
      "<h1>" (html-escape (get wire/status-messages status "Error")) "</h1>"
      (if-let [hint (get status-hints status)]
        (string "<p class=\"hint\">" hint "</p>")
        ""))))

(defn default-renderer
  "The floor renderer: the dev page in dev, a presentable HTML page
  for a browser, terse text for everything else."
  [err req ctx]
  (cond
    (ctx :dev) (dev-page err req ctx)
    (wants-html? req) (prod-page (ctx :status))
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
    :on-error   (fn [req err]) hooks — the :on-error lifecycle stage
, run before the renderers; the first hook
                returning a response table wins over rendering
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
        # a :void.http/timeout cancellation must reach the server's
        # deadline branch (503 + the :on-timeout stage), not the
        # renderers — re-propagate it
        (when (and (string? err) (string/find "deadline expired" err))
          (propagate err fib))
        (def status
          (if (and (dictionary? err) (int? (err :http/status)))
            (err :http/status)
            500))
        (def trace (when fib (stacktrace-str fib err)))
        (when (>= status 500)
          (log err req trace))
        (var hooked nil)
        # :on-error may be the hooks themselves or (fn [req] hooks) —
        # the route layer adds per-route hooks at request time
        (def eh (get opts :on-error []))
        (each h (if (indexed? eh) eh (eh req))
          (when (nil? hooked)
            (def [ok r] (protect (h req err)))
            (when (and ok (dictionary? r) (r :status))
              (set hooked r))))
        (or hooked
            (render (opts :renderers) err req
                    {:status status
                     :dev (opts :dev)
                     :stacktrace trace}))))))
