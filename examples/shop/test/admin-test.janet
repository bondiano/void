### The desk (ROADMAP 4.4, ADR-0029) — a back office over the entities
### this application already had, and the same declarations reachable
### by an agent under the same policies.
###
### What is under test is mostly *absence*. `src/modules/*/*.admin.janet`
### hold no handler, no template and no route, and this suite drives a
### list, a search, a filter, an in-place edit, a declared action and a
### bulk-as-a-job through pages nobody in this repository wrote for the
### shop. The pieces that did have to be written are four declarations,
### two narrowing policies, one function that turns
### `:void.admin/changed` into a bus message and one config key that
### opens the gate — and each of them is checked here for doing what it
### says.
###
### The suite is a function of the database, like every other in this
### example: sqlite always, Postgres when VOID_TEST_PG names a server.

(import ../test-support/paths)
(import ../test-support/postgres :as pg)
(import void/core/log :as log)
(import void/test :as test)
(import void/http/init :as http)
(import void/db :as db)
(import void/auth :as auth)
(import void/authz :as authz)
(import void/jobs :as jobs)
(import void/cache :as cache)
(import void/mcp :as mcp)
(import void/bus :as bus)
(import void/bus/db :as busdb)
(import void/bus/state :as bus-state)
(import spork/json)
(import ../main)
(import ../src/seed :as seed)
(import ../src/modules/catalog/catalog.model :as catalog)
(import ../src/modules/catalog/catalog.service :as catalog-service)
(import ../src/modules/customers/customers.model :as customers)
(import ../src/modules/orders/orders.model :as orders)
(import ../src/modules/orders/orders.repository :as orders-repo)
(import ../src/modules/audit/audit.service :as audit)
(import ../src/shared/values :as values)

(def bus-table "void_bus")

(def sqlite-path
  (string (or (os/getenv "TMPDIR") "/tmp") "/void-shop-admin-" (os/time) ".sqlite3"))

(def engines
  (filter identity
    [{:label "sqlite" :database :sqlite :config {:db-sqlite {:path sqlite-path}}}
     (when (pg/available?)
       {:label "postgres" :database :postgres
        :config {:db-postgres (pg/config)
                 :jobs-db {:table "shop_admin_test_jobs"}
                 :bus-db {:table bus-table
                          :poll-interval 0.05
                          :forwarder {:enabled false}}}})]))

(def app-tables
  ["audit_events" "payments" "order_items" "orders"
   "cart_items" "carts" "products" "customers"
   "auth_challenges" "auth_tokens" "schema_migrations"])

(defn- drop-tables! [names]
  (each t names
    (db/execute-sql (string "DROP TABLE IF EXISTS " t) [] {:kind :write :prepared false})))

(defn- text [resp] (test/text resp))

(defn- token-of [client]
  (first (peg/match ~(any (+ (* `content="` (<- (to `"`)) `" name="csrf-token"`) 1))
                    (text (test/inject client {:uri "/"})))))

(defn- settle []
  (busdb/forward-once! (bus-state/active-backend) 100)
  (ev/sleep 0.35))

