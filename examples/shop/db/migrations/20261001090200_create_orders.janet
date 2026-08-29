# An order is the part of a shop that must never change under a
# customer's feet, which is why `order_items` copies the sku, the name
# and the unit price instead of joining to `products` for them: the
# catalog is free to move afterwards and the invoice still says what
# was sold and for how much. `product_id` stays as a nullable link,
# for the reporting query rather than for the receipt.

(defn up []
  [{:create-table "orders"
    :columns [[:id :serial {:primary-key true}]
              [:number :text {:null false :unique true}]
              [:customer-id :int {:null false :refs [:customers :id]}]
              [:email :text {:null false}]
              [:status :text {:null false :default "placed"}]
              [:total-cents :int {:null false}]
              [:placed-at :text {:null false}]
              [:paid-at :text]
              [:shipped-at :text]]}

   {:create-table "order_items"
    :columns [[:id :serial {:primary-key true}]
              [:order-id :int {:null false :refs [:orders :id] :on-delete :cascade}]
              [:product-id :int {:refs [:products :id] :on-delete :set-null}]
              [:sku :text {:null false}]
              [:name :text {:null false}]
              [:unit-price-cents :int {:null false}]
              [:quantity :int {:null false}]]}

   # the capture attempt, as a row: the job in shop/jobs updates it,
   # and a payment that never succeeded is the difference between an
   # order that is waiting and one nobody is coming back to
   {:create-table "payments"
    :columns [[:id :serial {:primary-key true}]
              [:order-id :int {:null false :refs [:orders :id] :on-delete :cascade}]
              [:status :text {:null false :default "pending"}]
              [:amount-cents :int {:null false}]
              [:reference :text]
              [:attempts :int {:null false :default 0}]
              [:updated-at :text {:null false}]]}

   {:create-index "orders_customer_idx" :on "orders" :columns [:customer-id]}
   {:create-index "orders_status_idx" :on "orders" :columns [:status]}
   {:create-index "order_items_order_idx" :on "order_items" :columns [:order-id]}
   {:create-index "payments_order_idx" :on "payments" :columns [:order-id]}])

(defn down []
  [{:drop-table "payments"}
   {:drop-table "order_items"}
   {:drop-table "orders"}])
