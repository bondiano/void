### void/dash/view — the frame and the shared pieces, as hiccup.
###
### The same posture as void/admin/view: htmx is an improvement, never
### a requirement — a page that polls is a page that also loads whole
### from the same URL; the markup carries no inline style and no inline
### script (the sheet is served as one fingerprinted file from the
### dash's own prefix, so composing the dashboard costs an application
### nothing in its content-security policy); and every number is
### rendered from a value the process already had, with `%q` and a cut
### rather than a formatter that could throw on somebody's data.

(import void/html/assets :as assets)
(import void/html/hiccup :as hiccup)
(import void/core/config :as config)
(import void/datastar/ds :as ds)
(import ./context :as ctx)

# -- the sheet -----------------------------------------------------------

(def stylesheet
  ``The built-in stylesheet: an operator's control room. Dark by
  default — these pages are read next to terminals and log tails — and
  light when the OS asks for light; both palettes are the same tokens,
  so every rule below is written once. System fonts, tabular numerals
  for anything that counts, one cyan accent for the interactive, and
  the three status hues reserved for status alone. No build step, no
  inline style, one served file.``
  `
:root {
  --bg:#101418; --panel:#171c22; --panel-2:#1d242c; --soft:#1d242c;
  --line:#2a323c; --line-soft:#232b34;
  --fg:#dde4ec; --muted:#93a2b3;
  --accent:#4cc2ff; --accent-soft:rgba(76,194,255,.12);
  --ok:#3fd68f; --warn:#e3b341; --danger:#f47067;
  --ok-soft:rgba(63,214,143,.12); --warn-soft:rgba(227,179,65,.14); --danger-soft:rgba(244,112,103,.12);
  --shadow:0 1px 2px rgba(0,0,0,.4), 0 4px 16px rgba(0,0,0,.25);
  --mono:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
  color-scheme:dark;
}
@media (prefers-color-scheme: light) {
  :root {
    --bg:#f6f7f9; --panel:#ffffff; --panel-2:#f0f3f6; --soft:#f0f3f6;
    --line:#d9dfe6; --line-soft:#e6eaef;
    --fg:#1d242c; --muted:#5d6b7a;
    --accent:#0b7cc4; --accent-soft:rgba(11,124,196,.1);
    --ok:#15803d; --warn:#8a6400; --danger:#c2362f;
    --ok-soft:rgba(21,128,61,.1); --warn-soft:rgba(138,100,0,.12); --danger-soft:rgba(194,54,47,.09);
    --shadow:0 1px 2px rgba(29,36,44,.06), 0 4px 16px rgba(29,36,44,.05);
    color-scheme:light;
  }
}
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
header.dash-bar { position:sticky; top:0; z-index:10;
                  display:flex; align-items:center; gap:1.25rem;
                  padding:0 1.25rem; height:2.9rem;
                  border-bottom:1px solid var(--line); background:var(--panel); }
header.dash-bar .dash-title { font-weight:650; letter-spacing:-.01em; white-space:nowrap; }
header.dash-bar .dash-title::before { content:""; display:inline-block; width:.5rem; height:.5rem;
                                      border-radius:50%; background:var(--ok); margin-right:.55rem;
                                      vertical-align:baseline; }
nav.dash-nav { display:flex; gap:.25rem; overflow-x:auto; scrollbar-width:none; }
nav.dash-nav::-webkit-scrollbar { display:none; }
nav.dash-nav a { color:var(--muted); padding:.35rem .6rem; border-radius:6px;
                 font-size:.92rem; white-space:nowrap; transition:color .15s, background .15s; }
nav.dash-nav a:hover { color:var(--fg); background:var(--panel-2); text-decoration:none; }
nav.dash-nav a.active { color:var(--fg); background:var(--accent-soft); font-weight:600; }
.dash-bar-meta { margin-left:auto; color:var(--muted); font:11px/1 var(--mono); white-space:nowrap; }
@media (max-width: 40rem) { .dash-bar-meta { display:none; } }
main.dash-main { padding:1.5rem 1.25rem 3rem; max-width:88rem; margin:0 auto; }

/* -- type -------------------------------------------------------------- */
h1 { font-size:1.3rem; font-weight:650; letter-spacing:-.015em; margin:0 0 1rem; }
h2 { font-size:.98rem; font-weight:650; letter-spacing:-.005em; margin:1.75rem 0 .6rem; }
code, pre { font:12px/1.5 var(--mono); }
.dash-count, .dash-big { font-variant-numeric:tabular-nums; }
.dash-note { color:var(--muted); font-size:.85rem; margin:.25rem 0; }
.dash-empty { color:var(--muted); padding:1rem 0; }
.dash-absent { color:var(--muted); font-style:italic; }

/* -- vitals: the strip across the top of the overview ------------------ */
.dash-vitals { display:grid; grid-template-columns:repeat(auto-fit,minmax(15rem,1fr));
               gap:1px; background:var(--line-soft); border:1px solid var(--line);
               border-radius:10px; overflow:hidden; box-shadow:var(--shadow); }
.dash-vital { background:var(--panel); padding:.9rem 1.1rem .8rem; min-height:7.25rem;
              display:flex; flex-direction:column; gap:.1rem; }
.dash-vital > h2 { margin:0 0 .35rem; font-size:.72rem; font-weight:600; letter-spacing:.08em;
                   text-transform:uppercase; color:var(--muted); }
.dash-big { font-size:1.45rem; font-weight:600; letter-spacing:-.02em; margin:0; line-height:1.2; }
.dash-vital .dash-note { margin:.15rem 0 0; }
.dash-vital svg { margin-top:auto; }

/* -- cards (contributed tiles, detail panels) -------------------------- */
.dash-cards { display:grid; grid-template-columns:repeat(auto-fill,minmax(14rem,1fr)); gap:.75rem; }
.dash-card { border:1px solid var(--line); border-radius:10px; padding:.8rem 1rem;
             background:var(--panel); }
.dash-card h2 { margin:0 0 .3rem; font-size:.72rem; font-weight:600; letter-spacing:.08em;
                text-transform:uppercase; color:var(--muted); }

/* -- health: a patch panel, one lamp per component --------------------- */
.dash-health { display:grid; grid-template-columns:repeat(auto-fill,minmax(13rem,1fr));
               gap:.5rem; }
.dash-health-item { display:flex; align-items:baseline; gap:.5rem;
                    border:1px solid var(--line-soft); border-radius:8px;
                    padding:.45rem .7rem; background:var(--panel);
                    font:12px/1.4 var(--mono); transition:border-color .15s; }
.dash-health-item:hover { border-color:var(--line); }
.dash-health-item .dash-badge { margin-left:auto; }
.dash-health-item.is-degraded { background:var(--warn-soft); border-color:var(--warn); }
.dash-health-item.is-down { background:var(--danger-soft); border-color:var(--danger); }
.dash-health-reason { flex-basis:100%; color:var(--muted); font-size:11px; }

/* -- status badges ------------------------------------------------------ */
.dash-badge { display:inline-flex; align-items:center; gap:.4em;
              font-size:.8rem; font-weight:550; color:var(--muted); white-space:nowrap; }
.dash-badge::before { content:""; width:.5em; height:.5em; border-radius:50%;
                      background:currentColor; }
.dash-badge.dash-up { color:var(--ok); }
.dash-badge.dash-degraded { color:var(--warn); }
.dash-badge.dash-down { color:var(--danger); }
.dash-up { color:var(--ok); } .dash-degraded { color:var(--warn); } .dash-down { color:var(--danger); }

/* -- tables ------------------------------------------------------------- */
/* rounded via the corner cells, not overflow:hidden — a clipped table
   lets scrolled rows peek out over its own sticky header */
table.dash-table { border-collapse:separate; border-spacing:0; width:100%;
                   border:1px solid var(--line); border-radius:10px;
                   background:var(--panel); box-shadow:var(--shadow); }
table.dash-table th, table.dash-table td { text-align:left; padding:.45rem .8rem;
                                           border-bottom:1px solid var(--line-soft);
                                           vertical-align:top; }
table.dash-table thead th { position:sticky; top:2.9rem; z-index:5; background:var(--panel-2);
                            color:var(--muted); font-size:.72rem; font-weight:600;
                            letter-spacing:.08em; text-transform:uppercase; white-space:nowrap;
                            border-bottom:1px solid var(--line); }
table.dash-table thead th:first-child { border-top-left-radius:9px; }
table.dash-table thead th:last-child { border-top-right-radius:9px; }
table.dash-table tbody tr:last-child td { border-bottom:none; }
table.dash-table tbody tr:last-child td:first-child { border-bottom-left-radius:9px; }
table.dash-table tbody tr:last-child td:last-child { border-bottom-right-radius:9px; }
table.dash-table tbody tr { transition:background .15s; }
table.dash-table tbody tr:hover { background:var(--panel-2); }
table.dash-table td { font-variant-numeric:tabular-nums; }

/* -- controls ------------------------------------------------------------ */
input, select { font:inherit; padding:.35rem .55rem; border:1px solid var(--line);
                border-radius:7px; background:var(--panel); color:inherit;
                transition:border-color .15s; }
input::placeholder { color:var(--muted); }
input:hover, select:hover { border-color:var(--muted); }
input:focus, select:focus { border-color:var(--accent); outline:none;
                            box-shadow:0 0 0 3px var(--accent-soft); }
button { font:inherit; font-weight:550; padding:.35rem .8rem; border:1px solid var(--line);
         border-radius:7px; background:var(--panel-2); cursor:pointer; color:inherit;
         transition:border-color .15s, background .15s; }
button:hover { border-color:var(--muted); }
button:active { background:var(--line-soft); }
.dash-toolbar { display:flex; gap:1rem; align-items:flex-end; flex-wrap:wrap; margin-bottom:1rem; }
.dash-toolbar .field { display:flex; flex-direction:column; gap:.2rem; }
.dash-toolbar label { color:var(--muted); font-size:.72rem; font-weight:600;
                      letter-spacing:.06em; text-transform:uppercase; }
.dash-filter { min-width:16rem; font:13px/1.4 var(--mono); }
.dash-actions { display:flex; gap:.5rem; align-items:center; margin:1rem 0; flex-wrap:wrap; }
form.dash-inline { display:inline; }

/* -- panels, warnings, code --------------------------------------------- */
.dash-warn { border:1px solid var(--danger); border-radius:8px; background:var(--danger-soft);
             padding:.5rem .75rem; }
pre.dash-jdn { background:var(--panel); border:1px solid var(--line); border-radius:10px;
               padding:.7rem .9rem; overflow-x:auto; white-space:pre-wrap; word-break:break-word; }
.dash-detail { border:1px solid var(--line); border-radius:10px; background:var(--panel);
               padding:.7rem .9rem; margin:.75rem 0; }
ul.dash-tree { list-style:none; padding-left:1.1rem; margin:.15rem 0; }
ul.dash-tree > li { margin:.1rem 0; }
.dash-spark { color:var(--accent); display:block; }

/* -- logs ---------------------------------------------------------------- */
.dash-logs { display:block; }
.dash-logs span { display:block; padding:.05rem .5rem; margin:0 -.5rem; border-radius:4px; }
.dash-logs span:hover { background:var(--panel-2); }
.dash-log-trace, .dash-log-debug { color:var(--muted); }
.dash-log-warn { color:var(--warn); }
.dash-log-error, .dash-log-fatal { color:var(--danger); }

/* -- motion: the poll settling, nothing else ----------------------------- */
.htmx-settling { animation:dash-settle .3s ease-out; }
@keyframes dash-settle { from { opacity:.55; } to { opacity:1; } }
@media (prefers-reduced-motion: reduce) {
  * { transition:none !important; animation:none !important; }
}
`)

