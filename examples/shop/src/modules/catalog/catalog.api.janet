### shop/catalog/api — the same module's JSON controller.
###
### An API in void is not a second application, it is a second
### *controller* over the same service. This file calls
### ./catalog.service exactly as ./catalog.controller does; what
### differs is that it answers with ./catalog.dto instead of
### ./catalog.view, and that its routes carry schema metadata
### void/rest and void/openapi read.
###
### Three decisions worth naming.
###
### **The catalog is cached at the response, the storefront is not.**
### `:void.cache/response {:ttl 30}` on the index means the second
### request for the same page does not reach a handler at all. That is
### only sound because this response is the same for everybody — the
### storefront's HTML carries a cart badge and a name, which is why it
### caches the *query* instead (./catalog.service).
###
### **The API pages, the storefront does not.** void/rest's convention
### (`?page=2&per-page=50&sort=-sku`) is one merge into the query schema
### and one call in the handler; the storefront has fifty products and
### a scroll bar.
###
### **`/openapi.json` is a projection.** Nothing in this file mentions
### OpenAPI: the document is built out of the route table, the query
### schema and the `:response` names, which are the same declarations
### the validation middleware enforces.
(import void/http/router :as router)
(import void/rest :as rest)
(import void/rest/pagination :as pagination)
(import ./catalog.service :as service)
(import ./catalog.dto :as dto)

(defn products-index
  "GET /api/products — the catalog, paged and sortable."
  [req]
  (def paging (pagination/params req {:allowed-sort [:sku :name :price-cents]}))
  (def result (service/page {:order-by (if (empty? (paging :sort))
                                         [[:sku :asc]]
                                         (paging :sort))
                             :limit (paging :limit)
                             :offset (paging :offset)}))
  (rest/json (pagination/envelope (map dto/product-view (result :rows))
                                  (merge paging {:total (result :total)}))))

(defn product-show
  "GET /api/products/:id"
  [req]
  (if-let [p (service/on-sale (get-in req [:params :id]))]
    (rest/json (dto/product-view p))
    (rest/abort 404 "no such product")))

(def resource
  (rest/resource :api.products "/api/products"
    {:id-schema [:int {:min 1}]
     :meta {:void.authz/policy :public
            :void.openapi/tags [:catalog]
            # a public JSON endpoint is the one an unknown client
            # hammers; the limit is per address and generous enough
            # that a page of a catalog is never the thing it stops
            :void.security/rate {:limit 120 :window 60 :key :ip}}}
    {:index {:handler 'products-index
             :query (merge (pagination/query-schema)
                           {:sort [:optional :string]})
             :response {200 :ProductList}
             :meta {:void.openapi/summary "List the catalog"
                    # the same answer for everybody, so it is cacheable
                    # at the response — see the module docstring
                    :void.cache/response {:ttl 30}}}
     :show {:handler 'product-show
            :response {200 :ProductView}
            :meta {:void.openapi/summary "One product"}}}))

(router/defroutes :shop.catalog/api
  resource)
