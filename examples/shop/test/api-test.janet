### The JSON half of the shop, and the claim behind it: an API in void
### is not a second application. Same process, same database, same
### policies, same audit trail — what differs is the metadata on the
### routes, and void/rest and void/openapi read it.
###
### One engine here, not two: nothing in this file touches SQL that
### ./shop-test has not already run on both. What it does touch is the
### part of the request path the storefront never uses — bearer
### tokens, query-schema coercion, problem+json, response caching and
### the OpenAPI projection.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/test :as test)
(import void/db :as db)
(import void/auth :as auth)
(import spork/json)
(import ../main)
(import ../src/seed :as seed)
(import ../src/shared/values :as values)
(import ../src/modules/catalog/catalog.model :as catalog)
(import ../src/modules/customers/customers.model :as customers)
(import ../src/modules/orders/orders.model :as orders)

(def sqlite-path
  (string (or (os/getenv "TMPDIR") "/tmp") "/void-shop-api-" (os/time) ".sqlite3"))

(def app-tables
  ["audit_events" "payments" "order_items" "orders"
   "cart_items" "carts" "products" "customers"
   "auth_challenges" "auth_tokens" "schema_migrations"])

(defn- drop-tables! []
  (each t app-tables
    (db/execute-sql (string "DROP TABLE IF EXISTS " t) [] {:kind :write :prepared false})))

(defn- body [resp] (json/decode (resp :body) true))

(def opts
  {:plugins (main/plugins :sqlite)
   :profile :test
   :config {:env @{}
            :cli {:db {:n1-guard :strict :migrations {:dir "db/migrations"}}
                  :db-sqlite {:path sqlite-path}
                  :cache {:prefix "shop-api-test:"}
                  :auth {:scrypt {:ln 10}}
                  :crypto {:kdf {:in-thread false}}
                  :mail {:transport :memory}
                  :bus {:consume false}
                  :bus-db {:forwarder {:enabled false}}
                  # the document is served in :dev by default, and this
                  # suite runs in :test — the flag is what a CI job
                  # that exports the spec would set too
                  :openapi {:enabled true}}}})

(log/set-sinks! [(fn [_])])

