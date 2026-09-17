### void/html/chrome — the framework's own pages, in one language.
###
### void/admin and void/dash draw the same control room — dark by
### default, light when the OS asks, one cyan accent for the
### interactive, the three status hues reserved for status, tabular
### numerals for anything that counts — and until wave 8.8 each carried
### its own copy of the tokens and the rules, under its own class
### prefix, drifting a declaration at a time. This module is the one
### copy: the tokens, the base sheet over `.vd-*` classes, and the
### three mechanics both plugins had also written twice — a URL under a
### mount prefix, a served asset with a content-addressed name, and the
### route that serves it.
###
### The kernel's error page (void/http/errors) is the one page that
### keeps a sheet of its own: void/http cannot import the view layer
### that depends on it, and the page must render in a composition
### without void/html. Its tokens are these, by hand.
###
### An application does not have to speak this language: `[:admin
### :stylesheet]` replaces the admin's sheet whole, `:void.admin/layout`
### replaces its frame, and nothing here reaches a page the application
### renders itself.

(import void/http/router :as router)
(import ./assets :as assets)

# -- the tokens ----------------------------------------------------------

(def tokens
  ``The palette and the type, as custom properties on :root — dark, and
  light under prefers-color-scheme. Every rule in `base-sheet` reads
  these and nothing else, which is why both palettes are one sheet.``
  `
:root {
  --bg:#101418; --panel:#171c22; --panel-2:#1d242c; --soft:#1d242c;
  --line:#2a323c; --line-soft:#232b34;
  --fg:#dde4ec; --muted:#93a2b3;
  --accent:#4cc2ff; --accent-soft:rgba(76,194,255,.12); --accent-strong:#1685c9;
  --ok:#3fd68f; --warn:#e3b341; --danger:#f47067;
  --ok-soft:rgba(63,214,143,.12); --warn-soft:rgba(227,179,65,.14); --danger-soft:rgba(244,112,103,.12);
  --shadow:0 1px 2px rgba(0,0,0,.4), 0 4px 16px rgba(0,0,0,.25);
  --mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  --bar-height:2.9rem;
  color-scheme:dark;
}
@media (prefers-color-scheme: light) {
  :root {
    --bg:#f6f7f9; --panel:#ffffff; --panel-2:#f0f3f6; --soft:#f0f3f6;
    --line:#d9dfe6; --line-soft:#e6eaef;
    --fg:#1d242c; --muted:#5d6b7a;
    --accent:#0b7cc4; --accent-soft:rgba(11,124,196,.1); --accent-strong:#0b7cc4;
    --ok:#15803d; --warn:#8a6400; --danger:#c2362f;
    --ok-soft:rgba(21,128,61,.1); --warn-soft:rgba(138,100,0,.12); --danger-soft:rgba(194,54,47,.09);
    --shadow:0 1px 2px rgba(29,36,44,.06), 0 4px 16px rgba(29,36,44,.05);
    color-scheme:light;
  }
}
`)

# -- the base sheet ------------------------------------------------------

