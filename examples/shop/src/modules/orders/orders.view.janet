### shop/orders/view — the order list and one order.
###
### `status-pill` is exported because the admin desk draws the same
### badge over the same statuses, and a second stylesheet class for the
### same idea is how two pages start disagreeing about what "paid"
### looks like.
(import ../../shared/values :as values)

(defn status-pill [order]
  [:span {:class (string "status " (order :status))} (order :status)])

(defn orders-view [orders]
  [:div {:id "orders"}
   [:h1 "Your orders"]
   (if (empty? orders)
     [:p "No orders yet."]
     [:table {:class "lines"}
      [:thead [:tr [:th "Number"] [:th "Placed"] [:th "Status"]
               [:th {:class "num"} "Total"]]]
      [:tbody
       (seq [o :in orders]
         [:tr
          [:td [:a {:href (string "/orders/" (o :number))} (o :number)]]
          [:td (o :placed-at)]
          [:td (status-pill o)]
          [:td {:class "num"} (values/format-price (o :total-cents))]])]])])

(defn order-view [order items]
  [:div {:id "order"}
   [:h1 "Order " (order :number)]
   [:p {:class "lede"} "Placed " (order :placed-at) " · " (status-pill order)]
   [:table {:class "lines"}
    [:thead [:tr [:th "Item"] [:th {:class "num"} "Unit"] [:th {:class "num"} "Qty"]
             [:th {:class "num"} "Total"]]]
    [:tbody
     (seq [i :in items]
       [:tr [:td (i :name)]
        [:td {:class "num"} (values/format-price (i :unit-price-cents))]
        [:td {:class "num"} (i :quantity)]
        [:td {:class "num"} (values/format-price (* (i :quantity) (i :unit-price-cents)))]])]
    [:tfoot [:tr [:td {:colspan "3"} "Total"]
             [:td {:class "num"} (values/format-price (order :total-cents))]]]]
   [:p [:a {:href "/orders"} "← All your orders"]]])
