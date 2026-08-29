### shop/cart/model — a basket, and the lines in it.
###
### The interesting decision in a shop is not the cart, it is *whose*
### it is. Here a cart belongs to a **browser**: the row carries a
### random token, the session carries the same token
### (./cart.session), and `customer_id` is null until somebody signs
### in. That is what lets a visitor fill a cart, sign in at the
### checkout and keep it — the alternative, a cart that only exists for
### accounts, is the shop that asks you to log in before it will let
### you shop.
(import void/db :as db)

(db/defentity Cart
  {:id [:int {:db/pk true :db/type "integer"}]
   # the browser's handle on its cart, kept in the session
   :token [:string {:min 8 :max 64 :db/unique true :db/type "text"}]
   :customer-id [:optional [:int {:db/fk :Customer :db/type "integer"}]]
   :created-at [:string {:db/type "text"}]
   :updated-at [:string {:db/type "text"}]}
  :db/table "carts"
  :db/rels {:customer [:belongs-to :Customer :customer-id]
            :items [:has-many :CartItem :cart-id]})

(db/defentity CartItem
  {:id [:int {:db/pk true :db/type "integer"}]
   :cart-id [:int {:db/fk :Cart :db/type "integer"}]
   :product-id [:int {:db/fk :Product :db/type "integer"}]
   :quantity [:int {:min 1 :max 99 :db/type "integer"}]}
  :db/table "cart_items"
  :db/rels {:cart [:belongs-to :Cart :cart-id]
            :product [:belongs-to :Product :product-id]})
