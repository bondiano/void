### shop/catalog/view — the storefront and one product page.
###
### The "add to cart" control is not here: it belongs to the cart, and
### this module asks for it (`cart-view/add-form`) rather than knowing
### what it posts. That is the whole of the coupling between the two
### modules on the HTML side, and it points the right way — the catalog
### knows there is a cart, the cart does not know there is a catalog
### page.
(import void/storage :as storage)
(import ../../shared/values :as values)
(import ../../web/layout :as layout)
(import ../cart/cart.view :as cart-view)

(defn- stock-line [product]
  (if (pos? (product :stock))
    [:span {:class "text-sm text-emerald-700"} (string (product :stock) " in stock")]
    [:span {:class "text-sm text-red-700"} "Sold out"]))

(defn- picture
  ``The product's image, or nothing. `storage/url` is the only thing on
  this page that knows where files live, and it answers a path under
  [:storage :serve :prefix] on a laptop and a minio URL in the compose
  file — from the same column, because the column holds a key
. A product with no picture draws no element rather than a
  broken one: the catalog was seeded before anybody uploaded anything.``
  [product class]
  # an empty key is no key: the seeded rows carry "" rather than nil,
  # and `when-let` would have taken an empty string for a picture and
  # drawn <img src=""> — one guard here, both callers
  (when-let [key (product :image)
             _ (not (empty? key))]
    [:img {:class class :src (storage/url key) :alt (product :name)
           :loading "lazy"}]))

(defn product-card [product]
  [:li {:class "group flex flex-col gap-2 overflow-hidden rounded-2xl border border-slate-200 bg-white p-4 shadow-sm transition hover:-translate-y-0.5 hover:border-slate-300 hover:shadow-md"}
   (picture product "mb-1 aspect-[4/3] w-full rounded-xl bg-slate-100 object-cover")
   [:span {:class "font-mono text-xs uppercase tracking-widest text-slate-400"}
    (product :sku)]
   [:a {:class "text-base font-semibold text-slate-900 no-underline group-hover:text-indigo-700"
        :href (string "/products/" (product :id))}
    (product :name)]
   [:span {:class "text-lg font-semibold tabular-nums text-slate-900"}
    (values/format-price (product :price-cents))]
   (stock-line product)])

(defn catalog-view
  ``The storefront. This is the one cached read in the shop
  (`catalog.service/listing`) — every other page is either personal or
  a write.``
  [products &opt state]
  (default state {})
  [:div {:id "catalog"}
   [:h1 {:class "text-3xl font-bold tracking-tight"} "Everything, one import away"]
   [:p {:class "mt-2 text-slate-500"} "A demo catalog. Nothing here ships."]
   (layout/notice state)
   [:ul {:class "mt-8 grid list-none grid-cols-[repeat(auto-fill,minmax(15rem,1fr))] gap-5 p-0"}
    (if (empty? products)
      [:li {:class "rounded-2xl border border-dashed border-slate-300 px-5 py-10 text-center text-slate-400"}
       "The catalog is empty — run "
       [:code {:class "rounded bg-slate-100 px-1.5 py-0.5 font-mono text-slate-700"}
        "void shop seed"] "."]
      (seq [p :in products] (product-card p)))]])

(defn product-view [product]
  # a product with no picture draws no column rather than an empty one
  (def pic (picture product "w-full rounded-2xl border border-slate-200 bg-slate-100 object-cover"))
  [:div {:id "product" :class (if pic "grid gap-10 md:grid-cols-2" "max-w-xl")}
   (when pic [:div pic])
   [:div
    [:p {:class "font-mono text-xs uppercase tracking-widest text-slate-400"}
     (product :sku)]
    [:h1 {:class "mt-2 text-3xl font-bold tracking-tight"} (product :name)]
    [:p {:class "mt-3 text-2xl font-semibold tabular-nums text-slate-900"}
     (values/format-price (product :price-cents))]
    [:p {:class "mt-4 leading-relaxed text-slate-600"} (product :description)]
    [:p {:class "mt-3"} (stock-line product)]
    [:div {:class "mt-6"}
     (if (pos? (product :stock))
       (cart-view/add-form product)
       [:p {:class "rounded-lg border border-red-200 bg-red-50 px-4 py-3 text-sm text-red-800"}
        "This one is sold out."])]
    [:p {:class "mt-8"}
     [:a {:class "text-sm text-slate-500 no-underline hover:text-slate-900" :href "/"}
      "← Back to the catalog"]]]])
