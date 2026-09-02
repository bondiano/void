### void/dash/tap — the value inspector (M4; Clojure's Portal, at
### void's scale).
###
### `(dash/tap value)` from code — or from the netrepl, which is the
### point — puts the value in a ring of [:dash :tap-buffer] entries
### with a timestamp and, through the macro, the call site. The Tap
### page lists them; one value opens as a lazily-unfolding tree (each
### expansion is an htmx request, so a ten-megabyte map costs the page
### only what was opened), an array of dictionaries also renders as a
### table, and every value can be copied out as JDN.
###
### The buffer is module-level like the metrics registry: a value
### tapped before the boot, or in a process that never booted the
### plugin, is still there when the page comes up. REPL-driven
### development as a first-class mode, carried to the browser.

(import void/html/init :as html)
(import void/htmx/init :as htmx)
(import void/http/wire :as wire)
(import ./context :as ctx)
(import ./ring :as ring)
(import ./view :as view)

(def default-capacity "Values held when [:dash :tap-buffer] says nothing." 100)

(var entries*
  "The ring of {:id :at :value :where} entries."
  (ring/make default-capacity))

(var- id-counter 0)

(defn configure!
  "Size the ring from [:dash :tap-buffer] — called at :before-start.
  A ring of the same capacity is kept as it is: a value tapped before
  the boot is part of the point."
  [capacity]
  (def cap (or capacity default-capacity))
  (unless (= cap (entries* :capacity))
    (set entries* (ring/make cap)))
  entries*)

(defn tap*
  ``Put one value in the tap ring; returns the value, so a tap can
  wrap an expression without changing it. `where` is free text — the
  `tap` macro fills in file:line.``
  [value &opt where]
  (++ id-counter)
  (ring/push! entries* @{:id id-counter
                         :at (os/clock :realtime)
                         :value value
                         :where where})
  value)

(defmacro tap
  ``tap*, with the call site written down:

      (dash/tap (order-totals basket))

  records the value under "src/orders.janet:42" and returns it.``
  [x]
  (def [l _] (or (tuple/sourcemap (dyn :macro-form)) [nil nil]))
  (def where (string (or (dyn :current-file) "?")
                     (if (and l (pos? l)) (string ":" l) "")))
  ~(,tap* ,x ,where))

(defn entries
  "The held entries, newest first."
  []
  (reverse (ring/to-array entries*)))

(defn find-entry
  "One entry by :id, or nil (evicted entries are gone — the ring is
  the contract)."
  [id]
  (find |(= id ($ :id)) (ring/to-array entries*)))

# -- shapes --------------------------------------------------------------

(defn- kind-of [v]
  (cond
    (dictionary? v) (string "{" (length v) " key" (if (= 1 (length v)) "" "s") "}")
    (indexed? v) (string "[" (length v) " item" (if (= 1 (length v)) "" "s") "]")
    (string (type v))))

(defn- addressable-key?
  "Can this key survive a JDN round trip through a URL? Anything else
  is shown inline instead of behind an expansion link."
  [k]
  (or (keyword? k) (string? k) (number? k) (boolean? k) (nil? k)))

(defn table-view?
  "Does this value read as a table — a non-empty array of
  dictionaries?"
  [v]
  (and (indexed? v)
       (not (empty? v))
       (all dictionary? v)))

(defn to-jdn
  "The value as JDN (%j); a value JDN cannot say (a function in a
  table) falls back to %q, which says so honestly."
  [v]
  (def [ok s] (protect (string/format "%j" v)))
  (if ok s (string/format "%q" v)))

(defn- resolve-path
  "Walk `path` (a tuple of keys) into `value`; [ok v]."
  [value path]
  (protect (reduce (fn [acc k] (get acc k)) value path)))

# -- the tree ------------------------------------------------------------

(defn- node-url [id path]
  (string (ctx/at (string "/tap/" id "/node"))
          "?path=" (wire/url-encode (string/format "%j" path))))

(defn- node-link [id path v]
  [:a {:href (node-url id path)
       :hx-get (node-url id path)
       :hx-swap "outerHTML"}
   (string "▸ " (kind-of v))])

(defn- leaf [v]
  [:code (view/value-str v 160)])

