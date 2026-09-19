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
  {:params [@{:id :number & r}] :ret :tuple :throws [:string]}
  ``The "add to cart" control. It lives in this module rather than in
  the catalog's view because the form is about a cart — the catalog
  module calls it, and does not have to know what it posts.``
  [product]
  (form/form dto/AddToCart
    {:action "/cart/items"
     :values {:product-id (product :id) :quantity 1}
     :fields {:product-id {:control :input :type "hidden" :label ""}
              :quantity {:control :input :type "number"}}
     :submit "Add to cart"}))

(defn- quantity-form
  {:params [@{:product-id :number :quantity :number & r}] :ret :tuple :throws [:string]}
  ``The quantity control: an htmx post that swaps the whole cart back
  in. The line is addressed by *product*, not by the line's own id
  (./cart.repository explains why), and the token rides on the form
  because void/security spliced it.``
  [line]
  (form/form dto/SetQuantity
    {:action (string "/cart/items/" (line :product-id))
     :values {:quantity (line :quantity)}
     :fields {:quantity {:control :input :type "number" :label ""}}
     :submit "Update"
     :attrs (merge {:class "inline-form"}
                   (hx/post (string "/cart/items/" (line :product-id))
                            :target "#cart" :swap :outer-html))}))

(defn cart-view
  {:params [[@{:id :number :cart-id :number :product-id :number :quantity :number & r}]
            {:count :number :subtotal-cents :number}
            (or {:tone :string? :message :string? & r} :nil)]
   :ret :tuple
   :throws [:string]}
  ``The cart, and the one control that matters. `db/rel` is a table
  lookup here because ./cart.repository preloaded the products; without
  the preload this page would be an N+1 that only shows up when
  somebody fills a basket.``
  [lines summary &opt state]
  (default state {})
  [:div {:id "cart"}
   [:h1 {:class "text-3xl font-bold tracking-tight"} "Your cart"]
   (layout/notice state)
   (if (empty? lines)
     [:p {:class "mt-6 rounded-2xl border border-dashed border-slate-300 px-5 py-10 text-center text-slate-400"}
      "Nothing in it yet. "
      [:a {:class "text-indigo-600 no-underline hover:underline" :href "/"}
       "Have a look around"] "."]
     [:div {:class "mt-8"}
      [:div {:class "overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm"}
       [:table {:class "w-full border-collapse text-left"}
        [:thead {:class "border-b border-slate-200 bg-slate-50 text-xs uppercase tracking-widest text-slate-500"}
         [:tr [:th {:class "px-5 py-3 font-medium"} "Item"]
          [:th {:class "px-5 py-3 text-right font-medium"} "Price"]
          [:th {:class "px-5 py-3 font-medium"} "Quantity"]
          [:th {:class "px-5 py-3 text-right font-medium"} "Total"]]]
        [:tbody
         (seq [line :in lines]
           (let [product (db/rel line :product)]
             [:tr {:class "border-b border-slate-100 last:border-0"}
              [:td {:class "px-5 py-4"}
               [:a {:class "font-medium text-slate-900 no-underline hover:text-indigo-700"
                    :href (string "/products/" (product :id))}
                (product :name)]]
              [:td {:class "px-5 py-4 text-right tabular-nums"}
               (values/format-price (product :price-cents))]
              [:td {:class "px-5 py-4"} (quantity-form line)]
              [:td {:class "px-5 py-4 text-right font-medium tabular-nums"}
               (values/format-price (service/line-total line))]]))]
        [:tfoot {:class "border-t border-slate-200 bg-slate-50"}
         [:tr [:td {:class "px-5 py-4 font-semibold" :colspan "3"} "Total"]
          [:td {:class "px-5 py-4 text-right text-lg font-semibold tabular-nums"}
           (values/format-price (summary :subtotal-cents))]]]]]
      [:div {:class "mt-6"}
       (if (auth/current-user)
         (form/form {} {:action "/checkout" :submit "Place the order"
                        :attrs {:class "cta"}})
         [:p {:class "rounded-lg border border-slate-200 bg-white px-4 py-3 text-sm text-slate-600"}
          [:a {:class "font-medium text-indigo-600 no-underline hover:underline" :href "/sign-in"}
           "Sign in"]
          " to place the order — the cart comes with you."])]])])