(def base-sheet
  ``The rules every framework page shares, over `.vd-*` classes: the
  bar and its navigation, type, tables with a sticky head, controls,
  toolbars, forms and their errors, cards, badges, warnings, the pager,
  and the settle animation. A plugin's sheet is this string followed by
  its own rules. No build step, no inline style, one served file.``
  (string tokens `
* { box-sizing:border-box; }
html { scrollbar-color:var(--line) transparent; }
body { margin:0; font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
       color:var(--fg); background:var(--bg);
       -webkit-font-smoothing:antialiased; caret-color:var(--accent); }
::selection { background:var(--accent-soft); color:inherit; }
::-webkit-scrollbar { width:10px; height:10px; }
::-webkit-scrollbar-thumb { background:var(--line); border-radius:5px; border:2px solid var(--bg); }
::-webkit-scrollbar-track { background:transparent; }
:focus-visible { outline:2px solid var(--accent); outline-offset:2px; border-radius:2px; }
a { color:var(--accent); text-decoration:none; }
a:hover { text-decoration:underline; text-underline-offset:3px; }

/* -- the bar ----------------------------------------------------------- */
header.vd-bar { position:sticky; top:0; z-index:10;
                display:flex; align-items:center; gap:1.25rem;
                padding:0 1.25rem; height:var(--bar-height);
                border-bottom:1px solid var(--line); background:var(--panel); }
header.vd-bar .vd-title { font-weight:650; letter-spacing:-.01em; white-space:nowrap; }
nav.vd-nav { display:flex; gap:.25rem; overflow-x:auto; scrollbar-width:none; }
nav.vd-nav::-webkit-scrollbar { display:none; }
nav.vd-nav a { color:var(--muted); padding:.35rem .6rem; border-radius:6px;
               font-size:.92rem; white-space:nowrap; transition:color .15s, background .15s; }
nav.vd-nav a:hover { color:var(--fg); background:var(--panel-2); text-decoration:none; }
nav.vd-nav a.active { color:var(--fg); background:var(--accent-soft); font-weight:600; }
nav.vd-nav .vd-nav-group { color:var(--muted); font-size:.72rem; font-weight:600;
                           letter-spacing:.08em; text-transform:uppercase;
                           padding:.45rem .6rem .35rem .9rem; white-space:nowrap; }
.vd-bar-meta { margin-left:auto; color:var(--muted); font:11px/1 var(--mono); white-space:nowrap; }
@media (max-width: 40rem) { .vd-bar-meta { display:none; } }
main.vd-main { padding:1.5rem 1.25rem 3rem; max-width:88rem; margin:0 auto; }

/* -- type -------------------------------------------------------------- */
h1 { font-size:1.3rem; font-weight:650; letter-spacing:-.015em; margin:0 0 1rem; }
h2 { font-size:.98rem; font-weight:650; letter-spacing:-.005em; margin:1.75rem 0 .6rem; }
code, pre { font:12px/1.5 var(--mono); }
.vd-count { font-variant-numeric:tabular-nums; }
.vd-note { color:var(--muted); font-size:.85rem; margin:.25rem 0; }
.vd-empty { color:var(--muted); padding:1rem 0; }
.vd-absent { color:var(--muted); font-style:italic; }

/* -- tables ------------------------------------------------------------- */
/* rounded via the corner cells, not overflow:hidden — a clipped table
   lets scrolled rows peek out over its own sticky header */
table.vd-table { border-collapse:separate; border-spacing:0; width:100%;
                 border:1px solid var(--line); border-radius:10px;
                 background:var(--panel); box-shadow:var(--shadow); }
table.vd-table th, table.vd-table td { text-align:left; padding:.45rem .8rem;
                                       border-bottom:1px solid var(--line-soft);
                                       vertical-align:top; }
table.vd-table thead th { position:sticky; top:var(--bar-height); z-index:5; background:var(--panel-2);
                          color:var(--muted); font-size:.72rem; font-weight:600;
                          letter-spacing:.08em; text-transform:uppercase; white-space:nowrap;
                          border-bottom:1px solid var(--line); }
table.vd-table thead th:first-child { border-top-left-radius:9px; }
table.vd-table thead th:last-child { border-top-right-radius:9px; }
table.vd-table tbody tr:last-child td { border-bottom:none; }
table.vd-table tbody tr:last-child td:first-child { border-bottom-left-radius:9px; }
table.vd-table tbody tr:last-child td:last-child { border-bottom-right-radius:9px; }
table.vd-table tbody tr { transition:background .15s; }
table.vd-table tbody tr:hover { background:var(--panel-2); }
table.vd-table td { font-variant-numeric:tabular-nums; }

/* -- controls ------------------------------------------------------------ */
input, select, textarea { font:inherit; padding:.35rem .55rem; border:1px solid var(--line);
                          border-radius:7px; background:var(--panel); color:inherit;
                          transition:border-color .15s; }
input::placeholder, textarea::placeholder { color:var(--muted); }
input:hover, select:hover, textarea:hover { border-color:var(--muted); }
input:focus, select:focus, textarea:focus { border-color:var(--accent); outline:none;
                                            box-shadow:0 0 0 3px var(--accent-soft); }
textarea { min-height:8rem; width:100%; }
button, .vd-button { font:inherit; font-weight:550; padding:.35rem .8rem;
                     border:1px solid var(--line); border-radius:7px;
                     background:var(--panel-2); cursor:pointer; color:inherit;
                     transition:border-color .15s, background .15s, color .15s; }
button:hover, .vd-button:hover { border-color:var(--muted); text-decoration:none; }
button:active { background:var(--line-soft); }
button.primary { background:var(--accent-strong); border-color:var(--accent-strong); color:#fff; }
button.primary:hover { filter:brightness(1.1); border-color:var(--accent-strong); }
button.danger, .vd-button.danger { color:var(--danger); }
button.danger:hover, .vd-button.danger:hover { border-color:var(--danger);
                                               background:var(--danger-soft); }
.vd-toolbar { display:flex; gap:1rem; align-items:flex-end; flex-wrap:wrap; margin-bottom:1rem; }
.vd-toolbar .field { display:flex; flex-direction:column; gap:.2rem; }
.vd-toolbar label { color:var(--muted); font-size:.72rem; font-weight:600;
                    letter-spacing:.06em; text-transform:uppercase; }
.vd-actions { display:flex; gap:.5rem; align-items:center; margin:1rem 0; flex-wrap:wrap; }
.vd-pager { display:flex; gap:.5rem; align-items:center; margin-top:1rem; color:var(--muted); }
form.vd-inline { display:inline; }

/* -- forms --------------------------------------------------------------- */
.vd-form .field { margin-bottom:1rem; max-width:44rem; }
.vd-form label { display:block; color:var(--muted); font-size:.8rem; margin-bottom:.2rem; }
.vd-form input[type=text], .vd-form input[type=email], .vd-form input[type=number],
.vd-form input[type=url], .vd-form input[type=date], .vd-form input[type=password],
.vd-form select { width:100%; max-width:44rem; }
.field-help { color:var(--muted); font-size:.8rem; margin:.2rem 0 0; }
.field-errors, .form-errors { color:var(--danger); margin:.25rem 0 0; padding-left:1rem; }
.field-invalid input, .field-invalid select, .field-invalid textarea { border-color:var(--danger); }
.vd-flash { border:1px solid var(--line); border-radius:8px; background:var(--panel);
            padding:.5rem .75rem; margin:0 0 1rem; }
.vd-flash.is-ok { border-color:var(--ok); background:var(--ok-soft); }
.vd-flash.is-warn { border-color:var(--warn); background:var(--warn-soft); }
.vd-flash.is-danger { border-color:var(--danger); background:var(--danger-soft); }

/* -- panels, cards, badges ---------------------------------------------- */
.vd-warn { border:1px solid var(--danger); border-radius:8px; background:var(--danger-soft);
           padding:.5rem .75rem; }
.vd-cards { display:grid; grid-template-columns:repeat(auto-fill,minmax(14rem,1fr)); gap:.75rem; }
.vd-card { border:1px solid var(--line); border-radius:10px; padding:.8rem 1rem;
           background:var(--panel); }
.vd-card h2 { margin:0 0 .3rem; font-size:.72rem; font-weight:600; letter-spacing:.08em;
              text-transform:uppercase; color:var(--muted); }
.vd-detail { border:1px solid var(--line); border-radius:10px; background:var(--panel);
             padding:.7rem .9rem; margin:.75rem 0; }
.vd-badge { display:inline-flex; align-items:center; gap:.4em;
            font-size:.8rem; font-weight:550; color:var(--muted); white-space:nowrap; }
.vd-badge::before { content:""; width:.5em; height:.5em; border-radius:50%;
                    background:currentColor; }
.vd-up { color:var(--ok); } .vd-degraded { color:var(--warn); } .vd-down { color:var(--danger); }

/* -- void/notify's bell and panel, without an inline style --------------- */
.void-notify-count { margin-left:4px; padding:0 6px; border-radius:9px;
                     background:var(--danger); color:#fff; font-size:12px; }
.void-notify-list ul { list-style:none; margin:0; padding:0; }
.void-notify-list li { padding:8px 0; border-bottom:1px solid var(--line-soft); }
.void-notify-list li p { margin:4px 0 0; }
.void-notify-list li button { margin-top:4px; }

/* -- motion: the swap settling, nothing else ----------------------------- */
.htmx-settling { animation:vd-settle .3s ease-out; }
@keyframes vd-settle { from { opacity:.55; } to { opacity:1; } }
@media (prefers-reduced-motion: reduce) {
  * { transition:none !important; animation:none !important; }
}
`))

