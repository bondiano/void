### shop/cart/controller — three routes, no identity required.
###
### The cart is open to everybody, including the visitor who has not
### said who they are — which is the whole point of a cart. The routes
### below name `:public` and mean it; signing in later adopts the row
### (customers/customers.controller).
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/http/errors :as errors)
(import void/html/form :as form)
(import ../../web/layout :as layout)
(import ../catalog/catalog.service :as catalog)
(import ./cart.dto :as dto)
(import ./cart.service :as service)
(import ./cart.session :as session)
(import ./cart.view :as view)

(defn- rendered
  "The cart page for this request, with an optional message on it."
  [req &opt state]
  (def cart (session/current req))
  (def lines (if cart (service/lines cart) []))
  (layout/page (view/cart-view lines (service/summary lines) (or state {}))))

(defn show-cart
  "GET /cart — the lines, with their products preloaded."
  [req]
  (rendered req))

(defn add-to-cart
  ``POST /cart/items — put something in the basket.

  No identity is required and none is invented: the cart belongs to
  the session, and the row is created here rather than on every page
  view.``
  [req]
  (def result (form/check dto/AddToCart (req :form)))
  # the form is a hidden id and a number, so a submission that fails
  # the schema is a broken client rather than a customer making a
  # mistake — there is no field to send back to
  (unless (empty? (result :errors)) (errors/abort 400))
  (def v (result :value))
  (def product (or (catalog/on-sale (v :product-id)) (errors/abort 404)))
  (service/add! (session/ensure! req) product (v :quantity))
  (ring/redirect "/cart"))

(defn update-line
  ``POST /cart/items/:id — set a line's quantity (0 removes it).

  Answers htmx with the cart fragment alone (`:void.htmx/partial`),
  which is why the quantity control does not reload the page.``
  [req]
  (def product-id (scan-number (get-in req [:params :id] "")))
  (def cart (session/current req))
  (def result (form/check dto/SetQuantity (req :form)))
  (when (and cart product-id (empty? (result :errors)))
    (service/set-quantity! cart product-id (get-in result [:value :quantity])))
  (rendered req))

(defn checkout-refused
  ``The cart page, with the reason a checkout did not become an order.
  The orders module renders its refusals through this function because
  the page a refused checkout lands on *is* the cart — and the cart
  module is the one that knows how to draw it.``
  [req message]
  (rendered req {:tone "bad" :message message}))

(router/defroutes :shop.cart/routes
  (GET "/cart" show-cart {:name :cart/show :void.authz/policy :public})
  (POST "/cart/items" add-to-cart
        {:name :cart/add :void.db/txn true :void.authz/policy :public})
  (POST "/cart/items/:id" update-line
        {:name :cart/update :void.db/txn true :void.htmx/partial true
         :void.authz/policy :public}))
