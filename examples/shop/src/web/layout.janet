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
###   * the two `<meta>` tags and the `hx-headers` attribute are what
###     let a request htmx makes on its own carry the same token;
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
  ``The one-line message a page carries back from a write. Every
  module's view calls it, which is why it is here and not in three
  places.``
  [state]
  (when-let [msg (get state :message)]
    [:p {:class (string "notice " (get state :tone "ok"))} msg]))

(defn- nav-cart [count]
  [:a {:href "/cart"} "Cart "
   [:span {:class "badge" :id "cart-badge"} (string count)]])

(defn staff?
  ``Does whoever is asking hold the staff role?

  `authz/has-role?` over a bare context rather than `(authz/can?
  :staff)`, and the difference is the point: `can?` records a
  *decision*, every decision goes through the hook the audit module
  subscribes to, and a nav item that asked would put a refusal on the
  audit trail for every page view by every visitor. Drawing a link is
  not an authorization decision — the route is where that is made
  (modules/admin/admin.controller.janet), and it is made once.``
  []
  (authz/has-role? (authz/make-context) :staff))

(defn- who-bar []
  (if (auth/current-user)
    [:span {:class "who"}
     (or (auth/claim :name) (auth/subject)) " · "
     (form/form {} {:action "/sign-out" :submit "Sign out"
                    :attrs {:class "inline"}})]
    [:a {:href "/sign-in"} "Sign in"]))

(defn layout
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
     [:link {:rel "stylesheet" :href (html/asset "shop.css")}]
     (when req (security/htmx-meta req))
     [:script {:src "https://unpkg.com/htmx.org@2.0.7"}]]
    [:body (if req (security/htmx-attrs req) {})
     [:header {:class "site"}
      [:div {:class "bar"}
       [:a {:class "brand" :href "/"} "void shop"]
       [:nav
        [:a {:href "/"} "Catalog"]
        (when (auth/current-user) [:a {:href "/orders"} "Orders"])
        (when (staff?) [:a {:href "/admin/orders"} "Desk"])
        (nav-cart (if req (cart-session/item-count req) 0))
        (who-bar)]]]
     [:main content]
     [:footer {:class "site"}
      "A void example application — "
      [:a {:href "/api/products"} "JSON API"] " · "
      [:a {:href "/openapi.json"} "OpenAPI"] " · "
      [:a {:href "/health"} "health"]]]))

(defn page
  ``A view, rendered into the frame. Every HTML handler in this
  application ends in this call and nothing else — which is what keeps
  `:layout` out of eleven handlers.``
  [view]
  (html/page view {:layout layout}))
