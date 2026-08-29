### shop/catalog/service — the rules about a catalog, which are two.
###
### A service is where a decision lives that is neither SQL nor HTTP:
### here, "the storefront listing is cached and the product page is
### not", and "a product that is not active does not exist as far as a
### visitor is concerned". Both are things a shop could change its mind
### about, and neither is a query.
###
### Nothing in this file takes a request. The controller unpacks the
### request and calls these functions with values, which is what lets
### the interesting half be read — and tested — without a socket.
(import void/core/log :as log)
(import void/cache :as cache)
(import ./catalog.repository :as repo)

(def log-ns "shop.catalog")

(def listing-key
  "The one cached read in this application — the storefront listing."
  "catalog:index")

(defn listing
  ``The storefront listing, through the cache.

  What goes in is **data**, not entities: a shared cache is another
  process's memory (in production this is redis — see config/prod), and
  an entity instance carries a prototype, a load-time snapshot and its
  preloads, none of which survive a round trip through a codec.
  Caching the five columns the cards render is the honest amount of
  work to save.``
  []
  (cache/remember listing-key {:ttl 60}
    (fn load-catalog []
      (log/debug "catalog cache miss" :ns log-ns)
      (map |{:id ($ :id) :sku ($ :sku) :name ($ :name)
             :description ($ :description)
             :price-cents ($ :price-cents) :stock ($ :stock)}
           (repo/active)))))

(defn forget-listing!
  ``Drop the cached listing. Called by whoever moved stock behind the
  storefront's back — the restock in orders/service, and nothing else.``
  []
  (cache/forget listing-key))

(defn by-id
  "One product, whatever its status — the row behind a product page."
  [id]
  (repo/find-by-id id))

(defn on-sale
  ``One product a visitor is allowed to *buy*, or nil. An archived
  product is nil here rather than a row with a flag on it, so no caller
  can forget to look at `:status`.``
  [id]
  (when-let [product (repo/find-by-id id)]
    (when (= "active" (product :status)) product)))

(defn page
  ``One page of the catalog plus the total, which is what a paged
  response needs and a listing does not.``
  [paging]
  {:rows (repo/page-active paging)
   :total (repo/count-active)})

(defn ensure-product!
  ``Put a product on sale, or leave the one that is there alone.
  Returns `[:created row]` or `[:kept row]`.

  The seed's idempotence lives here rather than in the seed, because "a
  product that exists is left alone" is a rule about a catalog — and
  `void shop seed` being safe to re-run is what lets a container run it
  at start-up.``
  [spec]
  (if-let [existing (repo/find-by-sku (spec :sku))]
    [:kept existing]
    [:created (repo/create! spec)]))
