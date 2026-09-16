### shop/orders/view — the order list and one order.
###
### `status-pill` is exported because the admin desk draws the same
### badge over the same statuses, and a second stylesheet class for the
### same idea is how two pages start disagreeing about what "paid"
### looks like.
(import ../../shared/values :as values)

(def- status-tones
  "One badge, four readings. The desk draws the same one."
  {"paid" "border-emerald-200 bg-emerald-50 text-emerald-700"
   "shipped" "border-sky-200 bg-sky-50 text-sky-700"
   "cancelled" "border-red-200 bg-red-50 text-red-700"})

(defn status-pill [order]
  [:span {:class (string "inline-block rounded-full border px-2.5 py-0.5 text-xs font-semibold uppercase tracking-wider "
                         (get status-tones (order :status)
                              "border-indigo-200 bg-indigo-50 text-indigo-700"))}
   (order :status)])

(def- th "px-5 py-3 font-medium")
(def- th-num "px-5 py-3 text-right font-medium")
(def- td "px-5 py-4")
(def- td-num "px-5 py-4 text-right tabular-nums")

(defn- table [head body &opt foot]
  "The one table this module draws, twice."
  [:div {:class "mt-8 overflow-hidden rounded-2xl border border-slate-200 bg-white shadow-sm"}
   [:table {:class "w-full border-collapse text-left"}
    [:thead {:class "border-b border-slate-200 bg-slate-50 text-xs uppercase tracking-widest text-slate-500"}
     head]
    [:tbody body]
    foot]])

(defn orders-view [orders]
  [:div {:id "orders"}
   [:h1 {:class "text-3xl font-bold tracking-tight"} "Your orders"]
   (if (empty? orders)
     [:p {:class "mt-6 rounded-2xl border border-dashed border-slate-300 px-5 py-10 text-center text-slate-400"}
      "No orders yet."]
     (table
       [:tr [:th {:class th} "Number"] [:th {:class th} "Placed"]
        [:th {:class th} "Status"] [:th {:class th-num} "Total"]]
       (seq [o :in orders]
         [:tr {:class "border-b border-slate-100 last:border-0"}
          [:td {:class td}
           [:a {:class "font-mono font-medium text-slate-900 no-underline hover:text-indigo-700"
                :href (string "/orders/" (o :number))}
            (o :number)]]
          [:td {:class (string td " text-slate-500")} (o :placed-at)]
          [:td {:class td} (status-pill o)]
          [:td {:class td-num} (values/format-price (o :total-cents))]])))])

(defn order-view [order items]
  [:div {:id "order"}
   [:h1 {:class "text-3xl font-bold tracking-tight"}
    "Order " [:span {:class "font-mono"} (order :number)]]
   [:p {:class "mt-2 flex items-center gap-3 text-slate-500"}
    "Placed " (order :placed-at) (status-pill order)]
   (table
     [:tr [:th {:class th} "Item"] [:th {:class th-num} "Unit"]
      [:th {:class th-num} "Qty"] [:th {:class th-num} "Total"]]
     (seq [i :in items]
       [:tr {:class "border-b border-slate-100 last:border-0"}
        [:td {:class td} (i :name)]
        [:td {:class td-num} (values/format-price (i :unit-price-cents))]
        [:td {:class td-num} (i :quantity)]
        [:td {:class td-num} (values/format-price (* (i :quantity) (i :unit-price-cents)))]])
     [:tfoot {:class "border-t border-slate-200 bg-slate-50"}
      [:tr [:td {:class "px-5 py-4 font-semibold" :colspan "3"} "Total"]
       [:td {:class "px-5 py-4 text-right text-lg font-semibold tabular-nums"}
        (values/format-price (order :total-cents))]]])
   [:p {:class "mt-8"}
    [:a {:class "text-sm text-slate-500 no-underline hover:text-slate-900" :href "/orders"}
     "← All your orders"]]])