(defn run-suite [engine]
  (def label (engine :label))
  (defn note [msg] (print "  [" label "] " msg))

  (def opts
    {:plugins (main/plugins (engine :database))
     :profile :test
     :config {:env @{}
              :cli (merge {:db {:n1-guard :strict :migrations {:dir "db/migrations"}}
                           :cache {:prefix (string "shop-admin-" label ":")}
                           :auth {:scrypt {:ln 10}}
                           :crypto {:kdf {:in-thread false}}
                           :mail {:transport :memory}
                           :bus {:consume false}
                           :bus-db {:poll-interval 0.05
                                    :forwarder {:enabled false}}}
                          (engine :config))}})

  (test/with-http [c (merge opts {:only [:http/kernel :cache/store :jobs/queue
                                         :crypto/lib :auth/registry :authz/registry
                                         :obs/registry :obs/tracer :pressure/sampler
                                         :bus/broker :bus.db/schema]})]

    (drop-tables! app-tables)
    (jobs/clear!)
    (cache/clear!)
    (db/migrate-up! {:dir "db/migrations"})
    (drop-tables! [bus-table (string bus-table "_cursors")
                   (string bus-table "_leases") (string bus-table "_outbox")])
    (busdb/create-tables! bus-table)
    (bus/start-consumers! (bus-state/active))
    (seed/seed!)

    # -- the desk is in the one route table ------------------------------
    #
    # Not a dispatcher behind one route: every action of every resource
    # is a named entry in the same table the storefront is in, which is
    # what makes `void routes`, `:void.db/txn`, CSRF, the policies and
    # the 403 renderers work here without anybody teaching them about
    # an admin (ADR-0029 §2).

    (def table (http/routes-table))
    (each name [:admin/dashboard
                :admin.products/index :admin.products/create :admin.products/cell
                :admin.products/bulk-apply
                :admin.orders/index :admin.orders/show :admin.orders/bulk-apply
                :admin.customers/edit :admin.customers/update
                :admin.audit-events/index]
      (assert (get-in table [:by-name name]) (string "no route named " name)))

    (each name [:admin.orders/create :admin.orders/update :admin.orders/destroy
                :admin.customers/destroy :admin.audit-events/update
                # a product is archived, never deleted — the row is what
                # an old invoice's line points at
                :admin.products/destroy
                :admin.payments/index :admin.order-items/index]
      (assert (nil? (get-in table [:by-name name]))
              (string "there must be no route named " name)))
    (note "every action is a route; :only and :mount false are the route table's business")

    # and none of them is in the shop's public API document: the desk is
    # kept out by [:admin :route-meta], which is the one thing an
    # application can say about routes it did not declare
    (each name [:admin/dashboard :admin.products/index]
      (assert (get-in table [:by-name name :meta :void.openapi/hidden])
              (string name " must carry :void.openapi/hidden from [:admin :route-meta]")))

    # -- shut, and opened by one line of config ---------------------------

    (assert (= 403 ((test/inject c {:uri "/admin"}) :status))
            "the gate is a policy, and a visitor does not pass it")

    (def shopper (test/client (c :boot)))
    (test/inject shopper {:uri "/register"
                          :headers {"x-csrf-token" (token-of shopper)}
                          :form {:name "Grace" :email "grace@shop.example"
                                 :password "correct horse battery"}})
    (assert (= 403 ((test/inject shopper {:uri "/admin/products"}) :status))
            "a customer signs in and is still not staff — [:admin :access] names :staff")

    (def desk (test/client (c :boot)))
    (assert (= 302 ((test/inject desk {:uri "/sign-in"
                                       :headers {"x-csrf-token" (token-of desk)}
                                       :form {:email (seed/staff :email)
                                              :password (seed/staff :password)}})
                    :status)))
    (assert (= 200 ((test/inject desk {:uri "/admin"}) :status))
            "and the seeded staff account is in — no second authentication anywhere")

    (def dashboard (test/inject desk {:uri "/admin"}))
    (assert (string/find "Paid, not yet shipped" (text dashboard))
            "the front page is what the modules contributed to it")
    (note "the gate: one policy the shop already had, one line of config")

    # -- a list, and the three affordances it declared --------------------

    (def listing (test/inject desk {:uri "/admin/products"}))
    (assert (= 200 (listing :status)))
    (assert (string/find "Enamel mug" (text listing)))
    (assert (string/find "€14.00" (text listing))
            "the money column renders through the application's own formatter")

    (def searched (test/inject desk {:uri "/admin/products?q=mug"}))
    (assert (string/find "Enamel mug" (text searched)))
    (assert (not (string/find "Notebook" (text searched)))
            ":search is a LIKE over the columns the declaration named")
    (assert (string/find "1 row" (text searched))
            "and the count counts what the page shows")

    (def filtered (test/inject desk {:uri "/admin/products?status=archived"}))
    (assert (not (string/find "Enamel mug" (text filtered)))
            ":filters narrows by an enum whose members came off the schema")
    (note "list, search, filter and a count that agrees with the page")

    # -- the one cell a desk edits all day --------------------------------

    (def mug (db/one catalog/Product {:where [:= :sku "VOID-MUG"]}))
    (def patched
      (test/inject desk {:method :patch
                         :uri (string "/admin/products/" (mug :id) "/-/cell/stock")
                         :headers {"x-csrf-token" (token-of desk)
                                   "hx-request" "true"}
                         :form {:stock "17"}}))
    (assert (< (patched :status) 400) (string "cell: " (patched :status) " " (text patched)))
    (assert (= 17 ((db/find catalog/Product (mug :id)) :stock))
            ":editable is an htmx form on the list page, and it writes one column")

    (def forged
      (test/inject desk {:method :patch
                         :uri (string "/admin/products/" (mug :id) "/-/cell/description")
                         :headers {"x-csrf-token" (token-of desk)}
                         :form {:description "not through here"}}))
    (assert (>= (forged :status) 400)
            "and only the columns :editable named — the rest is a 4xx, not a write")
    (note "in-place edit, bounded by the declaration")

    # -- the action that is a domain call ---------------------------------
    #
    # `:ship` calls orders.service/ship!, which is where "only a paid
    # order can ship" lives. So the desk cannot ship an unpaid order,
    # and the reason it cannot is not in the desk.

    (def placed (db/insert! orders/Order
                            {:number "SH-DESK1" :customer-id 1
                             :email "grace@shop.example" :status "placed"
                             :total-cents 1400 :placed-at (values/now)}))
    (def paid (db/insert! orders/Order
                          {:number "SH-DESK2" :customer-id 1
                           :email "grace@shop.example" :status "paid"
                           :total-cents 2800 :placed-at (values/now)
                           :paid-at (values/now)}))

    (def confirm (test/inject desk {:uri (string "/admin/orders/-/bulk/ship?ids="
                                                 (placed :id) "&ids=" (paid :id))}))
    (assert (= 200 (confirm :status)))
    (assert (string/find ">2</span>" (text confirm))
            "the confirmation counts the selection on the server, before anything is touched")

    (def applied
      (test/inject desk {:method :post
                         :uri "/admin/orders/-/bulk/ship"
                         :headers {"x-csrf-token" (token-of desk)}
                         :form {:ids [(string (placed :id)) (string (paid :id))]}}))
    (assert (< (applied :status) 400) (string "ship: " (applied :status)))
    (assert (= "shipped" ((db/find orders/Order (paid :id)) :status)))
    (assert (= "placed" ((db/find orders/Order (placed :id)) :status))
            "the unpaid one was left alone by the rule in orders.service, not by a check in the desk")
    (note "a declared action is a call into the module that owns the rule")

    # -- a bulk that is too big for a request -----------------------------
    #
    # `:archive` declares `:job`, so pressing the button enqueues
    # void/admin-jobs' one job and answers with a progress page. The
    # rows change when the worker runs them — here, when the suite
    # drains the queue.

    (def before-archive (db/count catalog/Product {:where [:= :status "active"]}))
    (assert (> before-archive 1))
    # `?all=1` is the whole filtered list, and the server re-runs the
    # filter rather than trusting a count or a list of identifiers from
    # the browser
    (def progress
      (test/inject desk {:method :post
                         :uri "/admin/products/-/bulk/archive?all=1"
                         :headers {"x-csrf-token" (token-of desk)}
                         :form {}}))
    (assert (= 200 (progress :status)) (string "archive: " (progress :status)))
    (assert (string/find "progress" (string/ascii-lower (text progress)))
            "the confirmation became a progress page over the job record's own state")
    (assert (= before-archive (db/count catalog/Product {:where [:= :status "active"]}))
            "and the request itself archived nothing — the rows change when a worker runs them")

    (jobs/drain!)
    (assert (zero? (db/count catalog/Product {:where [:= :status "active"]}))
            "the worker did the rows, one policy decision each, with the desk's identity")
    (note "a bulk action as a job, with the subject riding along")

    # -- the desk may not edit the account it is signed in as -------------

    (def desk-row (db/one customers/Customer {:where [:= :email (seed/staff :email)]}))
    (assert (= 403 ((test/inject desk {:uri (string "/admin/customers/" (desk-row :id) "/edit")})
                    :status))
            "one defpolicy under the name the route already carried, and no route changed")
    (def grace (db/one customers/Customer {:where [:= :email "grace@shop.example"]}))
    (def promoted
      (test/inject desk {:method :post
                         :uri (string "/admin/customers/" (grace :id))
                         :headers {"x-csrf-token" (token-of desk)}
                         :form {:name (grace :name) :email (grace :email) :role "staff"}}))
    (assert (< (promoted :status) 400) (string "promote: " (promoted :status)))
    (assert (= "staff" ((db/find customers/Customer (grace :id)) :role))
            "...and anybody else's account is the desk's to edit")
    (note "narrowing an action is a defpolicy and nothing else")

    # -- the trail this application already kept --------------------------

    (settle)
    (def trail (audit/trail {:limit 100}))
    (def admin-lines (filter |(string/has-prefix? "admin/" ($ :topic)) trail))
    (assert (not (empty? admin-lines))
            "the desk announced its changes and the wave-3.6 consumer wrote them down")
    (each topic ["admin/update" "admin/ship" "admin/archive"]
      (assert (some |(= topic ($ :topic)) admin-lines)
              (string "no " topic " on the trail")))
    (assert (some |(and (= "admin/archive" ($ :topic)) (string/find "customer:" (or ($ :actor) "")))
                  admin-lines)
            "including the ones a worker made, under the identity that pressed the button")
    (assert (some |(not (string/has-prefix? "admin/" ($ :topic))) trail)
            "next to the lines the application's own routes wrote, in one table")

    (def history (test/inject desk {:uri (string "/admin/products/" (mug :id))}))
    (assert (string/find "admin/update" (text history))
            "and the trail comes back as the history tab of a row (:void.admin/history)")
    (note "changes announced, not written — the trail is the application's")

    # -- and the same declarations, read by an agent ----------------------

    (def server (mcp/server-value))
    (def tools (map |($ :name) (server :tools)))
    (each name ["admin-products-list" "admin-orders-list" "admin-payments-list"]
      (assert (index-of name tools) (string "no tool named " name)))
    (each name ["admin-products-create" "admin-products-archive" "admin-orders-ship"]
      (assert (nil? (index-of name tools))
              (string name " writes, and writing waits for [:mcp :tools] to name it")))

    (def list-tool (first (filter |(= "admin-orders-list" ($ :name)) (server :tools))))
    (assert ((list-tool :call) @{})
            "a call is answered")
    (assert (((list-tool :call) @{}) :error?)
            "...with a refusal, because the gate does not know who is asking")

    (def listed
      (with-dyns [authz/identity-dyn
                  (auth/identity (string "customer:" (desk-row :id))
                                 {:claims {:role "staff"}})]
        (json/decode (((list-tool :call) @{:filters {:status "shipped"}}) :text) true)))
    (assert (= 1 (listed :total))
            "with an identity the desk's own filters answer, through the same query the page pages")
    (assert (= "SH-DESK2" (get-in listed [:rows 0 :number])))

    (def decl (first (filter |(= "void://admin/orders" ($ :uri)) (server :resources))))
    (assert decl "the declaration is published as a resource")
    (def declared (json/decode ((decl :read)) true))
    (assert (= "admin.orders/ship" (get-in declared [:policies :ship]))
            "and the agent is handed the very policy names the routes carry")
    (note "the same declarations, the same policies, for an agent")

    (print "  [" label "] ok")))

# the suite provokes refusals on purpose
(log/set-sinks! [(fn [_])])
(each engine engines
  (print "shop admin-test: " (engine :label))
  (run-suite engine))
(log/set-sinks! nil)
(os/rm sqlite-path)

(unless (pg/available?)
  (printf "shop admin-test: SKIPPED the Postgres pass (set %s to a conninfo or a postgres:// url)"
          pg/env-var))
(printf "shop admin-test ok (%s)"
        (string/join (map |($ :label) engines) ", "))
