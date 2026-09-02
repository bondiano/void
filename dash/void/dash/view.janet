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
  ``The built-in stylesheet: system fonts, one accent, readable tables,
  and nothing that needs a build step.``
  `
:root { --bg:#fff; --fg:#1b1f23; --muted:#6a737d; --line:#e1e4e8;
        --accent:#0366d6; --danger:#d73a49; --ok:#22863a; --warn:#b08800; --soft:#f6f8fa; }
* { box-sizing: border-box; }
body { margin:0; font:14px/1.5 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
       color:var(--fg); background:var(--bg); }
a { color:var(--accent); text-decoration:none; }
a:hover { text-decoration:underline; }
header.dash-bar { display:flex; align-items:baseline; gap:1rem; padding:.75rem 1.25rem;
                  border-bottom:1px solid var(--line); background:var(--soft); }
header.dash-bar .dash-title { font-weight:600; }
nav.dash-nav a { margin-right:1rem; color:var(--muted); }
nav.dash-nav a.active { color:var(--fg); font-weight:600; }
main.dash-main { padding:1.25rem; }
h1 { font-size:1.35rem; margin:0 0 1rem; }
h2 { font-size:1.1rem; margin:1.5rem 0 .5rem; }
table.dash-table { border-collapse:collapse; width:100%; }
table.dash-table th, table.dash-table td { text-align:left; padding:.4rem .6rem;
                                           border-bottom:1px solid var(--line); vertical-align:top; }
table.dash-table th { color:var(--muted); font-weight:600; white-space:nowrap; }
table.dash-table tr:hover td { background:var(--soft); }
input, select { font:inherit; padding:.3rem .4rem; border:1px solid var(--line);
                border-radius:4px; background:#fff; color:inherit; }
button { font:inherit; padding:.35rem .7rem; border:1px solid var(--line);
         border-radius:4px; background:var(--soft); cursor:pointer; color:inherit; }
.dash-toolbar { display:flex; gap:1rem; align-items:flex-end; flex-wrap:wrap; margin-bottom:1rem; }
.dash-toolbar .field { display:flex; flex-direction:column; gap:.15rem; }
.dash-toolbar label { color:var(--muted); font-size:.8rem; }
.dash-cards { display:flex; gap:1rem; flex-wrap:wrap; }
.dash-card { border:1px solid var(--line); border-radius:6px; padding:.75rem 1rem; min-width:12rem; }
.dash-card h2 { margin:0 0 .25rem; font-size:.9rem; color:var(--muted); }
.dash-count { font-variant-numeric:tabular-nums; }
.dash-big { font-size:1.3rem; font-variant-numeric:tabular-nums; }
.dash-note { color:var(--muted); font-size:.85rem; margin:.25rem 0; }
.dash-empty { color:var(--muted); padding:1rem 0; }
.dash-absent { color:var(--muted); font-style:italic; }
.dash-warn { border-left:3px solid var(--danger); padding:.5rem .75rem; background:var(--soft); }
.dash-up { color:var(--ok); } .dash-degraded { color:var(--warn); } .dash-down { color:var(--danger); }
code, pre { font:12px/1.45 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace; }
pre.dash-jdn { background:var(--soft); border:1px solid var(--line); border-radius:6px;
               padding:.6rem .8rem; overflow-x:auto; white-space:pre-wrap; word-break:break-word; }
.dash-detail { border:1px solid var(--line); border-radius:6px; padding:.6rem .8rem; margin:.5rem 0; }
ul.dash-tree { list-style:none; padding-left:1.1rem; margin:.15rem 0; }
ul.dash-tree > li { margin:.1rem 0; }
.dash-spark { color:var(--accent); }
.dash-logs { display:block; }
.dash-log-trace, .dash-log-debug { color:var(--muted); }
.dash-log-warn { color:var(--warn); }
.dash-log-error, .dash-log-fatal { color:var(--danger); }
.dash-actions { display:flex; gap:.5rem; align-items:center; margin:1rem 0; flex-wrap:wrap; }
form.dash-inline { display:inline; }
`)

(def asset-prefix
  "Where the sheet is mounted, under [:dash :prefix]."
  "/-/assets/")

(defn asset-bundle
  "The dash's served sheet, as data: {:style {:file :body}}."
  []
  {:style {:file (assets/fingerprint "dash.css" stylesheet) :body stylesheet}})

(defn asset-url
  "Where the sheet is served."
  []
  (when-let [b (get (ctx/setting :assets {}) :style)]
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
  (hiccup/html5 {:lang "en"}
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     [:title (get context :void.dash/title (ctx/setting :title "Dash"))]
     (when-let [href (asset-url)]
       [:link {:rel "stylesheet" :href href}])
     (htmx-tag)]
    [:body
     [:header {:class "dash-bar"}
      [:span {:class "dash-title"} (ctx/setting :title "Dash")]
      [:nav {:class "dash-nav"} ;(nav-links request)]]
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
  "A health status keyword as a colored word."
  [status]
  (def s (or status :unknown))
  [:span {:class (case s :up "dash-up" :degraded "dash-degraded"
                    :down "dash-down" "dash-note")}
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
     [:polyline {:points pts :fill "none" :stroke "currentColor" :stroke-width "1.5"}]]))

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
