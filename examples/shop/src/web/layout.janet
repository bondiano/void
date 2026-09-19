### shop/web/layout — the page frame every module renders into.
###
### The only thing in this application that knows about more than one
### module, and it is the one thing that has to: a nav bar is by
### definition a list of the places a visitor can go. It sits above the
### modules (`src/web/`) rather than inside `shared/` for exactly that
### reason — `shared/` is what modules may import, `web/` is what
### imports modules.
###
### Three wave-3 seams pass through this file without a line of
### plumbing:
###
###   * every non-GET form renders a CSRF field, because
###     `void/security` binds the slot `form/form` has been splicing
###     since wave 1 — there is no call to make;
###   * the two `<meta>` tags and the `hx-headers:inherited` attribute
###     are what let a request htmx makes on its own carry the same
###     token — the suffix is htmx 4's, and load-bearing;
###   * the stylesheet is linked through `html/asset`, which is the
###     logical path in development and the fingerprinted one after an
###     asset build — the markup does not change either way.
(import void/html :as html)
(import void/html/form :as form)
(import void/auth :as auth)
(import void/authz :as authz)
(import void/security :as security)
(import ../modules/cart/cart.session :as cart-session)

(defn notice
  {:params [{:message :any & r}] :ret (or :tuple :nil)}
  ``The one-line message a page carries back from a write. Every
  module's view calls it, which is why it is here and not in three
  places.``
  [state]
  (when-let [msg (get state :message)]
    (def tone (get state :tone "ok"))
    [:p {:class (string "my-6 rounded-lg border px-4 py-3 text-sm "
                        (case tone
                          "bad" "border-red-200 bg-red-50 text-red-800"
                          "warn" "border-amber-300 bg-amber-50 text-amber-900"
                          "border-emerald-200 bg-emerald-50 text-emerald-900"))}
     msg]))

(def nav-link
  "Every item in the nav bar is the same item — a second copy of this
  string is how they start disagreeing."
  "text-sm font-medium text-slate-600 no-underline transition hover:text-slate-900")

(defn- nav-cart
  {:params [:number] :ret :tuple}
  "The cart link, badged with how many items are in it."
  [count]
  [:a {:class (string nav-link " inline-flex items-center gap-2") :href "/cart"}
   "Cart"
   [:span {:id "cart-badge"
           :class "inline-flex min-w-5 items-center justify-center rounded-full bg-indigo-600 px-1.5 py-0.5 text-xs font-semibold tabular-nums text-white"}
    (string count)]])

(defn staff?
  {:params [] :ret :boolean}
  ``Does whoever is asking hold the staff role?

  `authz/has-role?` over a bare context rather than `(authz/can?
  :staff)`, and the difference is the point: `can?` records a
  *decision*, every decision goes through the hook the audit module
  subscribes to, and a nav item that asked would put a refusal on the
  audit trail for every page view by every visitor. Drawing a link is
  not an authorization decision — the route is where that is made, and
  every route void/admin projects carries the gate that makes it
  (`[:admin :access] :staff`, config/default.janet).``
  []
  (authz/has-role? (authz/make-context) :staff))

(defn- who-bar
  {:params [] :ret :tuple}
  "Who's signed in, with a way to sign out — or a sign-in link when nobody is."
  []
  (if (auth/current-user)
    [:span {:class "flex items-center gap-2 text-sm text-slate-500"}
     [:span {:class "font-medium text-slate-900"}
      (or (auth/claim :name) (auth/subject))]
     "·"
     (form/form {} {:action "/sign-out" :submit "Sign out"
                    :attrs {:class "quiet-form contents"}})]
    [:a {:class nav-link :href "/sign-in"} "Sign in"]))

(defn layout
  {:params [:any {:request :any & r}] :ret @[:any]}
  ``The one page frame.

  The htmx script comes from a CDN, which is why config/default.janet
  has to name that origin in the CSP — a policy built from data, and a
  typo in it is a boot error rather than a script that silently does
  not load.``
  [content context]
  (def req (get context :request))
  (html/html5 {:lang "en"}
    [:head
     [:meta {:charset "utf-8"}]
     [:meta {:name "viewport" :content "width=device-width, initial-scale=1"}]
     [:title "void shop"]
     [:link {:rel "stylesheet" :href (html/asset "app.css")}]
     (when req (security/htmx-meta req))
     [:script {:src "https://unpkg.com/htmx.org@4.0.0"}]]
    [:body (merge (if req (security/htmx-attrs req) {})
                  {:class "flex min-h-dvh flex-col bg-slate-50 text-slate-900 antialiased"})
     [:header {:class "sticky top-0 z-10 border-b border-slate-200 bg-white/85 backdrop-blur"}
      [:div {:class "mx-auto flex max-w-5xl flex-wrap items-center gap-x-6 gap-y-3 px-6 py-4"}
       [:a {:class "text-lg font-bold tracking-tight text-slate-900 no-underline" :href "/"}
        "void shop"]
       [:nav {:class "ml-auto flex flex-wrap items-center gap-x-6 gap-y-2"}
        [:a {:class nav-link :href "/"} "Catalog"]
        (when (auth/current-user) [:a {:class nav-link :href "/orders"} "Orders"])
        (when (staff?) [:a {:class nav-link :href "/admin"} "Desk"])
        (nav-cart (if req (cart-session/item-count req) 0))
        (who-bar)]]]
     [:main {:class "mx-auto w-full max-w-5xl grow px-6 py-10"} content]
     [:footer {:class "border-t border-slate-200 bg-white px-6 py-6 text-center text-sm text-slate-500"}
      "A void example application — "
      [:a {:class "text-indigo-600 no-underline hover:underline" :href "/api/products"} "JSON API"] " · "
      [:a {:class "text-indigo-600 no-underline hover:underline" :href "/openapi.json"} "OpenAPI"] " · "
      [:a {:class "text-indigo-600 no-underline hover:underline" :href "/health"} "health"]]]))

(defn page
  {:params [:any]
   :ret HtmlView
   :throws [:string]}
  ``A view, rendered into the frame. Every HTML handler in this
  application ends in this call and nothing else — which is what keeps
  `:layout` out of eleven handlers.``
  [view]
  (html/page view {:layout layout}))
