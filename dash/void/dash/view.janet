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

(import void/html/chrome :as chrome)
(import void/html/hiccup :as hiccup)
(import void/htmx/init :as htmx)
(import void/htmx/hx :as hx)
(import void/core/config :as config)
(import void/core/util :as util)
(import void/datastar/ds :as ds)
(import void/datastar/init :as datastar)
(import ./context :as ctx)

# -- the sheet -----------------------------------------------------------

(def stylesheet
  ``The built-in stylesheet: void/html/chrome's base sheet — the
  control room void/admin draws too — plus the blocks only the
  dashboard has: the lamp on the title, the vitals strip, the health
  panel, the log lines. No build step, no inline style, one served
  file.``
  (string chrome/base-sheet `
header.vd-bar .vd-title::before { content:""; display:inline-block; width:.5rem; height:.5rem;
                                  border-radius:50%; background:var(--ok); margin-right:.55rem;
                                  vertical-align:baseline; }
.dash-big { font-variant-numeric:tabular-nums; }

/* -- vitals: the strip across the top of the overview ------------------ */
.dash-vitals { display:grid; grid-template-columns:repeat(auto-fit,minmax(15rem,1fr));
               gap:1px; background:var(--line-soft); border:1px solid var(--line);
               border-radius:10px; overflow:hidden; box-shadow:var(--shadow); }
.dash-vital { background:var(--panel); padding:.9rem 1.1rem .8rem; min-height:7.25rem;
              display:flex; flex-direction:column; gap:.1rem; }
.dash-vital > h2 { margin:0 0 .35rem; font-size:.72rem; font-weight:600; letter-spacing:.08em;
                   text-transform:uppercase; color:var(--muted); }
.dash-big { font-size:1.45rem; font-weight:600; letter-spacing:-.02em; margin:0; line-height:1.2; }
.dash-vital .vd-note { margin:.15rem 0 0; }
.dash-vital svg { margin-top:auto; }

/* -- health: a patch panel, one lamp per component --------------------- */
.dash-health { display:grid; grid-template-columns:repeat(auto-fill,minmax(13rem,1fr));
               gap:.5rem; }
.dash-health-item { display:flex; align-items:baseline; gap:.5rem;
                    border:1px solid var(--line-soft); border-radius:8px;
                    padding:.45rem .7rem; background:var(--panel);
                    font:12px/1.4 var(--mono); transition:border-color .15s; }
.dash-health-item:hover { border-color:var(--line); }
.dash-health-item .vd-badge { margin-left:auto; }
.dash-health-item.is-degraded { background:var(--warn-soft); border-color:var(--warn); }
.dash-health-item.is-down { background:var(--danger-soft); border-color:var(--danger); }
.dash-health-facts { flex-basis:100%; color:var(--muted); font-size:11px;
                     word-break:break-word; }
.dash-health-reason { flex-basis:100%; color:var(--muted); font-size:11px; }

/* -- filters, code, trees ---------------------------------------------- */
.dash-filter { min-width:16rem; font:13px/1.4 var(--mono); }
pre.dash-jdn { background:var(--panel); border:1px solid var(--line); border-radius:10px;
               padding:.7rem .9rem; overflow-x:auto; white-space:pre-wrap; word-break:break-word; }
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
`))

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

(defn asset-bundle
  "The dash's served assets, as data:
  {:style {:file :body} :script {:file :body}} (void/html/chrome)."
  []
  {:style (chrome/served-asset "dash.css" stylesheet)
   :script (chrome/served-asset "dash.js" script)})

(defn asset-url
  "Where one half of the bundle is served (:style by default), or nil."
  [&opt half]
  (default half :style)
  (chrome/asset-href (ctx/prefix) (get (ctx/setting :assets {}) half)))

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
     [:title (get context :void.html/title (ctx/setting :title "Dash"))]
     (when-let [href (asset-url :style)]
       [:link {:rel "stylesheet" :href href}])
     (when-let [src (asset-url :script)]
       [:script {:src src :defer true}])
     (htmx/script-tag {:src (ctx/setting :htmx-src) :integrity (ctx/setting :htmx-integrity)})
     (get context :void.html/head)
     # the live half: `live-attrs` hangs data-init on a page, and
     # this is the script that reads it — one without the other is a
     # page that polls while believing it streams
     (when (ctx/setting :datastar?) (datastar/script-tag))]
    [:body
     [:header {:class "vd-bar"}
      [:span {:class "vd-title"} (ctx/setting :title "Dash")]
      [:nav {:class "vd-nav"} ;(nav-links request)]
      # which process, at a glance — the operator with three of these
      # open tells them apart by the bar, not by the URL
      [:span {:class "vd-bar-meta"}
       (string (string (get boot :profile "?")) " · pid " (os/getpid))]]
     [:main {:class "vd-main"} content]]))

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
      (util/callable? v) "<function>"
      (string/format "%q" v)))
  (if (> (length s) limit) (string (string/slice s 0 limit) "…") s))

(defn status-word
  "A health status keyword as a badge: a dot in the status hue, then
  the word — the lamp reads before the label does."
  [status]
  (def s (or status :unknown))
  [:span {:class (string "vd-badge "
                         (case s :up "vd-up" :degraded "vd-degraded"
                           :down "vd-down" "vd-note"))}
   (string s)])

(defn absent
  ``The section that has no source, said the void way: the name of the
  plugin whose composition would fill it, not an empty box.``
  [what plugin-name]
  [:p {:class "vd-absent"}
   (string what " is not in this composition — composing " plugin-name " adds it.")])

(defn poll-wrap
  ``The moving half of a page: it re-fetches itself every 5 seconds
  from its own URL — the jobs-dashboard idiom. The static frame stays
  outside it, so a poll never steals focus from a control.``
  [id href & body]
  [:div (merge {:id id} (hx/get* href :trigger "every 5s" :swap :outer-html))
   ;body])

(defn detail-link
  "A link that opens `href` in the detail panel `target` (an id) when
  htmx is there, and as a page when it is not."
  [href target & body]
  [:a (merge {:href href} (hx/get* href :target (string "#" target) :swap :inner-html))
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
