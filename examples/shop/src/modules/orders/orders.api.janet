### shop/orders/api — the same orders, as JSON.
###
### Same process, same rows, same policy, same audit trail. What
### differs from ./orders.controller is the DTO and two metadata keys.
###
### **A session cookie is not an API credential.**
### `:void.auth/strategies [:bearer]` on the group means a browser that is
### signed in cannot use its cookie here — which also means these routes
### need no CSRF token, because a request that cannot be authenticated by
### a cookie cannot be forged through one. Mint a token with `void auth
### token customer:1`.
###
### **`:orders/own` is imported, not restated.** The policy and its
### resource loader are ./orders.policy, and the HTML page, this
### endpoint and the admin desk all name the same two values.
(import void/http/router :as router)
(import void/rest :as rest)
(import ../customers/customers.service :as customers)
(import ./orders.dto :as dto)
(import ./orders.policy :as policy)
(import ./orders.repository :as repo)

(defn orders-index
  "GET /api/orders — the caller's own orders, newest first."
  [req]
  (rest/json
    {:data (seq [o :in (repo/of-customer (customers/current-id))]
             (dto/order-view o (repo/items-of (o :id))))}))

(defn order-show
  "GET /api/orders/:number — one order."
  [req]
  (if-let [order (repo/find-by-number (get-in req [:params :number]))]
    (rest/json (dto/order-view order (repo/items-of (order :id))))
    (rest/abort 404 "no such order")))

(def resource
  (rest/resource :api.orders "/api/orders"
    {:meta {:void.auth/access :required
            :void.auth/strategies [:bearer]
            :void.openapi/tags [:orders]
            :void.security/rate {:limit 60 :window 60 :key :subject}}}
    {:index {:handler 'orders-index
             :response {200 :OrderList}
             :meta {:void.authz/policy :authenticated
                    :void.openapi/summary "The caller's orders"}}
     :show {:method :get :path "/:number"
            :handler 'order-show
            :params {:number [:string {:min 4 :max 32}]}
            :response {200 :OrderView}
            :meta {:void.authz/policy :orders/own
                   :void.authz/resource policy/resource
                   :void.openapi/summary "One order of the caller's"}}}))

(router/defroutes :shop.orders/api
  resource)