# -- a URL under a mount prefix ------------------------------------------

(defn url-under
  {:params [:string :string (or {:string :any} :nil)] :ret :string}
  ``A URL under a prefix: (url-under "/admin" "/jobs"), (url-under
  "/dash" "/why" {"key" "http/server"}). Query is a table of already-
  stringable values; nil and empty values drop out, which is what
  makes "the same URL without the filter" one expression rather than
  a branch. Keys render sorted, so the same query is the same URL.

  It exists because a mount prefix is config and a contribution is a
  value frozen at load: a plugin that mounts a page cannot write down
  where its own page will be, and asks here instead.``
  [prefix path &opt query]
  (def full (string prefix path))
  (def pairs*
    (sorted (seq [[k v] :pairs (or query {})
                  :when (and (not (nil? v)) (not (empty? (string v))))]
              (string k "=" v))))
  (if (empty? pairs*)
    full
    (string full "?" (string/join pairs* "&"))))

# -- served assets -------------------------------------------------------
#
# A framework page's sheet and script are *served*, not written into
# the page. That is a content-security decision before it is a caching
# one: an inline `<style>` is refused by `default-src 'self'`, so a
# composition that adds the back office would pay for it with
# `'unsafe-inline'` — the weakest half of its own policy, spent on
# somebody else's page. A file from this origin needs no policy line.
# The name carries a crc32 of the content (the pipeline's own
# `fingerprint`), so the response is immutable and a changed sheet is a
# changed URL; `private` rather than `public`, because the route sits
# behind the same gate as every page of the plugin and a shared cache
# must not keep it.

