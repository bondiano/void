### shop/orders/repository — every query about an order, its lines and
### its payment.
###
### The writes here are deliberately dumb: `mark-paid!` sets two
### columns and nothing else. Whether an order *may* be marked paid,
### what else happens when it is, and which transaction all of it
### commits in are decisions, and decisions are ./orders.service.
(import void/db :as db)
(import ../../shared/values :as values)
(import ./orders.model :as model)

# -- orders --------------------------------------------------------------

(defn find-by-id
  "One order by primary key, or nil."
  [id]
  (db/find model/Order id))

(defn find-by-number
  "One order by the number a customer quotes, or nil."
  [number]
  (when number (db/one model/Order {:where [:= :number number]})))

(defn of-customer
  "One customer's orders, newest first."
  [customer-id &opt limit]
  (db/query model/Order {:where [:= :customer-id customer-id]
                         :order-by [[:id :desc]]
                         :limit (or limit 50)}))

(defn recent
  "Every order, newest first — what the desk shows."
  [&opt limit]
  (db/query model/Order {:order-by [[:id :desc]] :limit (or limit 100)}))

(defn count-placed
  "Orders that have been placed and not yet settled."
  []
  (db/count model/Order {:where [:= :status "placed"]}))

(defn create!
  "Write the order itself."
  [{:number number :customer-id customer-id :email email
    :total-cents total :placed-at placed-at}]
  (db/insert! model/Order {:number number
                           :customer-id customer-id
                           :email email
                           :status "placed"
                           :total-cents total
                           :placed-at placed-at}))

(defn mark-paid! [order]
  (db/update! model/Order (order :id) {:status "paid" :paid-at (values/now)}))

(defn mark-cancelled! [order]
  (db/update! model/Order (order :id) {:status "cancelled"}))

(defn mark-shipped! [order]
  (db/update! model/Order (order :id) {:status "shipped"
                                       :shipped-at (values/now)}))

# -- lines ---------------------------------------------------------------

(defn items-of
  "The lines of an order, in the order they were bought."
  [order-id]
  (db/query model/OrderItem {:where [:= :order-id order-id]
                             :order-by [[:id :asc]]}))

(defn add-item!
  ``One line, as a copy of what was bought (see ./orders.model).``
  [order line product]
  (db/insert! model/OrderItem {:order-id (order :id)
                               :product-id (product :id)
                               :sku (product :sku)
                               :name (product :name)
                               :unit-price-cents (product :price-cents)
                               :quantity (line :quantity)}))

# -- payments ------------------------------------------------------------

(defn open-payment!
  "The pending payment the checkout writes next to the order."
  [order amount-cents]
  (db/insert! model/Payment {:order-id (order :id)
                             :status "pending"
                             :amount-cents amount-cents
                             :attempts 0
                             :updated-at (values/now)}))

(defn latest-payment
  "The payment against an order, or nil."
  [order-id]
  (db/one model/Payment {:where [:= :order-id order-id]
                         :order-by [[:id :desc]]}))

(defn mark-payment-captured! [payment reference attempts]
  (db/update! model/Payment (payment :id)
              {:status "captured"
               :reference reference
               :attempts attempts
               :updated-at (values/now)}))

(defn mark-payment-failed! [payment attempts]
  (db/update! model/Payment (payment :id)
              {:status "failed"
               :attempts attempts
               :updated-at (values/now)}))