(test/with-http [c (merge opts {:only [:http/kernel :cache/store :jobs/queue
                                       :crypto/lib :auth/registry :authz/registry
                                       :obs/registry :obs/tracer :pressure/sampler
                                       :bus/broker :bus.db/schema]})]
  (drop-tables!)
  (db/migrate-up! {:dir "db/migrations"})
  (seed/seed!)

  # an order to look at, written directly: the checkout is ./shop-test's
  # subject, and a fixture that goes through eight HTTP requests to set
  # up an API assertion is a fixture that fails for the wrong reasons
  (def ada (db/one customers/Customer {:where [:= :email (seed/customer :email)]}))
  (def mug (db/one catalog/Product {:where [:= :sku "VOID-MUG"]}))
  (def order (db/insert! orders/Order {:number "SH-TEST01"
                                       :customer-id (ada :id)
                                       :email (ada :email)
                                       :status "paid"
                                       :total-cents 2800
                                       :placed-at (values/now)
                                       :paid-at (values/now)}))
  (db/insert! orders/OrderItem {:order-id (order :id)
                                :product-id (mug :id)
                                :sku (mug :sku)
                                :name (mug :name)
                                :unit-price-cents (mug :price-cents)
                                :quantity 2})

  # -- the catalog, which anybody may read --------------------------------

  (def listed (test/inject c {:uri "/api/products"}))
  (assert (= 200 (listed :status)))
  (assert (string/find "application/json" (get-in listed [:headers "content-type"])))
  (def page (body listed))
  (assert (= 8 (length (page :data))) "every active product, sold out ones included")
  (assert (= 8 (get-in page [:page :total])))
  (assert (= "VOID-BAG" (get-in page [:data 0 :sku])) "sorted by sku by default")
  (assert (= 2200 (get-in page [:data 0 :price :cents]))
          "money is an integer number of cents, all the way to the client")

  (def paged (body (test/inject c {:uri "/api/products?per-page=2&page=2"})))
  (assert (= 2 (length (paged :data))))
  (assert (= 4 (get-in paged [:page :pages])) "void/rest's paging convention, one merge into the query schema")

  (def sorted-desc (body (test/inject c {:uri "/api/products?sort=-price-cents"})))
  (assert (= "VOID-POSTER" (get-in sorted-desc [:data 0 :sku])) "?sort=-field is descending")

  (def bad (test/inject c {:uri "/api/products?per-page=5000"}))
  (assert (= 400 (bad :status)) "the query schema is enforced before the handler")
  (assert (string/find "problem+json" (get-in bad [:headers "content-type"]))
          "and a failure is RFC 7807, not a rendered page")

  (def shown (test/inject c {:uri (string "/api/products/" (mug :id))}))
  (assert (= 200 (shown :status)))
  (assert (= "VOID-MUG" ((body shown) :sku)))
  (assert (= 404 ((test/inject c {:uri "/api/products/999999"}) :status)))

  # the index carries :void.cache/response, so the second identical
  # request never reaches a handler — which is only sound because the
  # answer is the same for everybody (the storefront's HTML is not, and
  # caches its query instead)
  (defn- price-of [payload sku]
    (get-in (find |(= sku ($ :sku)) (payload :data)) [:price :cents]))

  # A response that sets a cookie is never stored in a shared cache —
  # void/cache-http refuses, and it is right to: the entry would be
  # served to the next visitor with somebody else's cookie in it. The
  # first response to a browser carries the CSRF cookie void/security
  # sets, so the entry appears on the second request and is served from
  # the third.
  (assert (= "MISS" (get-in (test/inject c {:uri "/api/products"}) [:headers "x-cache"])))
  (def stored (test/inject c {:uri "/api/products"}))
  (assert (nil? (get-in stored [:headers "set-cookie"]))
          "the browser now holds the cookie, so this response sets none")

  (db/update! catalog/Product (mug :id) {:price-cents 9999})
  (def cached (test/inject c {:uri "/api/products"}))
  (assert (= "HIT" (get-in cached [:headers "x-cache"])))
  (assert (= 1400 (price-of (body cached) "VOID-MUG"))
          "the cached response still says the old price — which is what a 30-second TTL means")
  (db/update! catalog/Product (mug :id) {:price-cents 1400})
  (print "  api: catalog ok")

  # -- the orders, which need a token -------------------------------------

  (def anonymous (test/inject c {:uri "/api/orders"}))
  (assert (= 401 (anonymous :status)) "no credential, no orders")

  (def minted (auth/issue-token (auth/token-store) (string "customer:" (ada :id))
                                {:name "api-test"}))
  (defn as-ada [uri]
    (test/inject c {:uri uri
                    :headers {"authorization" (string "Bearer " (minted :token))}}))

  (def mine (as-ada "/api/orders"))
  (assert (= 200 (mine :status)) (string (mine :status) " " (test/text mine)))
  (def listed-orders (get (body mine) :data))
  (assert (= 1 (length listed-orders)))
  (assert (= "SH-TEST01" (get-in listed-orders [0 :number])))
  (assert (= 2800 (get-in listed-orders [0 :total :cents])))
  (assert (= 2 (get-in listed-orders [0 :items 0 :quantity]))
          "with the lines it was bought with")

  (assert (= 200 ((as-ada "/api/orders/SH-TEST01") :status)))
  # a number that does not exist and one that is not yours look the
  # same from outside, and that is the policy doing its job: the
  # resource loader finds no row, so no policy can say it is yours
  (assert (= 403 ((as-ada "/api/orders/SH-NOPE") :status)))
  (print "  api: bearer ok")

  # -- a session cookie is not an API credential --------------------------

  (def browser (test/client (c :boot)))
  (def token-of
    (first (peg/match ~(any (+ (* `content="` (<- (to `"`)) `" name="csrf-token"`) 1))
                      (test/text (test/inject browser {:uri "/"})))))
  (assert (= 302 ((test/inject browser {:uri "/sign-in"
                                        :headers {"x-csrf-token" token-of}
                                        :form {:email (seed/customer :email)
                                               :password (seed/customer :password)}})
                  :status))
          "the browser is signed in as the same customer")
  (assert (= 200 ((test/inject browser {:uri "/orders"}) :status))
          "and the HTML page is theirs")
  (assert (= 401 ((test/inject browser {:uri "/api/orders"}) :status))
          ":void.auth/strategies [:bearer] — a cookie cannot act as an API credential, which is also why these routes need no CSRF token")
  (print "  api: strategies ok")

  # -- somebody else's order ----------------------------------------------

  (def desk (db/one customers/Customer {:where [:= :email (seed/staff :email)]}))
  (def desk-token (auth/issue-token (auth/token-store) (string "customer:" (desk :id))
                                    {:name "desk"}))
  (def peeked
    (test/inject c {:uri "/api/orders/SH-TEST01"
                    :headers {"authorization" (string "Bearer " (desk-token :token))}}))
  (assert (= 200 (peeked :status))
          "the desk holds the staff role, and :orders/own says the desk may look")

  (def mallory (db/insert! customers/Customer
                           {:name "Mallory" :email "mallory@shop.example"
                            :role "customer" :created-at (values/now)}))
  (def mallory-token (auth/issue-token (auth/token-store) (string "customer:" (mallory :id))
                                       {:name "mallory"}))
  (def refused
    (test/inject c {:uri "/api/orders/SH-TEST01"
                    :headers {"authorization" (string "Bearer " (mallory-token :token))}}))
  (assert (= 403 (refused :status))
          "and another customer may not — the same policy the HTML page and the desk are enforced with")
  (assert (string/find "problem+json" (get-in refused [:headers "content-type"]))
          "as problem+json, because this route is schema'd")
  (print "  api: policy ok")

  # -- the document is a projection, not a file ---------------------------

  # `document`, not `doc`: janet's `doc` is a macro, and shadowing it
  # with a def makes `(doc :status)` a documentation lookup
  (def document (test/inject c {:uri "/openapi.json"}))
  (assert (= 200 (document :status)))
  (def spec (body document))
  (assert (= "void shop" (get-in spec [:info :title])) "from [:openapi :info]")
  (assert (get-in spec [:paths (keyword "/api/products") :get])
          "the catalog endpoint is in the document")
  (assert (get-in spec [:components :schemas :ProductList])
          "with the schemas the routes named, chased through the registry")
  (assert (get-in spec [:components :schemas :Money])
          "including the ones those schemas reference")
  # the document is a projection of the whole route table, so the
  # storefront's HTML routes are in it too, described as far as their
  # metadata allows — and the admin desk is not, because its group
  # carries :void.openapi/hidden
  (assert (get-in spec [:paths (keyword "/cart")]))
  (assert (nil? (get-in spec [:paths (keyword "/admin/orders")]))
          ":void.openapi/hidden on the group takes the desk out of the document")
  (print "  api: openapi ok"))

(log/set-sinks! nil)
(os/rm sqlite-path)
(print "shop api-test ok (sqlite)")
