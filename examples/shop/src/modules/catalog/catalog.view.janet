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
    [:span {:class "stock"} (string (product :stock) " in stock")]
    [:span {:class "stock out"} "Sold out"]))

(defn- picture
  ``The product's image, or nothing. `storage/url` is the only thing on
  this page that knows where files live, and it answers a path under
  [:storage :serve :prefix] on a laptop and a minio URL in the compose
  file — from the same column, because the column holds a key
  (ADR-0039). A product with no picture draws no element rather than a
  broken one: the catalog was seeded before anybody uploaded anything.``
  [product class]
  (when-let [key (product :image)]
    [:img {:class class :src (storage/url key) :alt (product :name)
           :loading "lazy"}]))

(defn product-card [product]
  [:li {:class "card"}
   (picture product "thumb")
   [:span {:class "sku"} (product :sku)]
   [:a {:class "name" :href (string "/products/" (product :id))} (product :name)]
   [:span {:class "price"} (values/format-price (product :price-cents))]
   (stock-line product)])

(defn catalog-view
  ``The storefront. This is the one cached read in the shop
  (`catalog.service/listing`) — every other page is either personal or
  a write.``
  [products &opt state]
  (default state {})
  [:div {:id "catalog"}
   [:h1 "Everything, one import away"]
   [:p {:class "lede"} "A demo catalog. Nothing here ships."]
   (layout/notice state)
   [:ul {:class "grid"}
    (if (empty? products)
      [:li {:class "card"} "The catalog is empty — run "
       [:code "void shop seed"] "."]
      (seq [p :in products] (product-card p)))]])

(defn product-view [product]
  [:div {:id "product"}
   (picture product "photo")
   [:p {:class "sku"} (product :sku)]
   [:h1 (product :name)]
   [:p {:class "price"} (values/format-price (product :price-cents))]
   [:p (product :description)]
   (stock-line product)
   (if (pos? (product :stock))
     (cart-view/add-form product)
     [:p {:class "notice bad"} "This one is sold out."])
   [:p [:a {:href "/"} "← Back to the catalog"]]])
