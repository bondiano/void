### void/admin/view — the pages, as hiccup.
###
### Everything here renders twice over: once as a whole page, and once
### as the fragment htmx swaps into a page that is already open. There
### is no second template for the second case — the fragment functions
### are what the page functions call, and `:void.htmx/partial` on the
### route decides which of the two the response carries.
###
### **htmx is an improvement, never a requirement.** A form is a
### `<form method="post">`, a link is a link, a confirmation is a page
### with a URL. The filter panel carries a real submit button that no
### JavaScript is needed to press, sorting is an ordinary link, and
### pagination is ordinary links. This is asserted by the suite twice:
### once with no HX-* header anywhere, and once with them.
###
### **An HTML form can send GET and POST and nothing else.** The
### routes still declare the verb they mean (PATCH on a cell, DELETE
### on a row), and the plain-page fallback reaches them through
### `?_method=`, rewritten at the edge for admin paths and only ever
### out of a POST — see ./init. A GET is never rewritten, because a
### link that changes state is a link the browser will prefetch.
###
### The markup carries no inline style and no inline script: the sheet
### and every widget's assets are served as two fingerprinted files
### from the admin's own prefix, so composing the back office costs an
### application nothing in its content-security policy (see
### `asset-bundle` below). An application with no asset pipeline and no
### manifest still gets a usable back office the moment it composes the
### plugin; `[:admin :stylesheet]` replaces the sheet and a
### `:void.admin/layout` contribution replaces the frame entirely.
###
### htmx attributes are written with void/htmx's builders (`hx/get*`,
### `hx/post`, ...) and never by hand — the builders spell the swap
### styles and the header names the way htmx 4 does, and a typo in a
### builder call is an error where a typo in a string is a page that
### does not swap.

(import void/html :as html)
(import void/html/chrome :as chrome)
(import void/html/hiccup :as hiccup)
(import void/html/form :as form)
(import void/htmx/init :as htmx)
(import void/htmx/hx :as hx)
(import void/core/schema :as schema)
(import ./context :as ctx)
(import ./resource :as res)
(import ./widget :as widget)

# -- the sheet -----------------------------------------------------------

(def stylesheet
  ``The built-in stylesheet: void/html/chrome's base sheet — the
  control room void/dash draws too — plus the one block only the admin
  has. No build step, no inline style, one served file.``
  (string chrome/base-sheet `
.admin-inline { border:1px solid var(--line); border-radius:10px; background:var(--panel);
                padding:.75rem .9rem; margin-bottom:1rem; }
`))

# -- the frame -----------------------------------------------------------

(defn- nav-links [request]
  (def here (get request :path ""))
  (def items @[])
  (each rname (res/mounted)
    (def d (res/lookup rname))
    (array/push items {:label (d :title) :href (ctx/base d)}))
  (each m (ctx/setting :menu [])
    (array/push items {:label (m :label)
                       :href (or (get m :href) (ctx/at (m :path)))}))
  (seq [i :in items]
    [:a {:href (i :href)
         :class (when (string/has-prefix? (i :href) here) "active")}
     (i :label)]))

# -- the two files the frame links ---------------------------------------
#
# One bundle for the whole admin rather than one per page: a file that
# is identical everywhere is a file the browser fetches once, and the
# style of a widget this page does not draw is inert. How a bundle is
# named, cached and served is void/html/chrome's (`served-asset`,
# `asset-route`).

(defn- join-assets [pairs key]
  (def parts (filter |(not (empty? $))
                     (seq [[_ a] :in pairs :let [v (get a key)] :when v] (string v))))
  (string/join parts "\n"))

