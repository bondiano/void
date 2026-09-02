### void/dash/pages — the M1 projections: overview, components,
### plugins, config, routes, deploy.
###
### Nothing on these pages is computed for them. Every number and every
### row is a value the process already answers a REPL with —
### plugin/health, plugin/inspect, plugin/why, config/explain,
### boot :system, deploy/survey, routes-table, explain-route — and the
### page is the fourth projection of it, after Prometheus, MCP and the
### CLI. What has no source in this composition is not an empty box: it
### is a sentence naming the plugin that would fill it, which is the
### same voice every boot error in this repository speaks in.
###
### Optional sources are reached through the boot value — a component's
### own :health function, by key — never through an import: void/obs,
### void/pressure and void/db are not edges of this package, and a
### composition without them gets a dashboard that says so.

(import void/core/plugin :as plugin)
(import void/core/config :as config)
(import void/core/deploy :as deploy)
(import void/core/meta :as meta)
(import void/http/init :as http)
(import void/html/init :as html)
(import void/htmx/init :as htmx)
(import ./context :as ctx)
(import ./history :as history)
(import ./view :as view)

# -- responses -----------------------------------------------------------

(defn page
  "A full dash page: the frame, the content."
  [req content]
  (html/page content {:layout view/layout :context {:request req}}))

(defn partial?
  "Is this request asking for the fragment rather than the page?"
  [req]
  (htmx/partial-request? req))

(defn- kw
  "A query-string keyword: with or without the leading colon a REPL
  habit types."
  [s]
  (keyword (string/triml (string s) ":")))

# -- reading the boot ----------------------------------------------------

(defn- component-health
  ``One running component's :health value, or nil — the seam optional
  sections read through. A throwing health function answers nil here:
  a dashboard tile must not take the page down with it.``
  [boot key]
  (def sys (boot :system))
  (when (and sys (= :running (get-in sys [:states key])))
    (when-let [h (get-in sys [:components key :health])]
      (def [ok v] (protect (h (get-in sys [:instances key]))))
      (when (and ok (dictionary? v)) v))))

(defn sample-sources
  ``What the history sampler reads each tick, resolved from the boot:
  {:rss :connections} — either nil when its component is not in the
  composition (./init hands this to the sampler).``
  [boot]
  {:rss (get (component-health boot :obs/registry) :rss)
   :connections (get (component-health boot :http/server) :connections)})

# -- overview ------------------------------------------------------------

(defn- card [title & body]
  [:div {:class "dash-card"} [:h2 title] ;body])

(defn- process-card [boot]
  (card "Process"
        [:p {:class "dash-big"}
         (view/duration-str (- (os/clock :monotonic) (ctx/setting :started-at 0)))]
        [:p {:class "dash-note"}
         (string "up · profile " (string (boot :profile))
                 " · shape " (string (get-in boot [:deploy :shape] :single)))]))

(defn- runtime-card [boot]
  (if-let [h (component-health boot :obs/registry)]
    (card "Runtime"
          [:p {:class "dash-big"} (view/bytes-str (h :rss))]
          [:p {:class "dash-note"}
           (string "rss · loop lag p99 " (view/ms (h :loop-lag-p99))
                   " (max " (view/ms (h :loop-lag-max)) ")"
                   (if (h :sampling) "" " · sampler off"))]
          (view/sparkline (history/series :lag-ms))
          [:p {:class "dash-note"} "loop lag, dash's own samples"])
    (card "Runtime"
          (view/absent "the RSS and loop-lag meter" ":void/obs")
          (view/sparkline (history/series :lag-ms))
          [:p {:class "dash-note"} "loop lag, dash's own samples"])))

(defn- http-card [boot]
  (if-let [h (component-health boot :http/server)]
    (card "HTTP"
          [:p {:class "dash-big"} (string (get h :connections 0))]
          [:p {:class "dash-note"}
           (string "open connections · port " (string (get h :port "?"))
                   " · " (string (get h :status :up)))]
          (view/sparkline (history/series :connections))
          [:p {:class "dash-note"} "connections over time"])
    (card "HTTP"
          [:p {:class "dash-absent"}
           "the :http/server component is not running — a kernel-only boot (test/with-http) has no listener."])))

