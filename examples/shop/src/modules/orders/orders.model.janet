### shop/orders/model — the order aggregate: three tables, one module.
###
### An order, its lines and the payment against it are one thing that
### is written together and read together, so they are one model file
### and one repository. Nothing outside this module addresses an
### `order_items` or a `payments` row.
###
### **A line of an order is a copy, not a reference.** `OrderItem`
### carries the sku, the name and the unit price it was bought at.
### A product may be renamed, repriced or deleted afterwards and the
### order still says what was sold and for how much — which is what an
### invoice is. The `product-id` stays as a link for reporting, and it
### is nullable for the day a product is deleted.
(import void/db :as db)

(db/defentity Order
  {:id [:int {:db/pk true :db/type "integer"}]
   # what a human quotes on the phone; unique, and not the primary key
   :number [:string {:min 4 :max 32 :db/unique true :db/type "text"}]
   :customer-id [:int {:db/fk :Customer :db/type "integer"}]
   # copied off the customer at checkout: a receipt goes where the
   # order said, not where the account was later moved to
   :email [:string {:format :email :db/type "text"}]
   # placed -> paid -> shipped, or placed -> cancelled.
   # ./orders.service writes the first, ./orders.jobs the second, the
   # admin module the third.
   :status [:enum "placed" "paid" "shipped" "cancelled"]
   :total-cents [:int {:min 0 :db/type "integer"}]
   :placed-at [:string {:db/type "text"}]
   :paid-at [:optional [:string {:db/type "text"}]]
   :shipped-at [:optional [:string {:db/type "text"}]]}
  :db/table "orders"
  :db/rels {:customer [:belongs-to :Customer :customer-id]
            :items [:has-many :OrderItem :order-id]
            :payments [:has-many :Payment :order-id]})

(db/defentity OrderItem
  {:id [:int {:db/pk true :db/type "integer"}]
   :order-id [:int {:db/fk :Order :db/type "integer"}]
   # nullable: the product may be deleted, the line may not
   :product-id [:optional [:int {:db/fk :Product :db/type "integer"}]]
   :sku [:string {:min 1 :max 40 :db/type "text"}]
   :name [:string {:min 1 :max 120 :db/type "text"}]
   :unit-price-cents [:int {:min 0 :db/type "integer"}]
   :quantity [:int {:min 1 :max 99 :db/type "integer"}]}
  :db/table "order_items"
  :db/rels {:order [:belongs-to :Order :order-id]
            :product [:belongs-to :Product :product-id]})

(db/defentity Payment
  {:id [:int {:db/pk true :db/type "integer"}]
   :order-id [:int {:db/fk :Order :db/type "integer"}]
   # pending -> captured, or pending -> failed after the last attempt
   :status [:enum "pending" "captured" "failed"]
   :amount-cents [:int {:min 0 :db/type "integer"}]
   # what the (imaginary) gateway called this capture, once it answered
   :reference [:optional [:string {:max 64 :db/type "text"}]]
   :attempts [:int {:min 0 :db/type "integer"}]
   :updated-at [:string {:db/type "text"}]}
  :db/table "payments"
  :db/rels {:order [:belongs-to :Order :order-id]})
