### The shop, driven end to end — and the wave-3 claim that the whole
### stack is one composition rather than a pile of libraries.
###
### The suite is a function of the database, run once per engine:
### sqlite always (a temporary file, nothing to install); Postgres when
### VOID_TEST_PG names a server, which in CI it does. Everything below
### `run-suite` is engine-agnostic on purpose: if a single assertion
### needed a `case` on the dialect, the claim would be false.
###
### Requests go through test/inject (ADR-0017) — the production stack
### without a socket: routing, lifecycle stages, middleware, sessions,
### the identity, the policies, the CSRF check, schema validation,
### rendering, wire bytes.

(import ../test-support/paths)
(import ../test-support/postgres :as pg)
(import void/core/log :as log)
(import void/test :as test)
(import void/db :as db)
(import void/cache :as cache)
(import void/jobs :as jobs)
(import void/mail :as mail)
(import void/bus :as bus)
(import void/bus/db :as busdb)
(import void/bus/state :as bus-state)
(import void/obs :as obs)
(import ../main)
(import ../src/seed :as seed)
# the models, each out of the module that owns it — which is the one
# thing a suite has to know about the layout, and the reason it reads
# like an inventory of the application
(import ../src/modules/catalog/catalog.model :as catalog)
(import ../src/modules/cart/cart.model :as cart)
(import ../src/modules/customers/customers.model :as customers)
(import ../src/modules/orders/orders.model :as orders)
(import ../src/modules/audit/audit.service :as audit)

(def bus-table "void_bus")

(def sqlite-path
  (string (or (os/getenv "TMPDIR") "/tmp") "/void-shop-test-" (os/time) ".sqlite3"))

(def engines
  (filter identity
    [{:label "sqlite" :database :sqlite :config {:db-sqlite {:path sqlite-path}}}
     (when (pg/available?)
       {:label "postgres" :database :postgres
        :config {:db-postgres (pg/config)
                 :jobs-db {:table "shop_test_jobs"}
                 :bus-db {:table bus-table
                          :poll-interval 0.05
                          :forwarder {:enabled false}}}})]))

(def app-tables
  "Dropped before every pass, newest first — the suite owns the schema."
  ["audit_events" "payments" "order_items" "orders"
   "cart_items" "carts" "products" "customers"
   "auth_challenges" "auth_tokens" "schema_migrations"])

(defn- drop-tables! [names]
  (each t names
    (db/execute-sql (string "DROP TABLE IF EXISTS " t) [] {:kind :write :prepared false})))

(defn- reset-bus!
  ``Take the message log, the cursors and the outbox back to empty. A
  consumer group's cursor is *state*: left over from the last run it is
  a consumer that has already read everything this one publishes, and
  every assertion below would pass for the wrong reason.``
  []
  (drop-tables! [bus-table (string bus-table "_cursors")
                 (string bus-table "_leases") (string bus-table "_outbox")])
  (busdb/create-tables! bus-table))

(defn- text [resp] (test/text resp))

(defn- token-of
  ``This browser's CSRF token, off the `<meta>` tag every page carries
  (`security/htmx-meta` in views/layout). The token is signed over the
  cookie that identifies the browser, so it has to be read per client
  — and a page with no form on it still has one, which is why this
  reads the meta tag rather than a hidden field.``
  [client]
  (first (peg/match ~(any (+ (* `content="` (<- (to `"`)) `" name="csrf-token"`) 1))
                    (text (test/inject client {:uri "/"})))))

(defn- settle
  ``Forward whatever the outbox holds and let the consumers catch up.
  In a deployment this is the `:bus.db/forwarder` component and each
  consumer's own poll; in a test it is a call and a sleep, so that what
  is asserted is the *effect*, not the timing.``
  []
  (busdb/forward-once! (bus-state/active-backend) 100)
  (ev/sleep 0.35))