(defn- pressure-card [boot]
  (if-let [h (component-health boot :pressure/sampler)]
    (card "Pressure"
          [:p {:class "dash-big"}
           (if (h :under-pressure) [:span {:class "dash-down"} "shedding"]
             [:span {:class "dash-up"} "ok"])]
          [:p {:class "dash-note"}
           (string "mode " (string (get h :mode "-"))
                   " · episodes " (string (get h :episodes 0))
                   " · shed " (string (get h :shed 0)))])
    (card "Pressure" (view/absent "load shedding" ":void/pressure"))))

(defn- health-tiles [boot]
  (def h (plugin/health boot))
  [:div
   [:h2 "Health"]
   [:p (view/status-word (h :status))
    [:span {:class "dash-note"} " — plugin/health, the same fold GET /health and void/mcp answer with"]]
   [:div {:class "dash-cards"}
    ;(seq [name :in (sorted (keys (h :components)))
           :let [c (get-in h [:components name])]]
       [:div {:class "dash-card"}
        [:h2 (string name)]
        [:p (view/status-word (get c :status))]
        (when-let [r (get c :reason)]
          [:p {:class "dash-note"} (view/value-str r 120)])])]])

(defn- contributed-tiles []
  (def tiles (ctx/setting :tiles []))
  (unless (empty? tiles)
    [:div
     [:h2 "At a glance"]
     [:div {:class "dash-cards"}
      ;(seq [t :in tiles]
         [:div {:class "dash-card"}
          [:h2 (get t :label (string (t :name)))]
          (let [[ok v] (protect ((t :render)))]
            (if ok v [:p {:class "dash-warn"} (view/value-str v 120)]))])]]))

(defn overview-fragment
  "Everything the overview poll moves."
  [boot]
  (view/poll-wrap "dash-overview" (ctx/at "")
    [:div {:class "dash-cards"}
     (process-card boot)
     (runtime-card boot)
     (http-card boot)
     (pressure-card boot)]
    (health-tiles boot)
    (contributed-tiles)))

(defn overview-body
  "The overview, inside the frame."
  [boot]
  [:div (view/live-attrs "/live")
   [:h1 "Overview"]
   (overview-fragment boot)])

(defn overview [req]
  (def boot (ctx/boot))
  (if (partial? req)
    (html/fragment (overview-fragment boot))
    (page req (overview-body boot))))

# -- components ----------------------------------------------------------

(def why-target "dash-why")

(defn- why-link [key]
  [:a {:href (ctx/at "/why" {"key" (string key)})
       :hx-get (ctx/at "/why" {"key" (string key)})
       :hx-target (string "#" why-target)
       :hx-swap "innerHTML"}
   "why?"])

(defn components-body [boot]
  (def sys (boot :system))
  [:div
   [:h1 "Components"]
   [:p {:class "dash-note"}
    "boot :system — the graph in topological order: every component after the ones it depends on."]
   [:table {:class "dash-table"}
    [:thead [:tr [:th "component"] [:th "plugin"] [:th "state"]
             [:th "deps"] [:th "provides"] [:th ""]]]
    [:tbody
     (seq [k :in (get sys :order [])]
       (def c (get-in sys [:components k]))
       (def res (get-in sys [:resolution k] {}))
       [:tr
        [:td [:code (string k)]]
        [:td (string (get c :plugin ""))]
        [:td (view/status-word (case (get-in sys [:states k])
                                 :running :up
                                 :suspended :degraded
                                 :down))]
        [:td (if (empty? res)
               [:span {:class "dash-note"} "—"]
               (string/join (seq [[ref rk] :pairs res]
                              (if (= ref rk)
                                (string rk)
                                (string ref " → " rk)))
                            ", "))]
        [:td (string/join (map string (get c :provides [])) ", ")]
        [:td (why-link k)]])]]
   [:div {:id why-target :class "dash-detail"}
    [:p {:class "dash-note"} "Pick a component — plugin/why answers: who brought it, and who depends on it."]]])

(defn components [req]
  (page req (components-body (ctx/boot))))

