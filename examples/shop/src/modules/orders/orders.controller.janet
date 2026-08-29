### shop/orders/controller — the checkout, and the two pages after it.
###
### `place-order` is short because the interesting part is not here:
### the stock, the pricing, the outbox message and the payment job are
### one function away (./orders.service), and what is left is which
### page the customer sees.
###
### The refusal page is rendered by the cart module, because the page a
### refused checkout lands on *is* the cart. This module decides what
### the message says; it does not know how a cart is drawn.
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/http/errors :as errors)
(import ../../web/layout :as layout)
(import ../cart/cart.controller :as cart-controller)
(import ../cart/cart.session :as cart-session)
(import ../customers/customers.service :as customers)
(import ./orders.policy :as policy)
(import ./orders.repository :as repo)
(import ./orders.service :as service)
(import ./orders.view :as view)

(defn- refusal-message [result]
  (case (result :reason)
    :empty "There is nothing in your cart."
    :out-of-stock (string "Sorry — "
                          (get-in result [:product :name] "an item")
                          " sold out while you were deciding. "
                          "Nothing has been charged.")
    :gone "One of those products has left the catalog. Nothing has been charged."
    "Something went wrong placing that order. Nothing has been charged."))

(defn place-order
  "POST /checkout — the transaction in ./orders.service, and the two
  answers it can give."
  [req]
  (def customer (or (customers/current) (errors/abort 401)))
  (def result (service/place! (cart-session/current req) customer))
  (cond
    (result :ok)
    (do
      (cart-session/forget! req)
      (ring/redirect (string "/orders/" (get-in result [:order :number]))))

    (cart-controller/checkout-refused req (refusal-message result))))

(defn my-orders
  "GET /orders — the caller's own, newest first."
  [req]
  (layout/page (view/orders-view (repo/of-customer (customers/current-id)))))

(defn show-order
  ``GET /orders/:number — one order.

  The policy on the route already decided that this caller may see it
  (`:orders/own` over `policy/resource`), so the handler loads the row
  and renders it. The check is not repeated here, because a rule
  enforced in two places is a rule that will disagree with itself.``
  [req]
  (def order (or (policy/resource req) (errors/abort 404)))
  (layout/page (view/order-view order (repo/items-of (order :id)))))

(def signed-in
  "Signed in, whoever it is — the two keys a personal route carries."
  {:void.auth/access :required
   :void.authz/policy :authenticated})

(router/defroutes :shop.orders/routes
  (POST "/checkout" place-order
        (merge signed-in
               {:name :checkout/place
                # no :void.db/txn — ./orders.service opens its own,
                # because a rollback here is an answer and not an error
                #
                # a checkout is not a page anybody refreshes fifty
                # times a minute, and the stock decrement is the most
                # expensive statement in the shop
                :void.security/rate {:limit 20 :window 60 :key :subject}}))

  (GET "/orders" my-orders (merge signed-in {:name :orders/index}))
  (GET "/orders/:number" show-order (merge policy/own-order {:name :orders/show})))