(defn run-suite [engine]
  (def label (engine :label))
  (defn note [msg] (print "  [" label "] " msg))

  (def opts
    {:plugins (main/plugins (engine :database))
     :profile :test
     :config {:env @{}
              :cli (merge {# an unpreloaded relation is an error here,
                           # not a warning: the application must not
                           # have a single one (ADR-0009)
                           :db {:n1-guard :strict
                                :migrations {:dir "db/migrations"}}
                           :cache {:prefix (string "shop-test-" label ":")}
                           # the suite hashes a handful of passwords and
                           # is not measuring scrypt
                           :auth {:scrypt {:ln 10}}
                           :crypto {:kdf {:in-thread false}}
                           # letters land in a list this suite can read
                           :mail {:transport :memory}
                           # the consumers are started by hand below,
                           # once the schema this suite writes into
                           # actually exists
                           :bus {:consume false}
                           :bus-db {:poll-interval 0.05
                                    :forwarder {:enabled false}}}
                          (engine :config))}})

  (test/with-http [c (merge opts {:only [:http/kernel :cache/store :jobs/queue
                                         :crypto/lib :auth/registry :authz/registry
                                         :obs/registry :obs/tracer
                                         # /health reports every started
                                         # component, and a composition
                                         # that has void/pressure and has
                                         # not started it is a process
                                         # that cannot answer "am I
                                         # shedding" — which is a 503
                                         :pressure/sampler
                                         :bus/broker :bus.db/schema]})]

    # -- the schema, and a shop to click on ------------------------------

    (drop-tables! app-tables)
    (jobs/clear!)
    (cache/clear!)
    (mail/clear-outbox!)

    (def applied (db/migrate-up! {:dir "db/migrations"}))
    (assert (= 7 (length applied)) "seven migrations applied")
    (reset-bus!)
    (bus/start-consumers! (bus-state/active))
    (assert (get (bus/stats) :outbox)
            "void/bus-db installed the outbox writer, which is what publish-tx! needs")

    # the metric registry is process-wide and both engine passes run in
    # one process, so what this suite can assert is its own delta
    (def orders-metric (obs/find-metric :shop/orders-placed-total))
    (def orders-before-suite (or (obs/metric-value orders-metric) 0))

    (def seeded (seed/seed!))
    (assert (= (length seed/catalog-items) (seeded :products-created)))
    (assert (= 0 (db/count orders/Order)) "no orders yet")
    (note "migrated and seeded")

    # -- the storefront, out of the cache --------------------------------

    (def home (test/inject c {:uri "/"}))
    (assert (= 200 (home :status)))
    (assert (string/find "Enamel mug" (text home)) "the catalog is on the page")
    (assert (string/find "Sold out" (text home)) "including the one nobody can buy")

    (def before (cache/stats))
    (test/inject c {:uri "/"})
    (assert (= (inc (before :hits)) ((cache/stats) :hits))
            "the second render came out of the cache")

    (def mug (db/one catalog/Product {:where [:= :sku "VOID-MUG"]}))
    (def product-page (test/inject c {:uri (string "/products/" (mug :id))}))
    (assert (string/find "Add to cart" (text product-page)))
    (assert (= 404 ((test/inject c {:uri "/products/999999"}) :status))
            "a missing product is a 404, not a 500")
    (note "catalog ok")

    # -- the cart, which belongs to a browser ----------------------------

    (defn post [uri form &opt client]
      (def browser (or client c))
      (test/inject browser
                   {:uri uri
                    # minted per request against this browser's own
                    # binding: the token is signed over the cookie, so
                    # one browser's token does not verify for another
                    :headers {"x-csrf-token" (token-of browser)}
                    :form form}))

    # The first POST from a browser holding no cookie of ours is not
    # checked, and that is the rule rather than a hole: CSRF applies to
    # a request whose credential rode on a **cookie**, not to every
    # unsafe verb (ADR-0025 §1). Nobody can forge a request on behalf
    # of a browser that is not carrying anything.
    (def added (test/inject c {:uri "/cart/items"
                               :form {:product-id (mug :id) :quantity 2}}))
    (assert (= 302 (added :status)) (text added))

    # and now it is: the cart's token lives in the session, so this
    # browser has a cookie, so the next unsafe request needs a token —
    # which the application never mentions anywhere
    (assert (= 403 ((test/inject c {:uri "/cart/items"
                                    :form {:product-id (mug :id) :quantity 1}})
                    :status))
            "a cookie-borne request without the CSRF token is refused")
    (assert (= 1 (db/count cart/Cart)) "a cart was opened for this browser")
    (assert (nil? ((db/one cart/Cart) :customer-id))
            "and it belongs to nobody yet — you can shop before you sign in")

    (def cart-page (test/inject c {:uri "/cart"}))
    (assert (string/find "Enamel mug" (text cart-page)))
    (assert (string/find "€28.00" (text cart-page)) "two mugs at €14.00")

    # the quantity control is an htmx post answered with the fragment
    (def updated
      (test/inject c {:uri (string "/cart/items/" (mug :id))
                      :headers {"hx-request" "true" "x-csrf-token" (token-of c)}
                      :form {:quantity 1}}))
    (assert (= 200 (updated :status)) (string (updated :status) " " (text updated)))
    (assert (not (string/find "<html" (text updated)))
            ":void.htmx/partial answers htmx with the bare fragment")
    (assert (string/find "€14.00" (text updated)))
    (note "cart ok")

    # -- the checkout wants an identity ----------------------------------

    (def anonymous (post "/checkout" {}))
    (assert (= 401 (anonymous :status))
            ":void.auth/access :required, and this composition answers 401 rather than redirecting (config/default.janet)")
    (assert (= 0 (db/count orders/Order)) "and nothing was written")

    (def registered
      (post "/register" {:name "Grace" :email "grace@shop.example"
                         :password "correct horse battery"}))
    (assert (= 302 (registered :status)) (text registered))
    (def grace (db/one customers/Customer {:where [:= :email "grace@shop.example"]}))
    (assert (string/has-prefix? "$" (grace :password-hash))
            "a PHC string in the column, not a password")
    (assert (= (grace :id) ((db/one cart/Cart) :customer-id))
            "and the cart that was already in hand came along")
    (note "sign-up ok")

    # -- the checkout ----------------------------------------------------

    (def stock-before (mug :stock))
    (def placed (post "/checkout" {}))
    (assert (= 302 (placed :status)) (text placed))

    (def order (db/one orders/Order {:order-by [[:id :desc]]}))
    (assert order "an order exists")
    (assert (= "placed" (order :status)))
    (assert (= 1400 (order :total-cents)) "one mug, priced from the products table")
    (assert (= (grace :id) (order :customer-id)))
    (assert (= (dec stock-before) ((db/find catalog/Product (mug :id)) :stock))
            "the stock came off in the same transaction")
    (assert (= 0 (db/count cart/Cart)) "and the cart is gone")
    (assert (= 1 (db/count orders/Payment {:where [:= :order-id (order :id)]}))
            "with a pending payment to capture")

    (def queued (jobs/list-jobs {:queue :payments}))
    (assert (= 1 (length queued)) "the capture was enqueued by the same transaction")
    (assert (= :capture-payment ((first queued) :job)))

    (assert (empty? (audit/trail))
            "the fact is in the outbox, not yet on the bus — which is what an outbox is")
    (settle)
    (def placed-line (find |(= "order/placed" ($ :topic)) (audit/trail)))
    (assert placed-line "and after the forwarder ran it is on the trail")
    (assert (= (string "customer:" (grace :id)) (placed-line :actor)))
    (note "checkout ok")

    # -- the letter, and the capture -------------------------------------

    (assert (= 1 (length (jobs/list-jobs {:queue :mail})))
            "the receipt was queued by a bus consumer that no handler calls")
    (jobs/drain!)
    (def receipt (find |(string/find "Your order" (get-in $ [:message :subject] ""))
                       (mail/outbox)))
    (assert receipt "the receipt was sent")
    (assert (string/find "grace@shop.example" (string/join (get-in receipt [:message :recipients]) " ")))
    (assert (string/find (order :number) (string (get receipt :bytes)))
            "and it says which order")

    (def paid (db/find orders/Order (order :id)))
    (assert (= "paid" (paid :status)) "the capture ran and the order is paid")
    (assert (= "captured" ((db/one orders/Payment {:where [:= :order-id (order :id)]}) :status)))
    (settle)
    (assert (find |(= "order/paid" ($ :topic)) (audit/trail))
            "and the payment is on the trail")
    (note "payment ok")

    # -- sold out while you were deciding --------------------------------
    #
    # `catalog/reserve-stock!` is the whole of this: the stock is taken
    # by a statement whose WHERE clause cannot be raced.

    (def cap (db/one catalog/Product {:where [:= :sku "VOID-CAP"]}))
    (post "/cart/items" {:product-id (cap :id) :quantity 1})
    (db/update! catalog/Product (cap :id) {:stock 0})
    (def orders-before (db/count orders/Order))
    (def refused (post "/checkout" {}))
    (assert (= 200 (refused :status)))
    (assert (string/find "sold out" (text refused)))
    (assert (= orders-before (db/count orders/Order)) "no order was written")
    (assert (= 1 (db/count cart/Cart)) "and the cart is still there to fix")
    (settle)
    (assert (= 1 (length (filter |(= "order/placed" ($ :topic)) (audit/trail))))
            "a rolled-back checkout leaves no line claiming an order was placed")
    (note "out-of-stock ok")

    # -- a card the gateway refuses --------------------------------------
    #
    # The payments gateway declines any total ending in 13 cents,
    # deterministically, so the unhappy path is a test rather than a
    # coin flip.

    (db/update! catalog/Product (cap :id) {:stock 5})
    (post (string "/cart/items/" (cap :id)) {:quantity 0})
    (def note-book (db/one catalog/Product {:where [:= :sku "VOID-NOTE"]}))
    (def note-stock ((db/find catalog/Product (note-book :id)) :stock))
    (post "/cart/items" {:product-id (note-book :id) :quantity 1})
    (assert (= 302 ((post "/checkout" {}) :status)))
    (def declined-order (db/one orders/Order {:order-by [[:id :desc]]}))
    (assert (= 1213 (declined-order :total-cents)))
    (jobs/drain!)
    (def settled (db/find orders/Order (declined-order :id)))
    (assert (= "cancelled" (settled :status)) "a declined card cancels the order")
    (assert (= "failed" ((db/one orders/Payment {:where [:= :order-id (declined-order :id)]}) :status)))
    (assert (= note-stock ((db/find catalog/Product (note-book :id)) :stock))
            "and the stock went back — the checkout had taken it")
    (settle)
    (jobs/drain!)
    (assert (find |(string/find "could not be completed" (get-in $ [:message :subject] ""))
                  (mail/outbox))
            "the customer is told, by a consumer of :order/cancelled")
    (note "declined payment ok")

    # -- one order, three surfaces, one policy ---------------------------

    (def mallory (test/client (c :boot)))
    (test/inject mallory {:uri "/register"
                          :headers {"x-csrf-token" (token-of mallory)}
                          :form {:name "Mallory" :email "mallory@shop.example"
                                 :password "another good password"}})
    (assert (= 403 ((test/inject mallory {:uri (string "/orders/" (order :number))}) :status))
            "another customer may not read Grace's order")
    (assert (= 200 ((test/inject c {:uri (string "/orders/" (order :number))}) :status))
            "and Grace may")
    (settle)
    (assert (find |(= "authz/denied" ($ :topic)) (audit/trail))
            "the refusal reached the trail through void/authz's hook, with no middleware anywhere")
    (note "row-level authorization ok")

    # -- the desk --------------------------------------------------------
    #
    # Not a line of it was written for this application: the pages are
    # a projection of the declarations in src/modules/*/*.admin.janet,
    # and what this suite checks is that the projection is wired into
    # the same composition as everything above — the same session, the
    # same policy, the same transaction, the same trail
    # (test/admin-test.janet takes the desk itself apart).

    (assert (= 403 ((test/inject c {:uri "/admin/orders"}) :status))
            "a customer is not staff, and the gate is a policy the shop already had")

    (def desk (test/client (c :boot)))
    (assert (= 302 ((test/inject desk {:uri "/sign-in"
                                       :headers {"x-csrf-token" (token-of desk)}
                                       :form {:email (seed/staff :email)
                                              :password (seed/staff :password)}})
                    :status))
            "the seeded staff account signs in")
    (def desk-page (test/inject desk {:uri "/admin/orders"}))
    (assert (= 200 (desk-page :status)) "and the desk is open to it — one role, one policy")
    (assert (string/find (order :number) (text desk-page)))

    # the one write the desk does, through the action the orders module
    # declared — which calls the same `ship!` the shop has had since
    # wave 2, inside the transaction the bulk route declares
    (def shipped
      (test/inject desk {:method :post
                         :uri "/admin/orders/-/bulk/ship"
                         :headers {"x-csrf-token" (token-of desk)}
                         :form {:ids (string (order :id))}}))
    (assert (< (shipped :status) 400) (string (shipped :status) " " (text shipped)))
    (assert (= "shipped" ((db/find orders/Order (order :id)) :status)))
    (settle)
    (jobs/drain!)
    (assert (find |(string/find "on its way" (get-in $ [:message :subject] ""))
                  (mail/outbox))
            "and the dispatch notice went out — from a consumer, not from a handler, and not from the admin")

    (def trail-page (test/inject desk {:uri "/admin/audit-events"}))
    (assert (string/find "order/placed" (text trail-page))
            "the trail is a resource of the desk, read-only")
    (assert (string/find "admin/ship" (text trail-page))
            "and the desk's own change is on it, announced rather than written (ADR-0029 §8)")
    (note "admin desk ok")

    # -- the queue's own life is on the trail too ------------------------

    (assert (find |(= "jobs/completed" ($ :topic)) (audit/trail))
            "void/bus-jobs put it there, and nothing in this application mentions it")

    # -- what the operator sees ------------------------------------------

    (def health (test/inject c {:uri "/health"}))
    (assert (= 200 (health :status)) (string (health :status) " " (text health)))

    (def metrics (test/inject c {:uri "/metrics"}))
    (assert (= 200 (metrics :status)))
    (assert (string/find "shop_orders_placed_total" (text metrics))
            "the application's own metrics are in the exposition")
    (assert (string/find "void_http_requests_total" (text metrics))
            "next to the ones void/obs-http derives from the route table")
    (assert (= (+ 2 orders-before-suite) (obs/metric-value orders-metric))
            "two orders were placed in this pass, and the counter counted both")
    (note "observability ok")

    # -- and the shop refuses to be guessed at ---------------------------

    (def guesser (test/client (c :boot)))
    (var last-status 200)
    (each _ (range 12)
      (set last-status
           ((test/inject guesser {:uri "/sign-in"
                                  :headers {"x-csrf-token" (token-of guesser)}
                                  :form {:email "grace@shop.example" :password "wrong"}})
            :status)))
    (assert (= 429 last-status)
            "the rate limit on the sign-in form is one metadata key (:void.security/rate)")
    (note "rate limit ok")))

# -- run it once per engine ----------------------------------------------

# the suite provokes a declined payment and a duplicate-key redelivery
# on purpose, so the sinks go quiet the way the blog suites' do
(log/set-sinks! [(fn [_])])

(each engine engines
  (print "shop shop-test: " (engine :label))
  (run-suite engine))

(log/set-sinks! nil)
(os/rm sqlite-path)

(unless (pg/available?)
  (printf "shop shop-test: SKIPPED the Postgres pass (set %s to a conninfo or a postgres:// url)"
          pg/env-var))
(printf "shop shop-test ok (%s)"
        (string/join (map |($ :label) engines) ", "))