(def script
  ``The dash's one script, served like the sheet: a delegated
  client-side row filter. Any input carrying `data-dash-filter="#id"`
  hides the rows of that table whose text does not contain the query —
  delegation, so rows swapped in by a poll are filtered by the next
  keystroke without re-wiring. Progressive on purpose: without
  JavaScript the input is inert and every row stays visible.``
  `
document.addEventListener("input", function (e) {
  var input = e.target.closest("[data-dash-filter]");
  if (!input) return;
  var table = document.querySelector(input.getAttribute("data-dash-filter"));
  if (!table || !table.tBodies.length) return;
  var q = input.value.trim().toLowerCase();
  var rows = table.tBodies[0].rows, shown = 0;
  for (var i = 0; i < rows.length; i++) {
    var hit = !q || rows[i].textContent.toLowerCase().indexOf(q) !== -1;
    rows[i].hidden = !hit;
    if (hit) shown++;
  }
  var out = document.getElementById(input.getAttribute("data-dash-filter").slice(1) + "-count");
  if (out) out.textContent = q ? shown + " of " + rows.length : rows.length + "";
});
`)

(def asset-prefix
  "Where the sheet is mounted, under [:dash :prefix]."
  "/-/assets/")

(defn asset-bundle
  "The dash's served assets, as data:
  {:style {:file :body} :script {:file :body}}."
  []
  {:style {:file (assets/fingerprint "dash.css" stylesheet) :body stylesheet}
   :script {:file (assets/fingerprint "dash.js" script) :body script}})