(defn why
  "The plugin/why answer for one component or interface, as a fragment."
  [req]
  (def boot (ctx/boot))
  (def raw (get-in req [:query "key"] ""))
  (def [ok w] (protect (plugin/why boot (kw raw))))
  (html/fragment
    (if (not ok)
      [:p {:class "dash-warn"} (view/value-str w 300)]
      (if (get w :interface)
        [:div
         [:h2 (string "interface " (w :interface))]
         [:p (string "providers: "
                     (string/join (map string (w :providers)) ", "))]
         [:p (string "selected: " (string (or (w :selected) "the only one")))]]
        [:div
         [:h2 (string (w :key))]
         [:p (string "brought by plugin " (string (w :plugin))
                     " · state " (string (w :state)))]
         [:p (string "provides: "
                     (if (empty? (get w :provides [])) "nothing"
                       (string/join (map string (w :provides)) ", ")))]
         [:p (string "depends on: "
                     (let [d (get w :deps {})]
                       (if (empty? d) "nothing"
                         (string/join (seq [[ref rk] :pairs d]
                                        (string ref " → " rk)) ", "))))]
         (if (empty? (get w :dependents []))
           [:p "nothing depends on it"]
           [:div [:p "depended on by:"]
            [:ul (seq [d :in (w :dependents)]
                   [:li [:code (string (d :component))]
                    (string " via " (string (d :via)))])]])]))))

# -- plugins and extension points ----------------------------------------

(def point-target "dash-point")

(defn plugins-body [boot]
  (def rows (plugin/inspect boot))
  [:div
   [:h1 "Plugins"]
   [:table {:class "dash-table"}
    [:thead [:tr [:th "plugin"] [:th "version"] [:th "active"]
             [:th "components"] [:th "own points"] [:th "contributes"]]]
    [:tbody
     (seq [r :in rows]
       [:tr
        [:td [:code (string (r :plugin))]]
        [:td (string (r :version))]
        [:td (if (r :active) [:span {:class "dash-up"} "yes"]
               [:span {:class "dash-note"} "no"])]
        [:td (string/join (map string (r :components)) ", ")]
        [:td (string/join (map string (r :extension-points)) ", ")]
        [:td (string/join (seq [[p n] :pairs (r :contributes)]
                            (string p " ×" n)) ", ")]])]]
   [:h2 "Extension points"]
   [:table {:class "dash-table"}
    [:thead [:tr [:th "point"] [:th "owner"] [:th "cardinality"]
             [:th "contributions"] [:th ""]]]
    [:tbody
     (seq [name :in (sorted (keys (boot :extensions)))
           :let [e (get-in boot [:extensions name])]]
       [:tr
        [:td [:code (string/format "%j" name)]]
        [:td (string (e :owner))]
        [:td (string (get-in e [:point :cardinality] :many))]
        [:td {:class "dash-count"} (string (length (get e :contributions [])))]
        [:td [:a {:href (ctx/at "/point" {"name" (string name)})
                  :hx-get (ctx/at "/point" {"name" (string name)})
                  :hx-target (string "#" point-target)
                  :hx-swap "innerHTML"}
              "open"]]])]]
   [:div {:id point-target :class "dash-detail"}
    [:p {:class "dash-note"}
     "Pick a point — its contributions with the plugin each came from, and the folded value the owner reads."]]])

(defn plugins [req]
  (page req (plugins-body (ctx/boot))))

(defn point
  "One extension point: doc, contributions with attribution, the
  resolved value — plugin/inspect on the point, as a fragment."
  [req]
  (def boot (ctx/boot))
  (def name (kw (get-in req [:query "name"] "")))
  (def e (get-in boot [:extensions name]))
  (html/fragment
    (if (nil? e)
      [:p {:class "dash-warn"}
       (string "unknown extension point " (string name))]
      [:div
       [:h2 [:code (string/format "%j" name)]]
       (when-let [doc (get-in e [:point :doc])]
         [:p {:class "dash-note"} doc])
       (if (empty? (get e :contributions []))
         [:p {:class "dash-empty"} "No contributions."]
         [:table {:class "dash-table"}
          [:thead [:tr [:th "plugin"] [:th "value"]]]
          [:tbody
           (seq [c :in (e :contributions)]
             [:tr
              [:td [:code (string (c :plugin))]]
              [:td [:code (view/value-str (c :value) 300)]]])]])
       [:p [:span {:class "dash-note"} "resolved: "]
        [:code (view/value-str (e :resolved) 300)]]])))

# -- config --------------------------------------------------------------

(defn config-body [boot]
  (def cfg (boot :config))
  (def paths (sorted (keys (cfg :provenance))))
  [:div
   [:h1 "Config"]
   [:p {:class "dash-note"}
    (string "profile " (string (cfg :profile))
            " · layers: "
            (string/join (map |(string ($ :layer)) (get cfg :layers [])) " ← ")
            " (later wins) · every value with the layer that set it — config/explain. "
            "Secrets are boxes and print as their reference: safe by construction.")]
   [:table {:class "dash-table"}
    [:thead [:tr [:th "path"] [:th "value"] [:th "from"]]]
    [:tbody
     (seq [p :in paths
           :let [e (config/explain cfg ;p)]]
       [:tr
        [:td [:code (string/join (map string p) " ")]]
        [:td [:code (view/value-str (e :value))]]
        [:td (config/describe-source (e :source))
         (let [shadowed (reverse (array/slice (e :history) 0 -2))]
           (unless (empty? shadowed)
             [:span {:class "dash-note"}
              (string " (overrides: "
                      (string/join (map config/describe-source shadowed) ", ")
                      ")")]))]])]]])

