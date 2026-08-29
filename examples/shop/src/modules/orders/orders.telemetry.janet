### shop/orders/telemetry — the four numbers this shop is judged on.
###
### **The label sets are small on purpose.** `:reason` is one of four
### words, and it is never an order number, a sku or a customer id. A
### metric labelled by anything a customer chooses is a cardinality
### incident waiting for the day somebody scripts the checkout —
### void/obs caps it (`:max-label-sets`) rather than falling over, but
### the cap is a seatbelt and this is the driving.
###
### The writes at the bottom are thin functions rather than bare
### `obs/inc!` calls at the call sites: what a label means is a
### decision, and a decision belongs in one place.
(import void/obs :as obs)
(import ./orders.repository :as repo)

(def orders-placed
  "Orders that made it through the checkout transaction."
  (obs/counter :shop/orders-placed-total
    {:doc "Orders placed (the checkout transaction committed)"}))

(def order-value
  ``What those orders were worth, in euros — a histogram rather than a
  total, because "we took €14 000 today" and "we took it in four
  orders" are different shops. The buckets are this catalog's price
  range; a shop selling cars would pick others.``
  (obs/histogram :shop/order-value-euros
    {:doc "Order totals in euros"
     :buckets [5 10 25 50 100 250 500 1000]}))

(def checkout-rejected
  ``Checkouts that did not become an order, by why. `:reason` is one of
  a closed set — `empty`, `out-of-stock`, `gone` — so this is a
  dashboard panel and not a cardinality bomb.``
  (obs/counter :shop/checkout-rejected-total
    {:doc "Checkouts refused, by reason"
     :labels [:reason]}))

(def unpaid-orders
  ``Orders that have been placed and not yet paid — the queue depth of
  the money side of this shop. Pull-based, like the cart gauge: it is a
  property of the database rather than a count of events this process
  saw.``
  (obs/gauge :shop/unpaid-orders
    {:doc "Orders in the placed state"
     :collect (fn collect-unpaid [] (repo/count-placed))}))

(defn order-placed!
  "One order, worth this many cents."
  [total-cents]
  (obs/inc! orders-placed)
  (obs/observe! order-value nil (/ total-cents 100)))

(defn checkout-rejected!
  "One checkout that did not become an order."
  [reason]
  (obs/inc! checkout-rejected [(string reason)]))
