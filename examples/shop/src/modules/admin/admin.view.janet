### shop/admin/view — the desk, and the trail next door.
###
### The status badge comes from the orders module rather than being
### drawn again here: two stylesheet classes for the same idea is how
### two pages start disagreeing about what "paid" looks like.
(import void/html/form :as form)
(import ../../shared/values :as values)
(import ../../web/layout :as layout)
(import ../orders/orders.view :as orders-ui)

(defn- row [order]
  [:tr
   [:td [:a {:href (string "/orders/" (order :number))} (order :number)]]
   [:td (order :email)]
   [:td (order :placed-at)]
   [:td (orders-ui/status-pill order)]
   [:td {:class "num"} (values/format-price (order :total-cents))]
   [:td
    (when (= "paid" (order :status))
      (form/form {} {:action (string "/admin/orders/" (order :number) "/ship")
                     :submit "Mark shipped"}))]])

(defn desk-view
  [orders &opt state]
  (default state {})
  [:div {:id "desk"}
   [:h1 "The desk"]
   [:p {:class "lede"} "Every order, newest first. "
    [:a {:href "/admin/audit"} "The audit trail"] " is next door."]
   (layout/notice state)
   [:table {:class "lines"}
    [:thead [:tr [:th "Number"] [:th "Customer"] [:th "Placed"] [:th "Status"]
             [:th {:class "num"} "Total"] [:th ""]]]
    [:tbody (if (empty? orders)
              [:tr [:td {:colspan "6"} "No orders yet."]]
              (seq [o :in orders] (row o)))]]])

(defn audit-view [events]
  [:div {:id "audit"}
   [:h1 "Audit trail"]
   [:p {:class "lede"}
    "Written by one bus consumer (modules/audit/audit.consumer.janet) that "
    "nothing calls. Domain facts arrive through the transactional outbox, "
    "the queue's lifecycle arrives from void/bus-jobs, and refusals arrive "
    "from void/authz's decision hook."]
   [:table {:class "lines"}
    [:thead [:tr [:th "At"] [:th "Topic"] [:th "Actor"] [:th "Correlation"] [:th "Detail"]]]
    [:tbody
     (if (empty? events)
       [:tr [:td {:colspan "5"} "Nothing recorded yet."]]
       (seq [ev :in events]
         [:tr
          [:td (ev :at)]
          [:td [:code (ev :topic)]]
          [:td (or (ev :actor) "—")]
          [:td [:code (string/slice (ev :correlation-id) 0 8)]]
          [:td [:code (ev :detail)]]]))]]])