(defn asset-url
  "Where one half of the bundle is served (:style by default), or nil."
  [&opt half]
  (default half :style)
  (when-let [b (get (ctx/setting :assets {}) half)]
    (ctx/at (string asset-prefix (b :file)))))

# -- the one script ------------------------------------------------------

(def htmx-src
  "The pinned htmx file — the same pin, for the same reason, as
  void/admin/view: a URL that names the file is a URL a reader can
  verify against the integrity hash."
  "https://unpkg.com/htmx.org@4.0.0/dist/htmx.min.js")

(def htmx-integrity
  "sha384 of that file; pairs with `htmx-src` and only with it."
  "sha384-BvJpBiO8Kh31EqtJe5DRIeWrHWnCGkwytKs9NKFi86Hhw96dEqdEMzZDeK9iEGTc")

(defn- htmx-tag []
  (def src (ctx/setting :htmx-src htmx-src))
  (def integrity (or (ctx/setting :htmx-integrity)
                     (when (= src htmx-src) htmx-integrity)))
  [:script (merge {:src src :defer true}
                  (if integrity
                    {:integrity integrity :crossorigin "anonymous"}
                    {}))])

# -- the frame -----------------------------------------------------------

(def sections
  "The navigation, in reading order: label and path under the prefix."
  [["Overview" ""]
   ["Components" "/components"]
   ["Plugins" "/plugins"]
   ["Config" "/config"]
   ["Routes" "/routes"]
   ["Deploy" "/deploy"]
   ["Logs" "/logs"]
   ["Tap" "/tap"]])