(defn config-page [req]
  (page req (config-body (ctx/boot))))

# -- routes --------------------------------------------------------------

(def route-target "dash-route")

(defn routes-body []
  (def table (http/routes-table))
  (def entries (sorted-by |[($ :pattern) (string ($ :method))] (table :routes)))
  [:div
   [:h1 "Routes"]
   [:p {:class "dash-note"}
    "The live route table — what `void routes` prints; opening a line is explain-route: every metadata key with the layer that set it."]
   [:table {:class "dash-table"}
    [:thead [:tr [:th "method"] [:th "pattern"] [:th "name"]
             [:th "source"] [:th "handler"]]]
    [:tbody
     (seq [e :in entries]
       [:tr
        [:td (string/ascii-upper (string (e :method)))]
        [:td [:code (e :pattern)]]
        [:td [:a {:href (ctx/at "/route" {"name" (string (e :name))})
                  :hx-get (ctx/at "/route" {"name" (string (e :name))})
                  :hx-target (string "#" route-target)
                  :hx-swap "innerHTML"}
              [:code (string (e :name))]]]
        [:td (string (e :source))]
        [:td [:code (if (symbol? (e :handler)) (string (e :handler)) "<fn>")]]])]]
   [:div {:id route-target :class "dash-detail"}
    [:p {:class "dash-note"} "Pick a route."]]])

(defn routes [req]
  (page req (routes-body)))

(defn route
  "One route's metadata provenance — the explain-route half that does
  not need a concrete path, read off the entry by :name."
  [req]
  (def table (http/routes-table))
  (def name (kw (get-in req [:query "name"] "")))
  (def e (get-in table [:by-name name]))
  (html/fragment
    (if (nil? e)
      [:p {:class "dash-warn"} (string "no route named " (string name))]
      (let [merged {:value (e :meta) :provenance (e :provenance)}]
        [:div
         [:h2 [:code (string (string/ascii-upper (string (e :method))) " " (e :pattern))]]
         [:p {:class "dash-note"}
          (string "source " (string (e :source))
                  " · middleware: "
                  (if (empty? (e :middleware)) "none"
                    (string/join (map string (e :middleware)) " → ")))]
         [:ul
          (seq [k :in (sorted (keys (e :meta)))]
            [:li [:code (meta/explain-str merged k)]])]]))))

# -- deploy --------------------------------------------------------------

(defn- store-verdict [e]
  (case (get e :shared?)
    true [:span {:class "dash-up"} "shared"]
    :by-design [:span {:class "dash-note"} "by design"]
    :unknown [:span {:class "dash-warn"} "no answer"]
    [:span {:class "dash-down"} "per-process"]))

(defn- store-note [e]
  (case (get e :shared?)
    false (get e :replacement "")
    :by-design (get e :why "")
    :unknown (get e :error "")
    ""))

(defn deploy-body [boot]
  (def dep (get boot :deploy {}))
  (def entries (or (get boot :stores)
                   (let [[ok v] (protect (deploy/survey boot))] (if ok v []))))
  [:div
   [:h1 "Deploy"]
   [:p {:class "dash-note"}
    (string "shape " (string (get dep :shape :single))
            " (" (string (get dep :reason "resolved")) ") — deploy/survey: every store this "
            "composition keeps, and whether a second replica would see it.")]
   (if (empty? entries)
     [:p {:class "dash-empty"}
      "Stores: none — nothing this composition keeps outlives a request."]
     [:table {:class "dash-table"}
      [:thead [:tr [:th "store"] [:th "what"] [:th "kind"] [:th "verdict"] [:th "note"]]]
      [:tbody
       (seq [e :in entries]
         [:tr
          [:td [:code (string (e :name))]]
          [:td (string (e :what))]
          [:td (string (get e :store "?"))]
          [:td (store-verdict e)]
          [:td {:class "dash-note"} (store-note e)]])]])])

(defn deploy-page [req]
  (page req (deploy-body (ctx/boot))))
