### void/http/errors — exception -> response mapping.
###
### wrap-panic is the phase-0 panic guard: everything a route chain
### throws becomes a response instead of a dropped connection. An
### error envelope (void/core/errors — `abort` builds one) keeps its
### status; a v1 `{:http/status N}` dictionary is read the same way;
### anything else is a 500. The response is produced by the
### :void.http/error-renderer contributions in priority order (first
### non-nil wins) with the built-in renderer as the floor: a terse
### text/plain in prod, a presentable page for a browser, a full HTML
### page with the stacktrace and request summary in dev. Renderer
### contract: (fn [err req ctx] response|nil), ctx = {:status :dev
### :stacktrace :error} — `err` is the value as raised (the v1
### contract), `:error` its envelope (`errors/of`), so a renderer
### branches on `(errors/kind (ctx :error))` without normalizing.
###
### This chain is the one negotiator of error format in void: rest
### contributes problem+json, grpc the Connect status, the floor the
### page or the line. Every refusal goes through it — the 404/405 of
### an unrouted path (init's route-or-404), an auth challenge, a
### shed request — which is what makes an API client see problem+json
### on a path that does not exist, and not somebody's text/plain.

(import void/core/errors :as errors)
(import void/core/keys :as keys)
(import void/core/text :as text)
(import ./ring :as ring)
(import ./wire :as wire)

(errors/define! :void.http/not-found
  {:status 404 :doc "no route matched the path"})
(errors/define! :void.http/method-not-allowed
  {:status 405 :doc "the path exists, the method does not; :data {:allowed [...]}"})
(errors/define! :void.http/bad-request
  {:status 400 :doc "the request could not be read: a body its codec cannot decode, malformed signals"})

(defn abort
  {:params [:number :string? (or {:keyword :any} :nil)]
   :ret :never
   :throws [{:void/error :keyword :message :string? :data {:keyword :any}
            :status :number :http/status :number}]}
  ``Throw an HTTP error the panic guard answers with its status:
  (abort 404) (abort 422 "invalid state"). An envelope of kind
  :void.http/abort — `(errors/raise kind message data)` is the same
  throw with a kind of one's own.``
  [status &opt message data]
  (errors/raise :void.http/abort message data status))

(defn- html-escape
  {:params [:any] :ret :string}
  "Escape &, < and > for safe interpolation into HTML markup."
  [s]
  (->> (string s)
       (string/replace-all "&" "&amp;")
       (string/replace-all "<" "&lt;")
       (string/replace-all ">" "&gt;")))

(defn stacktrace-str
  {:params [:fiber :any] :ret :string}
  "Render a fiber's stacktrace for an error value into a string."
  [fib err]
  (def out @"")
  (with-dyns [*err* out *err-color* false]
    (debug/stacktrace fib err ""))
  (string out))

(defn- err-message
  {:params [:any] :ret :string}
  "The one-line human message for a caught error: its own :message or
  a translated one when a locale is bound, else the status's standard
  phrase."
  [err]
  (def env (errors/of err))
  (if (or (get env :message) (get (dyn :void.errors/messages {}) (errors/kind env)))
    (errors/message env)
    (get wire/status-messages (errors/status env) "error")))

(def en
  ``The error pages' own words. One sentence under the code —
  recovery, not internals — per status a visitor can do something
  about. The table is the only place they are spelled: `text/t` asks
  the bound catalog first, so an application translates a hint by
  contributing `:void.http/hint-404` and this package learns nothing
  about locales.``
  {:void.http/hint-404 "There is nothing at this address. Check the URL, or start from the front page."
   :void.http/hint-403 "You are signed in as somebody this page is not for."
   :void.http/hint-401 "Signing in is what this page is waiting for."
   :void.http/hint-405 "This address exists, but not for the method the request used."
   :void.http/hint-408 "The request took too long to arrive. Try again."
   :void.http/hint-429 "Too many requests in a row — give it a moment, then retry."
   :void.http/hint-503 "The server is catching its breath. It answers again in a few seconds."})

(def- t (text/translator en))

(defn- status-title
  {:params [:number] :ret :string}
  ``The phrase next to the code. The reason phrases are the protocol's
  own English and this package ships no translation of them — but a
  catalog that carries `:void.http/status-404` is a catalog that means
  to translate the page, and it wins.``
  [status]
  (or (text/t? (keyword "void.http/status-" status))
      (get wire/status-messages status "Error")))

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
  {:params [:number :string] :ret @{:headers @{:string :any} & r}}
  ``One self-contained error page. It carries its own <style>, so it
  also carries its own Content-Security-Policy — the tightest one an
  inline-styled page can have. The security middleware keeps a CSP a
  response already set (its `unless`), so the application's policy —
  which rightly refuses inline style — never strips this page bare.``
  [status inner]
  (def resp
    (ring/html status
      (string
        "<!doctype html><html lang=\"" (html-escape (or (text/locale) :en)) "\">"
        "<head><meta charset=\"utf-8\">"
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
        "<title>" status " " (html-escape (status-title status)) "</title>"
        "<style>" page-css "</style></head><body><main>"
        inner
        "</main></body></html>")))
  (ring/header resp "content-security-policy"
               "default-src 'none'; style-src 'unsafe-inline'"))

