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
(import ./text :as text)
(import ./ring :as ring)
(import ./view :as view)
(import void/htmx/hx :as hx)

(def default-capacity "Values held when [:dash :tap-buffer] says nothing." 100)

(var entries*
  "The ring of {:id :at :value :where} entries."
  (ring/make default-capacity))

(var- id-counter 0)

(defn configure!
  {:params [:number?] :ret @{:slots @[:any] :capacity :number :next :number :written :number}
   :throws [:string]}
  "Size the ring from [:dash :tap-buffer] — called at :before-start.
  A ring of the same capacity is kept as it is: a value tapped before
  the boot is part of the point."
  [capacity]
  (def cap (or capacity default-capacity))
  (unless (= cap (entries* :capacity))
    (set entries* (ring/make cap)))
  entries*)

(defn tap*
  {:params [:any :string?] :ret :any}
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
  {:params [:any] :ret :any}
  ``tap*, with the call site written down:

      (dash/tap (order-totals basket))

  records the value under "src/orders.janet:42" and returns it.``
  [x]
  (def [l _] (or (tuple/sourcemap (dyn :macro-form)) [nil nil]))
  (def where (string (or (dyn :current-file) "?")
                     (if (and l (pos? l)) (string ":" l) "")))
  ~(,tap* ,x ,where))

(defn entries
  {:params [] :ret @[:any]}
  "The held entries, newest first."
  []
  (reverse (ring/to-array entries*)))

(defn find-entry
  {:params [:number] :ret (or :any :nil)}
  "One entry by :id, or nil (evicted entries are gone — the ring is
  the contract)."
  [id]
  (find |(= id ($ :id)) (ring/to-array entries*)))

# -- shapes --------------------------------------------------------------

(defn- kind-of
  {:params [:any] :ret :string}
  "A one-word shape for a value: {N keys}, [N items], or its type."
  [v]
  (cond
    (dictionary? v) (string "{" (length v) " key" (if (= 1 (length v)) "" "s") "}")
    (indexed? v) (string "[" (length v) " item" (if (= 1 (length v)) "" "s") "]")
    (string (type v))))

(defn- addressable-key?
  {:params [:any] :ret :boolean}
  "Can this key survive a JDN round trip through a URL? Anything else
  is shown inline instead of behind an expansion link."
  [k]
  (or (keyword? k) (string? k) (number? k) (boolean? k) (nil? k)))

(defn table-view?
  {:params [:any] :ret :boolean}
  "Does this value read as a table — a non-empty array of
  dictionaries?"
  [v]
  (and (indexed? v)
       (not (empty? v))
       (all dictionary? v)))

(defn to-jdn
  {:params [:any] :ret :string}
  "The value as JDN (%j); a value JDN cannot say (a function in a
  table) falls back to %q, which says so honestly."
  [v]
  (def [ok s] (protect (string/format "%j" v)))
  (if ok s (string/format "%q" v)))

(defn- resolve-path
  {:params [:any [:any]] :ret [:boolean :any]}
  "Walk `path` (a tuple of keys) into `value`; [ok v]."
  [value path]
  (protect (reduce (fn [acc k] (get acc k)) value path)))

# -- the tree ------------------------------------------------------------

(defn- node-url
  {:params [:number? [:any]] :ret :string :throws [:string]}
  "Where one branch of a tapped value's tree expands from."
  [id path]
  (string (ctx/at (string "/tap/" id "/node"))
          "?path=" (wire/url-encode (string/format "%j" path))))

(defn- node-link
  {:params [:number? [:any] :any] :ret :any :throws [:string]}
  "A collapsed link that expands one branch of the tree in place."
  [id path v]
  [:a (merge {:href (node-url id path)} (hx/get* (node-url id path) :swap :outer-html))
   (string "▸ " (kind-of v))])

(defn- leaf
  {:params [:any] :ret :any}
  "A value with no children, printed and cut."
  [v]
  [:code (view/value-str v 160)])

