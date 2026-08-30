### shop/orders/service — the one transaction this application is
### about.
###
### Everything a shop is afraid of happens in `place!`: two customers
### buying the last unit, a price that changed while a cart sat open,
### an order that exists but that nobody was told about. So this is
### where the framework's transactional pieces are actually used, and
### each one of them answers one of those fears.
###
### **Stock is decremented by a conditional UPDATE.** The statement is
### in catalog/catalog.repository (`reserve-stock!`) because it is a
### write against the products table, and its WHERE clause is the whole
### of the overselling story: the database decides, and the
### affected-row count is the answer.
###
### **The price is re-read here, never carried.** The cart holds a
### product id and a quantity and no money at all (cart/cart.model), so
### a form cannot claim a price and a cart that sat open for a week
### cannot buy last week's price.
###
### **The transaction is this function's, not the route's.**
### `:void.db/txn true` on a route is the right thing when the
### transaction is the whole request (see the other writes in this
### application). Here the interesting outcome is a *rollback that is
### not an error*: the last unit went to somebody else half a
### millisecond ago, which is a page with a message on it and not a
### 500. `db/rollback!` unwinds to the `with-tx` that opened it, which
### returns nil, and the reason — set before the unwind — is what the
### controller renders.
###
### **The announcement rides the transaction.** `bus/publish-tx!`
### writes `:order/placed` into the outbox in this same transaction
### (ADR-0012), and `jobs/enqueue` writes the payment capture into the
### same one again (void/jobs-db). So the order, the fact that it
### happened and the work it causes commit together: no receipt for an
### order that rolled back, and no order that nobody charges.
###
### Nothing in this file mentions a request, a session or a page. The
### controller hands it a cart and a customer and renders what comes
### back.
(import void/core/log :as log)
(import void/db :as db)
(import void/jobs :as jobs)
(import void/bus :as bus)
(import ../../shared/values :as values)
(import ../cart/cart.service :as cart)
(import ../catalog/catalog.repository :as catalog-repo)
(import ../catalog/catalog.service :as catalog)
(import ./orders.repository :as repo)
(import ./orders.telemetry :as telemetry)

(def log-ns "shop.orders")

(defn place!
  ``Turn a cart into an order.

  Returns `{:ok true :order <order>}`, or `{:ok false :reason …}` with
  `:empty`, `:gone` (a product left the catalog while the cart held
  it) or `:out-of-stock` plus the `:product` that ran out. Every
  failure has rolled everything back by the time it is returned.``
  [cart customer]
  (def lines (if cart (cart/lines cart) []))

  (when (empty? lines)
    (telemetry/checkout-rejected! :empty)
    (break {:ok false :reason :empty}))

  # set inside the transaction, read after it: a rollback unwinds the
  # stack, so the reason has to be somewhere the unwind does not reach
  (var refused nil)
  (def now (values/now))

  (def order
    (db/with-tx
      (var total 0)
      (def priced @[])
      (each line lines
        (def product (db/rel line :product))
        (cond
          (or (nil? product) (not= "active" (product :status)))
          (do (set refused {:reason :gone :line line})
              (db/rollback!))

          (not (catalog-repo/reserve-stock! (product :id) (line :quantity)))
          (do (set refused {:reason :out-of-stock :product product})
              (db/rollback!))

          (do
            (+= total (* (line :quantity) (product :price-cents)))
            (array/push priced [line product]))))

      (def order (repo/create! {:number (values/order-number)
                                :customer-id (customer :id)
                                :email (customer :email)
                                :total-cents total
                                :placed-at now}))
      (each [line product] priced
        (repo/add-item! order line product))
      (repo/open-payment! order total)

      (cart/discard! cart)

      # the work this order causes, written into the same transaction
      # by void/jobs-db: an order nobody charges cannot exist, and a
      # capture for an order that rolled back cannot either
      (jobs/enqueue :capture-payment (order :id))

      # and the fact, through the outbox: ./orders.events mails the
      # receipt and the audit module records the line, neither of them
      # known here
      (bus/publish-tx! :order/placed
                       {:order (order :id)
                        :number (order :number)
                        :total-cents total
                        :email (order :email)
                        :actor (string "customer:" (customer :id))
                        :at now})
      order))

  (cond
    order
    (do
      (telemetry/order-placed! (order :total-cents))
      (log/info "order placed" :ns log-ns
                :order (order :number) :total (order :total-cents))
      {:ok true :order order})

    refused
    (do
      (telemetry/checkout-rejected! (refused :reason))
      (log/info "checkout refused" :ns log-ns :reason (refused :reason))
      (merge {:ok false} refused))

    # `with-tx` returned nil and nobody set a reason: the transaction
    # was rolled back by something other than this code, and saying so
    # is better than inventing a reason for the page
    (do
      (telemetry/checkout-rejected! :rolled-back)
      {:ok false :reason :rolled-back})))

(defn restock!
  ``Put an order's units back on the shelf, and drop the cached
  listing. A **compensation**: the checkout already took the stock, so
  cancelling an order is not "do nothing", it is "undo that".``
  [order-id]
  (each item (repo/items-of order-id)
    (when-let [pid (item :product-id)]
      (catalog-repo/release-stock! pid (item :quantity))))
  (catalog/forget-listing!))

(defn settle-paid!
  "The card was charged: the payment, the order and the fact, together."
  [order payment reference attempts]
  (db/with-tx
    (repo/mark-payment-captured! payment reference attempts)
    (repo/mark-paid! order)
    (bus/publish-tx! :order/paid
                     {:order (order :id)
                      :number (order :number)
                      :total-cents (order :total-cents)
                      :email (order :email)
                      :reference reference
                      :at (values/now)})))

(defn settle-cancelled!
  "It was not, and will not be: the order goes, and the stock comes
  back."
  [order payment reason attempts]
  (db/with-tx
    (repo/mark-payment-failed! payment attempts)
    (repo/mark-cancelled! order)
    (restock! (order :id))
    (bus/publish-tx! :order/cancelled
                     {:order (order :id)
                      :number (order :number)
                      :email (order :email)
                      :reason reason
                      :at (values/now)})))

(defn awaiting-shipment
  "How many paid orders are waiting for the courier — one number on the
  desk's front page, and the queue the desk works through."
  []
  (repo/count-by-status "paid"))

(defn unsettled
  "How many orders have been placed and not yet paid or cancelled."
  []
  (repo/count-placed))

(defn ship!
  ``Mark a paid order shipped, and say whether it happened.

  Only a paid order can ship, and the check is here rather than in the
  desk's view: the view hides the button, and a hidden button is a
  hint, not a rule. The rule is a state transition, and the place a
  state transition belongs is next to the write that performs it.``
  [order]
  (when (= "paid" (order :status))
    (repo/mark-shipped! order)
    (bus/publish-tx! :order/shipped
                     {:order (order :id)
                      :number (order :number)
                      :email (order :email)
                      :at (values/now)})
    (log/info "order shipped" :ns log-ns :order (order :number))
    true))