(defn- nav-links [request]
  (def here (get request :path ""))
  (seq [[label path] :in sections
        :let [href (ctx/at path)]]
    [:a {:href href
         :class (when (if (empty? path)
                        (= here (ctx/prefix))
                        (string/has-prefix? href here))
                  "active")}
     label]))

(defn layout
  "The frame every dash page renders inside."
  [content context]
  (def request (get context :request))
  (def boot (ctx/boot))
  (hiccup/html5 {:lang "en"}
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     [:title (get context :void.dash/title (ctx/setting :title "Dash"))]
     (when-let [href (asset-url :style)]
       [:link {:rel "stylesheet" :href href}])
     (when-let [src (asset-url :script)]
       [:script {:src src :defer true}])
     (htmx-tag)]
    [:body
     [:header {:class "dash-bar"}
      [:span {:class "dash-title"} (ctx/setting :title "Dash")]
      [:nav {:class "dash-nav"} ;(nav-links request)]
      # which process, at a glance — the operator with three of these
      # open tells them apart by the bar, not by the URL
      [:span {:class "dash-bar-meta"}
       (string (string (get boot :profile "?")) " · pid " (os/getpid))]]
     [:main {:class "dash-main"} content]]))

# -- shared pieces -------------------------------------------------------

(defn value-str
  ``A config or contribution value as a string a page may print. A
  secret box prints as its own representation — @{:secret "NAME"} —
  which is safe by construction (the value lives outside the box);
  functions print as a word rather than an address; everything else is
  %q, cut so a page stays a page.``
  [v &opt limit]
  (default limit 200)
  (def s
    (cond
      (config/secret? v) (string/format "@{:secret %q}" (get v :secret))
      (or (function? v) (cfunction? v)) "<function>"
      (string/format "%q" v)))
  (if (> (length s) limit) (string (string/slice s 0 limit) "…") s))