(defn node-view
  {:params [:number? [:any] :any] :ret :any :throws [:string]}
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

(defn- page
  {:params [:any :any]
   :ret @{:status :number :headers @{:string :string} :void.html/content :any
          :void.html/layout :any :void.html/context {:any :any} & r}
   :throws [:string]}
  "A full Tap page: the frame around `content`."
  [req content]
  (html/page content {:layout view/layout :context {:request req}}))

(defn index
  {:params [:any]
   :ret @{:status :number :headers @{:string :string} :void.html/content :any
          :void.html/layout :any :void.html/context {:any :any} & r}
   :throws [:string]}
  "GET /tap: the held entries, newest first."
  [req]
  (def held (entries))
  (page req
        [:div
         [:h1 (text/t :void.dash/tap)]
         [:p {:class "vd-note"}
          (text/t :void.dash/tap-note {:capacity (entries* :capacity)
                                       :held (ring/size entries*)})]
         (if (empty? held)
           [:p {:class "vd-empty"} (text/t :void.dash/tap-empty)]
           [:table {:class "vd-table"}
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

(defn- gone
  {:params [:any :any]
   :ret @{:status :number :headers @{:string :string} :void.html/content :any
          :void.html/layout :any :void.html/context {:any :any} & r}
   :throws [:string]}
  "A 404 naming which tap id was evicted."
  [req id]
  (def resp (page req [:div [:h1 (text/t :void.dash/tap)]
                       [:p {:class "vd-warn"}
                        (text/t :void.dash/tap-gone {:id id
                                                     :capacity (entries* :capacity)})]
                       [:p [:a {:href (ctx/at "/tap")}
                            (text/t :void.dash/tap-back-to-list)]]]))
  (put resp :status 404)
  resp)

(defn- entry-id
  {:params [{:params {:keyword :string} & r}] :ret :number?}
  "The :id path capture, as a number."
  [req]
  (scan-number (string (get-in req [:params :id] ""))))

(defn- table-of
  {:params [(or @[{:any :any}] [{:any :any}])] :ret :any}
  "A tapped array of dictionaries, as a table: every column that
  appears in any row."
  [v]
  (def cols (sorted-by view/value-str (distinct (mapcat keys v))))
  [:table {:class "vd-table"}
   [:thead [:tr ;(seq [c :in cols] [:th [:code (view/value-str c 40)]])]]
   [:tbody
    (seq [row :in v]
      [:tr ;(seq [c :in cols]
              [:td [:code (view/value-str (get row c) 80)]])])]])

(defn show
  {:params [{:params {:keyword :string} & r}]
   :ret @{:status :number :headers @{:string :string} :void.html/content :any
          :void.html/layout :any :void.html/context {:any :any} & r}
   :throws [:string]}
  "GET /tap/:id: the value's tree, unfolded at the root."
  [req]
  (def id (entry-id req))
  (def e (when id (find-entry id)))
  (if (nil? e)
    (gone req (or id "?"))
    (page req
          [:div
           [:h1 (text/t :void.dash/tap-one {:id id})]
           [:p {:class "vd-note"}
            (string (view/stamp (e :at))
                    (if (e :where) (string " · " (e :where)) ""))
            " · "
            [:a {:href (ctx/at (string "/tap/" id "/jdn"))} (text/t :void.dash/tap-copy-jdn)]
            " · "
            [:a {:href (ctx/at "/tap")} (text/t :void.dash/tap-back)]]
           (when (table-view? (e :value))
             [:div [:h2 (text/t :void.dash/tap-as-table)] (table-of (e :value))])
           [:h2 (text/t :void.dash/tap-tree)]
           [:div {:class "vd-detail"} (node-view id [] (e :value))]])))

(defn node
  {:params [{:params {:keyword :string} :query (or {:string :any} :nil)
             :headers {:string :any} & r}]
   :ret @{:status :number :headers @{:string :string} :void.html/content :any
          :void.html/layout :any :void.html/context {:any :any} & r}
   :throws [:string]}
  "GET /tap/:id/node?path=...: one lazily-expanded branch of the tree."
  [req]
  (def id (entry-id req))
  (def e (when id (find-entry id)))
  (def raw (string (get-in req [:query "path"] "()")))
  (def [parsed-ok path] (protect (parse raw)))
  (cond
    (nil? e)
    (html/fragment [:span {:class "vd-warn"} (text/t :void.dash/tap-evicted)])

    (not (and parsed-ok (indexed? path)))
    (html/fragment [:span {:class "vd-warn"} (text/t :void.dash/tap-bad-path)])

    (let [[ok v] (resolve-path (e :value) path)
          content (if ok
                    (node-view id path v)
                    [:span {:class "vd-warn"} (text/t :void.dash/tap-branch-gone)])]
      (if (htmx/request? req)
        (html/fragment content)
        (page req [:div [:h1 (text/t :void.dash/tap-one {:id id})]
                   [:p {:class "vd-note"}
                    [:a {:href (ctx/at (string "/tap/" id))}
                     (text/t :void.dash/tap-whole)]]
                   [:div {:class "vd-detail"} content]])))))

(defn jdn
  {:params [{:params {:keyword :string} & r}]
   :ret @{:status :number :headers @{:string :string} :body :string}}
  "GET /tap/:id/jdn: the value, as JDN — the copy that round-trips."
  [req]
  (def id (entry-id req))
  (def e (when id (find-entry id)))
  (if (nil? e)
    @{:status 404
      :headers @{"content-type" "text/plain; charset=utf-8"}
      :body (string "tap #" (or id "?") " is no longer held")}
    @{:status 200
      :headers @{"content-type" "text/plain; charset=utf-8"}
      :body (to-jdn (e :value))}))