(def asset-prefix
  "Where a plugin's served assets are mounted, under its own prefix."
  "/-/assets/")

(def- content-types
  {:style "text/css; charset=utf-8"
   :script "text/javascript; charset=utf-8"})

(defn served-asset
  {:params [:string :string?] :ret (or {:file :string :body :string} :nil)}
  "One served file as data — `{:file <fingerprinted name> :body}` — or
  nil for an empty body, so a plugin with no script links none."
  [logical body]
  (unless (or (nil? body) (empty? body))
    {:file (assets/fingerprint logical body) :body body}))

(defn asset-href
  {:params [:string (or {:file :string & r} :nil)] :ret :string?}
  "Where a served asset lives under `prefix`, or nil when there is
  none: (asset-href \"/admin\" (bundle :style))."
  [prefix asset]
  (when asset
    (string prefix asset-prefix (asset :file))))

(defn asset-route
  {:params [:keyword (or {:file :string :body :string} :nil)
            (or {:name :keyword? :meta (or {:keyword :any} :nil)
                 :wrap (or (fn [a] a) :nil) & r} :nil)]
   :ret (or {:route :boolean :method :keyword :pattern :string
             :handler (or :symbol :function) :meta {:keyword :any}}
            :nil)
   :throws [:string]}
  ``The route serving one asset — `half` is :style or :script, `asset`
  a `served-asset` — as a router/route value, or nil when there is
  nothing to serve. opts: :name (the route name), :meta (route
  metadata, the gate's policy for instance), :wrap (a function around
  the handler, for a gate that is not a policy).``
  [half asset &opt opts]
  (default opts {})
  (when asset
    (def type (or (content-types half)
                  (errorf "asset half must be :style or :script, got %q" half)))
    (def body (asset :body))
    (defn serve
      {:params [:any] :ret {:status :number :headers @{:string :string} :body :string}}
      "The handler for a served asset: the same headers and body on
      every request, in a fresh table so downstream middleware can
      add its own headers without touching a shared value."
      [_req]
      # a fresh mutable table per request, never a shared struct: the
      # edge middlewares (CSRF's cookie, the security headers) add
      # headers to whatever a handler returns, and a struct here
      # answered every composition with void/security a 500 — an
      # unstyled back office, because this route is the sheet
      @{:status 200
        :headers @{"content-type" type
                   "cache-control" "private, max-age=31536000, immutable"}
        :body body})
    (router/GET (string asset-prefix (asset :file))
                (if-let [w (get opts :wrap)] (w serve) serve)
                (merge {:name (get opts :name (keyword "asset-" (string half)))}
                       (get opts :meta {})))))
