### shop/cart/repository — every query about a cart and its lines.
###
### Two tables, one repository, because they are one aggregate: a line
### has no meaning without the cart it is in, and nothing outside this
### module ever addresses a `cart_items` row directly.
###
### `lines` is the one query in the application with a `:preload` on it,
### and it is explicit because the alternative is an N+1 nobody notices
### until the cart page is the slowest page in the shop. The suite runs
### the guard at `:strict`, so a relation touched without one is a failure
### rather than a warning.
(import void/db :as db)
(import ../../shared/values :as values)
(import ./cart.model :as model)

# -- carts ---------------------------------------------------------------

(defn find-by-token
  "The cart behind a browser's token, or nil."
  [token]
  (when token (db/one model/Cart {:where [:= :token token]})))

(defn create!
  "Open a cart for a token nobody has used yet."
  [token]
  (def now (values/now))
  (db/insert! model/Cart {:token token :created-at now :updated-at now}))

(defn touch!
  "Say that this cart was used, which is what the sweep reads."
  [cart]
  (db/update! model/Cart (cart :id) {:updated-at (values/now)}))

(defn attach-customer!
  "Put a name on a cart that had none."
  [cart customer-id]
  (db/update! model/Cart (cart :id) {:customer-id customer-id
                                     :updated-at (values/now)}))

(defn delete!
  "Drop the cart itself — what the checkout does with the one it turned
  into an order."
  [cart]
  (db/delete! model/Cart (cart :id)))

(defn delete-stale!
  ``Delete carts nobody has touched since `cutoff` and that belong to
  nobody, and the lines with them (ON DELETE CASCADE). Returns how many
  went.``
  [cutoff]
  (db/delete-where! model/Cart [:and
                                [:< :updated-at cutoff]
                                [:= :customer-id nil]]))

# -- lines ---------------------------------------------------------------

(defn lines
  "The lines of a cart, each with its product already loaded."
  [cart]
  (db/query model/CartItem {:where [:= :cart-id (cart :id)]
                            :order-by [[:id :asc]]
                            :preload [:product]}))

(defn find-line
  ``One line, addressed by **product** rather than by its own id. A
  form that posts a line id is a form somebody can post *another*
  cart's line id to, and then the check that it belongs here is a thing
  the handler has to remember. This way there is nothing to
  remember.``
  [cart product-id]
  (db/one model/CartItem {:where [:and
                                  [:= :cart-id (cart :id)]
                                  [:= :product-id product-id]]}))

(defn add-line!
  "A line that was not there."
  [cart product-id quantity]
  (db/insert! model/CartItem {:cart-id (cart :id)
                              :product-id product-id
                              :quantity quantity}))

(defn set-line-quantity!
  ``A line that was. `update!` answers with the number of rows it
  wrote, so the row is re-read: a caller that wanted the line and got a
  1 would find that out one layer further away.``
  [line quantity]
  (db/update! model/CartItem (line :id) {:quantity quantity})
  (db/find model/CartItem (line :id)))

(defn remove-line!
  "A line the customer set to zero."
  [line]
  (db/delete! model/CartItem (line :id)))

(defn clear-lines!
  "Empty a cart without deleting it."
  [cart]
  (db/delete-where! model/CartItem [:= :cart-id (cart :id)]))

(defn count-items
  ``How many items a cart holds, without loading a product per line.
  The badge in the header is on every page in the shop, and it has no
  business joining the catalog to render a number.``
  [cart]
  (sum (map |($ :quantity)
            (db/query model/CartItem {:where [:= :cart-id (cart :id)]}))))
