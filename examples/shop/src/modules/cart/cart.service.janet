### shop/cart/service — what a cart does, as functions of a cart.
###
### No request appears in this file. The session is a request concern
### and lives one layer up (./cart.session); everything below is a
### function of a cart row and the database, which is what lets the
### checkout, the sweep, a test and the header all talk about a cart
### without one of them dragging an HTTP request into the others.
(import void/core/log :as log)
(import void/db :as db)
(import ../../shared/values :as values)
(import ./cart.repository :as repo)

(def log-ns "shop.cart")

(defn find-by-token
  ``The cart behind a token, or nil. A read: a page that shows an empty
  basket must not create a row for every crawler that walks the
  catalog.``
  [token]
  (repo/find-by-token token))

(defn open!
  "A brand-new cart, and the token the browser will hold it by."
  []
  (def token (values/token))
  (def cart (repo/create! token))
  (log/debug "cart opened" :ns log-ns :cart (cart :id))
  {:cart cart :token token})

(defn adopt!
  ``Attach a cart to whoever just signed in. The reason the cart
  survives the login: the row was already there, it just did not have a
  name on it yet.``
  [cart customer-id]
  (when (and cart (not= customer-id (cart :customer-id)))
    (repo/attach-customer! cart customer-id)))

(defn lines
  "The lines of a cart, with their products."
  [cart]
  (repo/lines cart))

(defn add!
  ``Put `quantity` of a product in the cart, or raise the line that is
  already there. Returns the line.

  The unique index on (cart_id, product_id) is what makes "or raise the
  line that is already there" true under two clicks at once: the second
  insert cannot succeed, so the shape here is the one the database can
  keep.``
  [cart product quantity]
  (def existing (repo/find-line cart (product :id)))
  (def line
    (if existing
      (repo/set-line-quantity! existing (min 99 (+ (existing :quantity) quantity)))
      (repo/add-line! cart (product :id) quantity)))
  (repo/touch! cart)
  line)

(defn set-quantity!
  "Set one line's quantity; 0 removes it. Returns the new quantity."
  [cart product-id quantity]
  (when-let [line (repo/find-line cart product-id)]
    (if (zero? quantity)
      (repo/remove-line! line)
      (repo/set-line-quantity! line quantity))
    (repo/touch! cart))
  quantity)

(defn clear!
  "Empty a cart — what the checkout does with the one it turned into an
  order."
  [cart]
  (repo/clear-lines! cart)
  (repo/touch! cart))

(defn discard!
  "Empty it and delete it. The checkout's last act."
  [cart]
  (repo/clear-lines! cart)
  (repo/delete! cart))

(defn item-count
  "How many items a cart holds — the number in the header's badge."
  [cart]
  (if cart (repo/count-items cart) 0))

(defn line-total
  "What one line costs, in cents."
  [line]
  (* (get line :quantity 0)
     (get (db/rel line :product) :price-cents 0)))

(defn summary
  ``What the header shows and what the checkout re-computes: the number
  of items and what they come to. A pure function of the lines, so a
  test asserts on it without a request anywhere.``
  [lines]
  {:count (sum (map |($ :quantity) lines))
   :subtotal-cents (sum (map line-total lines))})

(defn sweep-stale!
  ``Delete carts nobody has touched in `max-age` seconds and that
  belong to nobody. Returns how many went.``
  [max-age]
  (def cutoff (values/timestamp-before max-age))
  (def n (repo/delete-stale! cutoff))
  (log/info "swept carts" :ns log-ns :deleted n :cutoff cutoff)
  n)