(defn status-word
  "A health status keyword as a badge: a dot in the status hue, then
  the word — the lamp reads before the label does."
  [status]
  (def s (or status :unknown))
  [:span {:class (string "dash-badge "
                         (case s :up "dash-up" :degraded "dash-degraded"
                           :down "dash-down" "dash-note"))}
   (string s)])

(defn absent
  ``The section that has no source, said the void way: the name of the
  plugin whose composition would fill it, not an empty box.``
  [what plugin-name]
  [:p {:class "dash-absent"}
   (string what " is not in this composition — composing " plugin-name " adds it.")])

(defn poll-wrap
  ``The moving half of a page: it re-fetches itself every 5 seconds
  from its own URL — the jobs-dashboard idiom. The static frame stays
  outside it, so a poll never steals focus from a control.``
  [id href & body]
  [:div {:id id
         :hx-get href
         :hx-trigger "every 5s"
         :hx-swap "outerHTML"}
   ;body])

(defn sparkline
  ``An inline SVG polyline over up to the last `n` numbers — no
  JavaScript, fixed size, nils skipped. Returns nil when there is
  nothing to draw yet.``
  [vals &opt w h]
  (default w 160)
  (default h 28)
  (def xs (filter number? vals))
  (when (>= (length xs) 2)
    (def lo (min ;xs))
    (def hi (max ;xs))
    (def span (if (= hi lo) 1 (- hi lo)))
    (def n (length xs))
    (def pts
      (string/join
        (seq [i :range [0 n]
              :let [x (* w (/ i (dec n)))
                    y (- h 2 (* (- h 4) (/ (- (xs i) lo) span)))]]
          (string/format "%.1f,%.1f" x y))
        " "))
    [:svg {:class "dash-spark" :width (string w) :height (string h)
           :viewBox (string/format "0 0 %d %d" w h)}
     # a whisper of area under the line, closed down to the baseline —
     # same color, so the accent stays one token
     [:polygon {:points (string/format "0,%d %s %d,%d" h pts w h)
                :fill "currentColor" :opacity "0.08"}]
     [:polyline {:points pts :fill "none" :stroke "currentColor"
                 :stroke-width "1.5" :stroke-linejoin "round"
                 :stroke-linecap "round"}]]))

(defn live-attrs
  ``The data-* attributes that put a page on its morph stream when
  void/datastar is in the composition — and nothing at all when it is
  not, which leaves the htmx poll in charge. `path` is the stream's
  path under the prefix.``
  [path]
  (if (ctx/setting :datastar?)
    (ds/load (ds/action :get (ctx/at path) {:open-when-hidden false}))
    {}))

(defn ms
  "A number of milliseconds, printed to the tenth."
  [x]
  (if (number? x) (string/format "%.1f ms" x) "—"))

(defn bytes-str
  "A byte count, printed for a human."
  [n]
  (cond
    (not (number? n)) "—"
    (>= n 1073741824) (string/format "%.2f GiB" (/ n 1073741824))
    (>= n 1048576) (string/format "%.1f MiB" (/ n 1048576))
    (>= n 1024) (string/format "%.1f KiB" (/ n 1024))
    (string/format "%d B" n)))

(defn duration-str
  "Seconds as a human duration: 42s, 12m 3s, 5h 2m, 3d 4h."
  [secs]
  (if (not (number? secs))
    "—"
    (let [s (math/floor secs)]
      (cond
        (< s 60) (string s "s")
        (< s 3600) (string (div s 60) "m " (mod s 60) "s")
        (< s 86400) (string (div s 3600) "h " (div (mod s 3600) 60) "m")
        (string (div s 86400) "d " (div (mod s 86400) 3600) "h")))))

(defn stamp
  "A realtime clock value as an ISO-ish UTC stamp."
  [t]
  (if (number? t)
    (let [d (os/date (math/floor t) true)]
      (string/format "%04d-%02d-%02d %02d:%02d:%02dZ"
                     (d :year) (inc (d :month)) (inc (d :month-day))
                     (d :hours) (d :minutes) (d :seconds)))
    "—"))