(defn dev-page
  {:params [:any @{:method :keyword :path :string & r}
            {:status :number :dev :any :stacktrace :string? :error :any}]
   :ret @{:headers @{:string :any} & r}}
  "The dev error page: status, message, stacktrace, request summary."
  [err req ctx]
  (def trace (string/trim (or (ctx :stacktrace) "")))
  (html-error-page (ctx :status)
    (string
      "<p class=\"status\">" (ctx :status) "</p>"
      "<h1>" (html-escape (err-message err)) "</h1>"
      "<p class=\"hint\">" (html-escape (string (errors/kind err))) "</p>"
      # an abort has no trace worth a panel — an empty box is noise
      (if (empty? trace) "" (string "<pre>" (html-escape trace) "</pre>"))
      "<dl><dt>method</dt><dd>" (html-escape (string (req :method))) "</dd>"
      "<dt>path</dt><dd>" (html-escape (string (req :path))) "</dd>"
      "<dt>route</dt><dd>" (html-escape (string (get-in req [keys/route :name]))) "</dd></dl>")))

(defn wants-html?
  {:params [@{:headers {:string (or :string @[:string])} & r}]
   :ret :boolean :narrows :any}
  "Is this a browser? The Accept header says text/html; an API client,
  a curl and a health probe do not. Public because the 404/405 path
  (init's route-or-404) is outside every renderer and asks the same
  question."
  [req]
  (def accept (get-in req [:headers "accept"]))
  (and (string? accept) (truthy? (string/find "text/html" accept))))

(defn- hint
  {:params [:number] :ret :string?}
  "The translated one-sentence recovery hint for a status, or nil when
  this package has none for it."
  [status]
  (def key (keyword "void.http/hint-" status))
  (when (get en key) (t key)))

(defn prod-page
  {:params [:number] :ret @{:headers @{:string :any} & r}}
  ``The error page a browser gets outside dev: the status, the
  standard phrase, one sentence of recovery — and none of the detail,
  which is the same rule problem+json follows for a 5xx.``
  [status]
  (html-error-page status
    (string
      "<p class=\"status\">" status "</p>"
      "<h1>" (html-escape (status-title status)) "</h1>"
      (if-let [h (hint status)]
        (string "<p class=\"hint\">" (html-escape h) "</p>")
        ""))))

(defn default-renderer
  {:params [:any @{:method :keyword :path :string :headers {:string (or :string @[:string])} & r}
            {:status :number :dev :any :stacktrace :string? :error :any}]
   :ret @{:headers @{:string :any} & r}}
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
  {:params [(or @[{:fn (or :function :cfunction) :name :keyword & r}] :nil)
            :any
            @{:method :keyword :path :string :headers {:string (or :string @[:string])} & r}
            {:status :number :dev :any :stacktrace :string? :error :any}]
   :ret @{:headers @{:string :any} & r}}
  ``Run the renderers (sorted contributions of
  :void.http/error-renderer) over an error; the first response wins,
  default-renderer is the guaranteed fallback.

  Inside the request's own locale scope, when it carries one. This
  guard is phase 0 and `render-error` is called from outside any route
  at all, so by the time a refusal becomes a page the dyns a locale
  middleware bound are gone with the stack — or were never bound,
  because no route matched and no middleware ran. The request survives
  both, and `void/core/text` is what a renderer reads the locale
  through. It goes here and not in `wrap-panic` because this is the
  one place every refusal renders: the thrown ones and the ones
  `render-error` asks for without a throw.``
  [renderers err req ctx]
  (text/in-scope req
    (fn render-in-locale []
      (or (some (fn [r]
                  (def [ok resp] (protect ((r :fn) err req ctx)))
                  (if ok
                    resp
                    (do (eprintf "error renderer %q failed: %s"
                                 (r :name) (if (string? resp) resp (describe resp)))
                        nil)))
                (or renderers []))
          (default-renderer err req ctx)))))

(defn wrap-panic
  {:params [(or :function :cfunction)
            (or {:renderers (or @[{:fn (or :function :cfunction) :name :keyword & r}] :nil)
                 :dev :any
                 :on-error (or @[(or :function :cfunction)] :function :cfunction :nil)
                 :log (or (fn [:any :any :string?] :any) :nil)
                 & r}
                :nil)]
   :ret :function}
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
        (when (errors/deadline? err)
          (propagate err fib))
        (def env (errors/of err))
        (def status (errors/status env))
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
        # `render` puts the request's locale scope back around the
        # renderers; the log above stays outside it on purpose — a log
        # in the visitor's language is a log nobody can grep
        (or hooked
            (render (opts :renderers) err req
                    {:status status
                     :dev (opts :dev)
                     :stacktrace trace
                     :error env}))))))
