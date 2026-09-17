### shop/catalog/controller — two routes, and what a controller is for.
###
### A controller in this application does four things and no others:
### it unpacks the request, calls the service, picks the view, and
### chooses the status. It holds no SQL, no transaction, no business
### rule — those are ./catalog.repository and ./catalog.service, and
### the reason the split is worth having is that everything below the
### controller can be read, changed and tested without a request
### existing.
###
### Read the route table at the bottom first. Almost everything this
### application does about transactions, authentication, authorization,
### CSRF, caching and rate limiting is *there*, as metadata:
###
###   :void.db/txn true            the whole of transaction management
###   :void.db/load {:entity …}    the whole of "that row, or a 404"
###   :void.auth/access :required  the whole of "you must be signed in"
###   :void.authz/policy …         the whole of "and it must be yours"
###   :void.security/rate …        the whole of "and not fifty times a minute"
###
### Handlers are registered as symbols, so a redefinition in the repl — or
### a save with `void dev` running — is live.
(import void/http/router :as router)
(import ../../web/layout :as layout)
(import ./catalog.model :as model)
(import ./catalog.service :as service)
(import ./catalog.view :as view)

(defn storefront
  {:params [:any]
   :ret @{:status :number :headers @{:string :string} :void.html/content :any
         :void.html/layout :any :void.html/context {:any :any} & r}
   :throws [:string]}
  "GET / — the catalog, out of the cache."
  [req]
  (layout/page (view/catalog-view (service/listing))))

(defn show-product
  {:params [{:void.db/row :any & r}]
   :ret @{:status :number :headers @{:string :string} :void.html/content :any
         :void.html/layout :any :void.html/context {:any :any} & r}}
  ``GET /products/:id — the product the route's `:void.db/load` put on
  the request, whatever its status (an archived product still has a
  page; it just cannot be bought).``
  [req]
  (layout/page (view/product-view (req :void.db/row))))

(router/defroutes :shop.catalog/routes
  (GET "/" storefront {:name :catalog/index :void.authz/policy :public})
  (GET "/products/:id" show-product
       {:name :catalog/show :void.authz/policy :public
        :void.db/load {:entity model/Product}}))
