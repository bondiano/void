# A cart belongs to a browser before it belongs to anybody: `token` is
# what the session carries, `customer_id` is filled in when whoever is
# holding it signs in (shop/cart:adopt!). That is why the foreign key
# is nullable and the token is the unique one.

(defn up []
  [{:create-table "carts"
    :columns [[:id :serial {:primary-key true}]
              [:token :text {:null false :unique true}]
              [:customer-id :int {:refs [:customers :id] :on-delete :cascade}]
              [:created-at :text {:null false}]
              [:updated-at :text {:null false}]]}

   {:create-table "cart_items"
    :columns [[:id :serial {:primary-key true}]
              [:cart-id :int {:null false :refs [:carts :id] :on-delete :cascade}]
              [:product-id :int {:null false :refs [:products :id] :on-delete :cascade}]
              [:quantity :int {:null false}]]}

   # one line per product per cart: adding a product that is already in
   # the cart raises the quantity, and the database is what guarantees
   # it rather than the handler remembering to look first
   {:create-index "cart_items_unique_idx" :unique true
    :on "cart_items" :columns [:cart-id :product-id]}

   {:create-index "carts_updated_idx" :on "carts" :columns [:updated-at]}])

(defn down []
  [{:drop-table "cart_items"}
   {:drop-table "carts"}])
