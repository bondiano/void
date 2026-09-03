### shop/cart/view — plain functions returning hiccup.
###
### Nothing here knows about HTTP: the controller hands these to
### `layout/page` and the `:void.html/render` middleware turns the
### result into bytes on the way out. The forms are projections of
### ./cart.dto, so a field added there shows up here with its
### validation already attached.
(import void/html/form :as form)
(import void/htmx/hx :as hx)
(import void/db :as db)
(import void/auth :as auth)
(import ../../shared/values :as values)
(import ../../web/layout :as layout)
(import ./cart.dto :as dto)
(import ./cart.service :as service)

(defn add-form
  ``The "add to cart" control. It lives in this module rather than in
  the catalog's view because the form is about a cart — the catalog
  module calls it, and does not have to know what it posts.``
  [product]
  (form/form dto/AddToCart
    {:action "/cart/items"
     :values {:product-id (product :id) :quantity 1}
     :fields {:product-id {:control :input :type "hidden" :label ""}
              :quantity {:control :input :type "number"}}
     :submit "Add to cart"
     :attrs {:class "void-form"}}))

(defn- quantity-form [line]
  ``The quantity control: an htmx post that swaps the whole cart back
  in. The line is addressed by *product*, not by the line's own id
  (./cart.repository explains why), and the token rides on the form
  because void/security spliced it.``
  (form/form dto/SetQuantity
    {:action (string "/cart/items/" (line :product-id))
     :values {:quantity (line :quantity)}
     :fields {:quantity {:control :input :type "number" :label ""}}
     :submit "Update"
     :attrs (merge {:class "inline"}
                   (hx/post (string "/cart/items/" (line :product-id))
                            :target "#cart" :swap :outer-html))}))

(defn cart-view
  ``The cart, and the one control that matters. `db/rel` is a table
  lookup here because ./cart.repository preloaded the products; without
  the preload this page would be an N+1 that only shows up when
  somebody fills a basket.``
  [lines summary &opt state]
  (default state {})
  [:div {:id "cart"}
   [:h1 "Your cart"]
   (layout/notice state)
   (if (empty? lines)
     [:p "Nothing in it yet. " [:a {:href "/"} "Have a look around"] "."]
     [:div
      [:table {:class "lines"}
       [:thead
        [:tr [:th "Item"] [:th {:class "num"} "Price"] [:th "Quantity"]
         [:th {:class "num"} "Total"]]]
       [:tbody
        (seq [line :in lines]
          (let [product (db/rel line :product)]
            [:tr
             [:td [:a {:href (string "/products/" (product :id))} (product :name)]]
             [:td {:class "num"} (values/format-price (product :price-cents))]
             [:td (quantity-form line)]
             [:td {:class "num"} (values/format-price (service/line-total line))]]))]
       [:tfoot
        [:tr [:td {:colspan "3"} "Total"]
         [:td {:class "num"} (values/format-price (summary :subtotal-cents))]]]]
      (if (auth/current-user)
        (form/form {} {:action "/checkout" :submit "Place the order"})
        [:p {:class "notice"}
         [:a {:href "/sign-in"} "Sign in"]
         " to place the order — the cart comes with you."])])])
