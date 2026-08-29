### shop/admin/controller — the desk, which is three routes and one
### role.
###
### Everything that makes this surface different from the storefront is
### in one metadata key: `:void.authz/policy :staff`, on the group. The
### policy behind it is `(authz/role-policy :staff)`
### (customers/customers.policy), the role is a column on `customers`,
### and the claim that carries it onto the identity is one line of
### `[:auth-db :users :claims-columns]`. There is no admin framework
### here, no second authentication and no separate session — a member
### of staff is a customer with a role, and the desk is the part of the
### shop that asks for it.
###
### This module has no model and no repository. It is a *view* onto
### other modules' data, so it reads through their repositories and
### writes through their services — which is what keeps "only a paid
### order may ship" in one place (orders/orders.service) instead of in
### whichever surface happens to offer the button.
(import void/http/router :as router)
(import void/http/errors :as errors)
(import ../../web/layout :as layout)
(import ../audit/audit.service :as audit)
(import ../orders/orders.repository :as orders-repo)
(import ../orders/orders.service :as orders)
(import ./admin.view :as view)

(defn- desk [&opt state]
  (layout/page (view/desk-view (orders-repo/recent 100) (or state {}))))

(defn desk-page
  "GET /admin/orders"
  [req]
  (desk))

(defn ship
  ``POST /admin/orders/:number/ship — the one write the desk does.

  The announcement rides the transaction (`:void.db/txn true` on the
  route): the orders module mails the dispatch notice, the audit
  module records the line, and neither is named here.``
  [req]
  (def number (get-in req [:params :number]))
  (def order (or (orders-repo/find-by-number number) (errors/abort 404)))
  (desk {:message (if (orders/ship! order)
                    (string "Order " number " is on its way.")
                    (string "Order " number " is " (order :status)
                            " — only a paid order can ship."))}))

(defn trail
  "GET /admin/audit — the last hundred lines of the audit module's
  table."
  [req]
  (layout/page (view/audit-view (audit/trail {:limit 100}))))

# -- routes --------------------------------------------------------------
#
# One group, one policy. `:void.authz/policy` merges by :concat, so a
# route inside this group cannot loosen it — it can only add a second
# policy that must *also* allow (CONTRACTS v1).

(router/defroutes :shop.admin/routes
  (group "/admin" {:void.auth/access :required
                   :void.authz/policy :staff
                   # the document void/openapi builds is a projection of
                   # the *route table*, so without this the desk would be
                   # in the shop's public API description
                   :void.openapi/hidden true}
    (GET "/orders" desk-page {:name :admin/orders})
    (POST "/orders/:number/ship" ship {:name :admin/ship :void.db/txn true})
    (GET "/audit" trail {:name :admin/audit})))