(defn asset-bundle
  ``The admin's served assets, as data: `{:style {:file :body}
  :script {:file :body}}`, either half nil when there is nothing in it.
  A pure function of the sheet in force and the whole widget
  resolution, so ./mount can mount exactly the files ./view links.``
  [sheet resolved]
  (def pairs (widget/all-assets (or resolved {})))
  (def css (string/join
             (filter |(not (empty? $))
                     [(string (or sheet stylesheet)) (join-assets pairs :style)])
             "\n"))
  {:style (chrome/served-asset "admin.css" css)
   :script (chrome/served-asset "admin.js" (join-assets pairs :script))})

(defn asset-url
  "Where one half of the bundle is served, or nil when it is empty."
  [half]
  (chrome/asset-href (ctx/prefix) (get (ctx/setting :assets {}) half)))

(defn layout
  ``The default frame. Replaceable whole through a `:void.admin/layout`
  contribution — an application that already has a chrome should not
  have to live inside a second one. The page's head slots are
  void/html's: `:void.html/title` names the tab, `:void.html/head` is
  spliced into <head>.``
  [content context]
  (def request (get context :request))
  (hiccup/html5 {:lang "en"}
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     [:title (get context :void.html/title (ctx/setting :title "Admin"))]
     (when-let [href (asset-url :style)]
       [:link {:rel "stylesheet" :href href}])
     (when-let [src (asset-url :script)]
       [:script {:src src :defer true}])
     (htmx/script-tag {:src (ctx/setting :htmx-src) :integrity (ctx/setting :htmx-integrity)})
     (get context :void.html/head)]
    [:body
     [:header {:class "vd-bar"}
      [:span {:class "vd-title"} (ctx/setting :title "Admin")]
      [:nav {:class "vd-nav"} ;(nav-links request)]]
     [:main {:class "vd-main"} content]]))

(defn frame
  "The layout in force: the configured one, or the built-in."
  []
  (or (ctx/setting :layout) layout))

# -- small pieces --------------------------------------------------------

(defn- id-of [desc row]
  (string (get row (get-in desc [:entity :pk]))))

(defn- cell-value [desc row col]
  (if-let [f (get col :value)]
    (f row)
    (get row (col :name))))

(defn- csrf-slot []
  (when-let [f (dyn :void.html/csrf)] (f)))

(defn post-form
  ``A form that posts. `verb` is the verb the route actually declares:
  anything but :post rides `?_method=`, which the edge rewrites for
  admin paths and only out of a POST.``
  [verb action attrs & children]
  [:form (merge {:method "post"
                 :action (if (= :post verb)
                           action
                           (string action
                                   (if (string/find "?" action) "&" "?")
                                   "_method=" verb))}
                (or attrs {}))
   (csrf-slot)
   ;children])

# -- the list ------------------------------------------------------------

(defn list-params
  ``The query parameters that describe the current list, so a sort
  link, a page link and a bulk confirmation all carry the same view of
  it. Filters that are ranges carry both ends.``
  [desc st]
  (def out @{})
  (put out "q" (st :q))
  (put out "sort" (st :sort))
  (put out "dir" (when (st :sort) (st :dir)))
  (each f (desc :filters)
    (def v (get-in st [:filters (f :name)]))
    (when v
      (put out (f :param) (get v :eq))
      (put out (string (f :param) "-from") (get v :from))
      (put out (string (f :param) "-to") (get v :to))))
  out)

(defn- sort-link [desc st col]
  (def active (= (st :sort) (col :name)))
  (def next-dir (if (and active (= :desc (st :dir))) :asc :desc))
  (def params (list-params desc st))
  (put params "sort" (col :name))
  (put params "dir" next-dir)
  (ctx/url desc "" params))

(defn- rows-swap
  "The htmx half of a list link: fetch `url` into the rows, and put it
  in the address bar — the same three attributes on every link."
  [url]
  (hx/get* url :target "#admin-rows" :swap :outer-html :push-url true))

(defn- header-cell [desc st col]
  (def sortable (truthy? (index-of (col :name) (desc :sortable))))
  [:th
   (if sortable
     [:a (merge {:href (sort-link desc st col)} (rows-swap (sort-link desc st col)))
      (col :label)
      (when (= (st :sort) (col :name))
        (if (= :asc (st :dir)) " ▲" " ▼"))]
     (col :label))])

(defn cell
  ``One list cell. An `:editable` column renders as a tiny form that
  patches itself and swaps itself back — with no htmx it is simply the
  value, and the edit page is one click away, which is the honest
  fallback rather than a broken control.``
  [desc row col editable?]
  (def entry (ctx/widget-entry (desc :name) (col :name)))
  (def value (cell-value desc row col))
  (def shown
    (if entry
      (widget/display entry {:mode :list :value value :row row :resource desc})
      (widget/text-of value)))
  (if editable?
    [:td {:id (string "cell-" (desc :name) "-" (id-of desc row) "-" (col :name))}
     (post-form :patch (ctx/url desc (string "/" (id-of desc row) "/-/cell/" (col :name)))
                (merge (hx/patch (ctx/url desc (string "/" (id-of desc row) "/-/cell/" (col :name)))
                                 :target "this" :swap :outer-html :trigger "change")
                       {:enctype (when (widget/multipart? [entry]) "multipart/form-data")
                        :class "admin-cell"})
                (when entry
                  (widget/render entry {:mode :list :value value :row row
                                        :resource desc
                                        :name (string (col :name))
                                        :id (string "e-" (id-of desc row) "-" (col :name))}))
                [:button {:type "submit"} "Save"])]
    [:td shown]))

(defn row
  "One list row: the selection box, the cells, and the per-row links."
  [desc r st]
  (def id (id-of desc r))
  [:tr {:id (string "row-" (desc :name) "-" id)}
   [:td [:input {:type "checkbox" :name "ids" :value id}]]
   ;(seq [col :in (desc :list)]
      (cell desc r col (truthy? (index-of (col :name) (desc :editable)))))
   [:td
    (when (in (desc :action-set) :show)
      [:a {:href (ctx/url desc (string "/" id))} "View"])
    " "
    (when (in (desc :action-set) :edit)
      [:a {:href (ctx/url desc (string "/" id "/edit"))} "Edit"])
    " "
    (when (in (desc :action-set) :destroy)
      [:a {:href (ctx/url desc "/-/bulk/destroy" {"ids" id})} "Delete"])]])

(defn- pager [desc st total]
  (html/pager {:page (st :page) :per-page (st :per-page) :total total
               :attrs rows-swap
               :href (fn [p]
                       (def params (list-params desc st))
                       (put params "page" (when (> p 1) p))
                       (ctx/url desc "" params))}))

(defn rows-fragment
  ``The part of a list that filtering, searching, sorting and paging
  replace — `<tbody>` plus the pager, wrapped in one element so a
  single swap can carry both. This is the whole of the htmx story on
  the list page.``
  [desc rows st total]
  [:div {:id "admin-rows"}
   [:table {:class "vd-table"}
    [:thead
     [:tr
      [:th ""]
      ;(seq [col :in (desc :list)] (header-cell desc st col))
      [:th ""]]]
    [:tbody
     (if (empty? rows)
       [:tr [:td {:colspan (+ 2 (length (desc :list))) :class "vd-empty"} "Nothing here."]]
       (seq [r :in rows] (row desc r st)))]]
   (pager desc st total)])

(defn- filter-panel [desc st]
  (when (or (not (empty? (desc :search))) (not (empty? (desc :filters))))
    [:form (merge {:id "admin-filters"
                   :method "get"
                   :action (ctx/base desc)
                   :class "vd-toolbar"}
                  (rows-swap (ctx/base desc))
                  (hx/attrs :trigger "input changed delay:300ms from:find input, change from:find select, submit"))
     (when (not (empty? (desc :search)))
       [:div {:class "field"}
        [:label {:for "admin-q"} "Search"]
        [:input {:type "search" :name "q" :id "admin-q" :value (st :q)
                 :placeholder (string/join (map string (desc :search)) ", ")}]])
     ;(seq [f :in (desc :filters)]
        (def entry (ctx/widget-entry (desc :name) (f :name)))
        (def value (get-in st [:filters (f :name) :eq]))
        (def custom (when entry
                      (widget/filter-control entry {:value value
                                                    :name (f :param)
                                                    :id (string "f-" (f :param))
                                                    :resource desc})))
        [:div {:class "field"}
         [:label {:for (string "f-" (f :param))} (f :label)]
         (or custom
             (let [fd (f :field)]
               (case (fd :type)
                 :boolean [:select {:name (f :param) :id (string "f-" (f :param))}
                           [:option {:value ""} "any"]
                           [:option {:value "true" :selected (when (= true value) true)} "yes"]
                           [:option {:value "false" :selected (when (= false value) true)} "no"]]
                 :enum [:select {:name (f :param) :id (string "f-" (f :param))}
                        [:option {:value ""} "any"]
                        (seq [o :in (get-in fd [:node :props :values] [])]
                          [:option {:value (string o) :selected (when (= o value) true)}
                           (string o)])]
                 [:input {:type "text" :name (f :param) :id (string "f-" (f :param))
                          :value (when (not (nil? value)) (string value))}])))])
     [:div {:class "field"} [:button {:type "submit"} "Filter"]]]))

(defn- bulk-bar [desc]
  (def actions
    (array/concat
      (if (in (desc :action-set) :destroy)
        @[{:name :destroy :label "Delete" :danger true}]
        @[])
      (seq [k :in (sorted (keys (desc :custom-actions)))] (get-in desc [:custom-actions k]))))
  (unless (empty? actions)
    [:div {:class "vd-actions"}
     [:span "With selected:"]
     ;(seq [a :in actions]
        [:button {:type "submit"
                  :formaction (ctx/url desc (string "/-/bulk/" (a :name)))
                  :class (when (a :danger) "danger")}
         (a :label)])
     [:label [:input {:type "checkbox" :name "all" :value "1"}]
      " every row the filter matches"]]))

(defn list-page
  "The list: toolbar, selection form, rows, pager."
  [desc rows st total]
  [:div
   [:h1 (desc :title)]
   (filter-panel desc st)
   (when (in (desc :action-set) :new)
     [:p [:a {:class "vd-button" :href (ctx/url desc "/new")}
          (string "New " (desc :singular))]])
   # the selection form is a GET: a bulk action first shows a page, and a
   # page has a URL
   [:form {:method "get" :action (ctx/url desc "/-/bulk/destroy")}
    (rows-fragment desc rows st total)
    (bulk-bar desc)]])

# -- forms ---------------------------------------------------------------

(defn- field-block [desc fd values errors row]
  ``One labeled field, drawn through html/form's `field` with the
  control delegated to the widget — `:render` is the seam, so a widget
  field and a plain field are one block with one class vocabulary
  (and one place that learns what an invalid field looks like).``
  (def entry (ctx/widget-entry (desc :name) (fd :name)))
  (def errs (get (form/errors-by-field errors) (fd :name)))
  (def readonly (truthy? (index-of (fd :name) (desc :readonly))))
  (def raw (get values (fd :name) (get values (string (fd :name)))))
  (form/field
    {:name (fd :name) :label (fd :label)
     :render (fn [_spec value]
               (widget/render entry {:mode :form
                                     :value value
                                     :row row
                                     :readonly readonly
                                     :resource desc
                                     :errors errs
                                     :name (string (fd :name))
                                     :id (string "field-" (fd :name))
                                     :widget-url (ctx/url desc (string "/-/w/" (fd :name)))}))}
    raw
    errs))

(defn- form-attrs
  ``The <form> attributes of a form drawing `fields` of `desc`: the
  class, plus the enctype when a widget on it says its control needs
  one.``
  [desc fields &opt extra]
  (def entries (map |(ctx/widget-entry (desc :name) ($ :name)) fields))
  (merge {:class "vd-form"}
         (if (widget/multipart? entries) {:enctype "multipart/form-data"} {})
         (or extra {})))

(defn form-page
  ``The create/edit form. The version column, when the entity declares
  one, rides along as a hidden field: `save!` compares it and a lost
  race becomes a conflict the operator can read instead of a silently
  overwritten edit.``
  [desc opts]
  (def row (get opts :row))
  (def values (or (get opts :values) (or row {})))
  (def errors (get opts :errors))
  (def new? (nil? row))
  (def action (if new? (ctx/base desc) (ctx/url desc (string "/" (id-of desc row)))))
  (def vfield (get-in desc [:entity :version]))
  [:div
   [:h1 (if new?
          (string "New " (desc :singular))
          (string "Edit " (desc :singular) " " (id-of desc row)))]
   (when-let [c (get opts :conflict)]
     [:p {:class "vd-warn"} c])
   (post-form :post action (form-attrs desc (desc :form-fields))
     (when-let [errs (get (form/errors-by-field errors) :form)]
       [:ul {:class "form-errors"} (seq [e :in errs] [:li (schema/error-str e)])])
     (when (and vfield row)
       [:input {:type "hidden" :name (string vfield) :value (string (get row vfield))}])
     ;(seq [fd :in (desc :form-fields)] (field-block desc fd values errors row))
     [:div {:class "vd-actions"}
      [:button {:type "submit" :class "primary"} "Save"]
      [:a {:href (ctx/base desc)} "Cancel"]])])

# -- detail --------------------------------------------------------------

(defn detail-page
  "One row, its fields, its inlines and its history."
  [desc row inlines history]
  (def id (id-of desc row))
  [:div
   [:h1 (string (desc :singular) " " id)]
   [:div {:class "vd-actions"}
    (when (in (desc :action-set) :edit)
      [:a {:class "vd-button" :href (ctx/url desc (string "/" id "/edit"))} "Edit"])
    (when (in (desc :action-set) :destroy)
      [:a {:class "vd-button" :href (ctx/url desc "/-/bulk/destroy" {"ids" id})} "Delete"])
    [:a {:href (ctx/base desc)} "Back to list"]]
   [:table {:class "vd-table"}
    [:tbody
     (seq [fname :in (desc :detail)]
       (def entry (ctx/widget-entry (desc :name) fname))
       [:tr
        [:th (string fname)]
        [:td (if entry
               (widget/display entry {:mode :detail :value (get row fname)
                                      :row row :resource desc})
               (widget/text-of (get row fname)))]])]]
   ;(or inlines [])
   (when (and history (not (empty? history)))
     [:div
      [:h2 "History"]
      [:table {:class "vd-table"}
       [:tbody
        (seq [h :in history]
          [:tr [:td (string (get h :at ""))] [:td (string (get h :actor ""))]
           [:td (string (get h :detail (get h :action "")))]])]]])])

# -- confirmation --------------------------------------------------------

(defn confirm-page
  ``The page every action that touches rows goes through: what it will
  do, **how many rows**, a sample, and what goes with them. Deleting
  one row takes the same road as deleting forty thousand — the special
  case would be the dangerous one.``
  [desc action opts]
  (def total (get opts :total 0))
  (def sample (get opts :sample []))
  [:div
   [:h1 (string (get action :label (string (action :name))) " — confirm")]
   [:p [:span {:class "vd-count"} (string total)]
    (string " row" (if (= 1 total) "" "s") " of " (desc :title) " will be affected.")]
   (when-let [cascade (get opts :cascade)]
     (unless (empty? cascade)
       [:div {:class "vd-warn"}
        [:p "These will go with them:"]
        [:ul (seq [[label n capped] :in cascade]
               [:li (string (if capped "at least " "") n " " label)])]]))
   (when-let [note (get action :confirm)]
     [:p note])
   (when (not (empty? sample))
     [:table {:class "vd-table"}
      [:thead [:tr ;(seq [col :in (desc :list)] [:th (col :label)])]]
      [:tbody
       (seq [r :in sample]
         [:tr ;(seq [col :in (desc :list)]
                 [:td (widget/text-of (cell-value desc r col))])])]])
   (if (zero? total)
     [:p {:class "vd-empty"} "Nothing is selected, so there is nothing to do."]
     (post-form :post (ctx/url desc (string "/-/bulk/" (action :name)))
                {:class "vd-form"}
       (when (get opts :all)
         [:input {:type "hidden" :name "all" :value "1"}])
       (seq [id :in (get opts :ids [])]
         [:input {:type "hidden" :name "ids" :value (string id)}])
       ;(seq [[k v] :in (get opts :carry [])]
          [:input {:type "hidden" :name (string k) :value (string v)}])
       [:div {:class "vd-actions"}
        [:button {:type "submit" :class (hiccup/classes "primary" (when (get action :danger) "danger"))}
         (string "Yes, " (string/ascii-lower (get action :label (string (action :name)))))]
        [:a {:href (ctx/base desc)} "Cancel"]]))])

(defn progress-fragment
  ``What a running bulk shows and re-shows: the state of the job
  record, which the queue backend already stores. A percentage bar is
  drawn only when the action left one behind — a progress *column*
  would have meant editing the `:void/jobs-backend` contract, three
  backends and one conformance suite, for a widget.``
  [desc job-id state]
  # :completed and :dead are the queue's own terminal states; :gone is
  # the record the backend no longer holds. The page stops polling on
  # what the queue says, never on a flag of the admin's own
  (def done (in {:completed true :dead true :gone true} (get state :state)))
  [:div (merge {:id "admin-progress"}
               (hx/get* (ctx/url desc (string "/-/progress/" job-id))
                        :trigger (when (not done) "load delay:1s")
                        :swap :outer-html))
   [:p (string "job " job-id ": " (string (get state :state "pending")))]
   (when-let [p (get state :percent)]
     [:progress {:value (string p) :max "100"}])
   (when-let [l (get state :label)] [:p l])
   (when done [:p [:a {:href (ctx/base desc)} "Back to list"]])])

(defn progress-page
  "The page a bulk that went to the queue becomes."
  [desc action job-id state]
  [:div
   [:h1 (string (get action :label (string (action :name))) " — running")]
   (progress-fragment desc job-id state)])

# -- inlines -------------------------------------------------------------

(defn inline-block
  ``One inline: the child rows, each an ordinary form, plus an add
  form. The foreign key back to the parent is **not here** — it is put
  on by the server from the URL, so a forged POST cannot reparent a
  row.``
  [desc row inline child rows errors]
  (def id (id-of desc row))
  (def base (ctx/url desc (string "/" id "/-/inline/" (inline :name))))
  (def fields
    (or (get inline :fields)
        (map |($ :name) (child :form-fields))))
  [:div {:class "admin-inline" :id (string "inline-" (inline :name))}
   [:h2 (inline :label)]
   [:table {:class "vd-table"}
    [:thead [:tr ;(seq [f :in fields] [:th (string f)]) [:th ""]]]
    [:tbody
     (seq [c :in rows]
       (def cid (string (get c (get-in child [:entity :pk]))))
       [:tr
        ;(seq [f :in fields]
           [:td
            (post-form :post (string base "/" cid)
                       (merge (hx/post (string base "/" cid) :target (string "#inline-" (inline :name))
                                       :swap :outer-html)
                              {:enctype (when (widget/multipart?
                                                [(ctx/widget-entry (child :name) f)])
                                          "multipart/form-data")})
              (widget/render (ctx/widget-entry (child :name) f)
                             {:mode :inline :value (get c f) :row c :resource child
                              :name (string f) :id (string "i-" cid "-" f)})
              [:button {:type "submit"} "Save"])])
        [:td
         (when (inline :can-delete)
           (post-form :delete (string base "/" cid)
                      (hx/delete (string base "/" cid) :target (string "#inline-" (inline :name))
                                 :swap :outer-html)
             [:button {:type "submit" :class "danger"} "Delete"]))]])]]
   (when (inline :can-add)
     (post-form :post base
                (form-attrs child
                            (filter |(index-of ($ :name) fields) (child :form-fields))
                            (hx/post base :target (string "#inline-" (inline :name))
                                     :swap :outer-html))
       (when-let [errs (get (form/errors-by-field errors) :form)]
         [:ul {:class "form-errors"} (seq [e :in errs] [:li (schema/error-str e)])])
       ;(seq [f :in fields]
          (field-block child (first (filter |(= f ($ :name)) (child :form-fields)))
                       {} errors nil))
       [:button {:type "submit"} (string "Add " (child :singular))]))])

# -- dashboard -----------------------------------------------------------

(defn dashboard
  "The index of the admin: one card per resource, plus whatever was
  contributed to :void.admin/dashboard-widget."
  [widgets]
  [:div
   [:h1 (ctx/setting :title "Admin")]
   [:div {:class "vd-cards"}
    ;(seq [rname :in (res/mounted)
           :let [d (res/lookup rname)]]
       [:div {:class "vd-card"}
        [:h2 [:a {:href (ctx/base d)} (d :title)]]
        (when (d :doc) [:p (d :doc)])])]
   (unless (empty? widgets)
     [:div
      [:h2 "At a glance"]
      [:div {:class "vd-cards"}
       ;(seq [w :in widgets]
          [:div {:class "vd-card"}
           [:h2 (w :label)]
           ((w :render))])]])])
