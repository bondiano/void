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
  {:params [:number] :ret (or @{:any :any} :nil) :throws [:string]}
  "One order by primary key, or nil."
  [id]
  (db/find model/Order id))

(defn find-by-number
  {:params [:string?] :ret (or @{:any :any} :nil) :throws [:string]}
  "One order by the number a customer quotes, or nil."
  [number]
  (when number (db/one model/Order {:where [:= :number number]})))

(defn of-customer
  {:params [:number :number?] :ret @[@{:any :any}] :throws [:string]}
  "One customer's orders, newest first."
  [customer-id &opt limit]
  (db/query model/Order {:where [:= :customer-id customer-id]
                         :order-by [[:id :desc]]
                         :limit (or limit 50)}))

(defn recent
  {:params [:number?] :ret @[@{:any :any}] :throws [:string]}
  "Every order, newest first — what the desk shows."
  [&opt limit]
  (db/query model/Order {:order-by [[:id :desc]] :limit (or limit 100)}))

(defn count-placed
  {:params [] :ret :number :throws [:string]}
  "Orders that have been placed and not yet settled."
  []
  (db/count model/Order {:where [:= :status "placed"]}))

(defn count-by-status
  {:params [:string] :ret :number :throws [:string]}
  "How many orders are in one state — what the desk's front page
  counts, one tile per number."
  [status]
  (db/count model/Order {:where [:= :status status]}))

(defn create!
  {:params [{:number :string :customer-id :number :email :string
             :total-cents :number :placed-at :string & r}]
   :ret @{:any :any}
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Write the order itself."
  [{:number number :customer-id customer-id :email email
    :total-cents total :placed-at placed-at}]
  (db/insert! model/Order {:number number
                           :customer-id customer-id
                           :email email
                           :status "placed"
                           :total-cents total
                           :placed-at placed-at}))

(defn mark-paid!
  {:params [@{:id :number & r}]
   :ret :number
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Mark an order paid, with the timestamp of when."
  [order]
  (db/update! model/Order (order :id) {:status "paid" :paid-at (values/now)}))

(defn mark-cancelled!
  {:params [@{:id :number & r}]
   :ret :number
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Mark an order cancelled."
  [order]
  (db/update! model/Order (order :id) {:status "cancelled"}))

(defn mark-shipped!
  {:params [@{:id :number & r}]
   :ret :number
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Mark an order shipped, with the timestamp of when."
  [order]
  (db/update! model/Order (order :id) {:status "shipped"
                                       :shipped-at (values/now)}))

# -- lines ---------------------------------------------------------------

(defn items-of
  {:params [:number] :ret @[@{:any :any}] :throws [:string]}
  "The lines of an order, in the order they were bought."
  [order-id]
  (db/query model/OrderItem {:where [:= :order-id order-id]
                             :order-by [[:id :asc]]}))

(defn add-item!
  {:params [@{:id :number & r}
            @{:quantity :number & r}
            @{:id :number :sku :string :name :string :price-cents :number & r}]
   :ret @{:any :any}
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
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
  {:params [@{:id :number & r} :number]
   :ret @{:any :any}
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "The pending payment the checkout writes next to the order."
  [order amount-cents]
  (db/insert! model/Payment {:order-id (order :id)
                             :status "pending"
                             :amount-cents amount-cents
                             :attempts 0
                             :updated-at (values/now)}))

(defn latest-payment
  {:params [:number] :ret (or @{:any :any} :nil) :throws [:string]}
  "The payment against an order, or nil."
  [order-id]
  (db/one model/Payment {:where [:= :order-id order-id]
                         :order-by [[:id :desc]]}))

(defn mark-payment-captured!
  {:params [@{:id :number & r} :string :number]
   :ret :number
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Mark a payment captured, with the gateway's reference and how many
  attempts it took."
  [payment reference attempts]
  (db/update! model/Payment (payment :id)
              {:status "captured"
               :reference reference
               :attempts attempts
               :updated-at (values/now)}))

(defn mark-payment-failed!
  {:params [@{:id :number & r} :number]
   :ret :number
   :throws [:string {:void/error :keyword :message :string? :data {:any :any} & r}]}
  "Mark a payment failed, after this many attempts."
  [payment attempts]
  (db/update! model/Payment (payment :id)
              {:status "failed"
               :attempts attempts
               :updated-at (values/now)}))