(defn node-view
  ``One level of the tree: the node's children, each either a leaf or
  a collapsed link that expands in place. Depth per response is one —
  the laziness is the design, not an optimization.``
  [id path v]
  (cond
    (dictionary? v)
    [:span (string (kind-of v))
     [:ul {:class "dash-tree"}
      ;(seq [k :in (sorted-by view/value-str (keys v))
             :let [child (get v k)]]
         [:li [:code (view/value-str k 60)] " "
          (cond
            (not (or (dictionary? child) (indexed? child))) (leaf child)
            (not (addressable-key? k)) (leaf child)
            (node-link id [;path k] child))])]]
    (indexed? v)
    [:span (string (kind-of v))
     [:ul {:class "dash-tree"}
      ;(seq [i :range [0 (length v)]
             :let [child (get v i)]]
         [:li [:code (string i)] " "
          (if (or (dictionary? child) (indexed? child))
            (node-link id [;path i] child)
            (leaf child))])]]
    (leaf v)))

# -- pages ---------------------------------------------------------------

(defn- page [req content]
  (html/page content {:layout view/layout :context {:request req}}))

(defn index [req]
  (def held (entries))
  (page req
        [:div
         [:h1 "Tap"]
         [:p {:class "dash-note"}
          (string "(dash/tap value) from code or the netrepl puts a value here — a ring of "
                  (entries* :capacity) ", newest first. "
                  (ring/size entries*) " held.")]
         (if (empty? held)
           [:p {:class "dash-empty"}
            "Nothing tapped yet. From the REPL: (import void/dash :as dash) (dash/tap {:hello :world})"]
           [:table {:class "dash-table"}
            [:thead [:tr [:th "#"] [:th "when"] [:th "where"] [:th "shape"] [:th "value"]]]
            [:tbody
             (seq [e :in held]
               [:tr
                [:td [:a {:href (ctx/at (string "/tap/" (e :id)))}
                      (string "#" (e :id))]]
                [:td (view/stamp (e :at))]
                [:td [:code (or (e :where) "—")]]
                [:td (kind-of (e :value))]
                [:td [:code (view/value-str (e :value) 80)]]])]])]))

(defn- gone [req id]
  (def resp (page req [:div [:h1 "Tap"]
                       [:p {:class "dash-warn"}
                        (string "tap #" id " is no longer held — the ring keeps the last "
                                (entries* :capacity) " values, and this one was evicted.")]
                       [:p [:a {:href (ctx/at "/tap")} "Back to the list"]]]))
  (put resp :status 404)
  resp)

(defn- entry-id [req]
  (scan-number (string (get-in req [:params :id] ""))))

(defn- table-of [v]
  (def cols (sorted-by view/value-str (distinct (mapcat keys v))))
  [:table {:class "dash-table"}
   [:thead [:tr ;(seq [c :in cols] [:th [:code (view/value-str c 40)]])]]
   [:tbody
    (seq [row :in v]
      [:tr ;(seq [c :in cols]
              [:td [:code (view/value-str (get row c) 80)]])])]])

(defn show [req]
  (def id (entry-id req))
  (def e (when id (find-entry id)))
  (if (nil? e)
    (gone req (or id "?"))
    (page req
          [:div
           [:h1 (string "Tap #" id)]
           [:p {:class "dash-note"}
            (string (view/stamp (e :at))
                    (if (e :where) (string " · " (e :where)) ""))
            " · "
            [:a {:href (ctx/at (string "/tap/" id "/jdn"))} "copy as JDN"]
            " · "
            [:a {:href (ctx/at "/tap")} "back"]]
           (when (table-view? (e :value))
             [:div [:h2 "As a table"] (table-of (e :value))])
           [:h2 "Tree"]
           [:div {:class "dash-detail"} (node-view id [] (e :value))]])))

(defn node [req]
  (def id (entry-id req))
  (def e (when id (find-entry id)))
  (def raw (string (get-in req [:query "path"] "()")))
  (def [parsed-ok path] (protect (parse raw)))
  (cond
    (nil? e)
    (html/fragment [:span {:class "dash-warn"} "this tap value was evicted"])

    (not (and parsed-ok (indexed? path)))
    (html/fragment [:span {:class "dash-warn"} "unreadable tree path"])

    (let [[ok v] (resolve-path (e :value) path)
          content (if ok
                    (node-view id path v)
                    [:span {:class "dash-warn"} "this branch is gone"])]
      (if (htmx/request? req)
        (html/fragment content)
        (page req [:div [:h1 (string "Tap #" id)]
                   [:p {:class "dash-note"}
                    [:a {:href (ctx/at (string "/tap/" id))} "whole value"]]
                   [:div {:class "dash-detail"} content]])))))

(defn jdn [req]
  (def id (entry-id req))
  (def e (when id (find-entry id)))
  (if (nil? e)
    @{:status 404
      :headers @{"content-type" "text/plain; charset=utf-8"}
      :body (string "tap #" (or id "?") " is no longer held")}
    @{:status 200
      :headers @{"content-type" "text/plain; charset=utf-8"}
      :body (to-jdn (e :value))}))
