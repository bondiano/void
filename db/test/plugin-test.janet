(import ../test-support/paths)
(import ../test-support/fake-driver :as fake)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/db :as db)
(import void/db/state :as state)
(import void/db/entity :as entity)
(import void/db/pool :as pool)

(log/set-level! "void.db" :error)

# -- a driver plugin, the way void/db-sqlite will be -------------------

(var responder nil)
(def [driver-value fake-state]
  (fake/make {:responder (fn [sql params] (responder sql params))}))
(set responder (fn [_ _] @{:rows [] :count 1}))

(def driver-component
  (system/component :test/driver
    :doc "The scripted driver standing in for void/db-sqlite"
    :provides [:void/db-driver]
    :start (fn start [_ _] driver-value)))

(def driver-manifest
  (plugin/manifest 'test/driver
    :version "0.1.0"
    :requires {:void/db ">=0.0.1"}
    :components [driver-component]))

# -- an app with a transactional route ---------------------------------

(db/defentity Order
  {:id [:int {:db/pk true}]
   :title :string}
  :db/table "orders")

(defn create [req]
  (db/insert! Order {:title "widget"})
  {:status 201 :body "created"})

(defn boom [req]
  (db/insert! Order {:title "doomed"})
  (error "handler failed"))

(defn plain [req]
  (db/insert! Order {:title "no transaction"})
  {:status 200 :body "ok"})

(def app-routes
  (router/routes {}
    (router/POST "/orders" 'create {:name :orders/create :void.db/txn true})
    (router/POST "/orders/boom" 'boom {:name :orders/boom :void.db/txn true})
    (router/POST "/orders/plain" 'plain {:name :orders/plain})))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/db-http ">=0.0.1"}
    :contributes {:void.http/route-source [{:name :test/app
                                            :routes app-routes
                                            :env (router/env-ref (curenv))}]}))

(def plugins
  ["void/http/init" "void/db/init" "void/db/http"
   driver-manifest app-manifest])

(def config {:env @{} :cli {:http {:port 0 :strict-meta true}
                            :db {:pool {:size 2} :n1-guard :strict}
                            # plugin/start! wires the logger from config
                            :log {:level :error}}})

# -- phases 1-5 catch the wiring problems before anything starts --------

(def report (plugin/dry-run {:plugins plugins :profile :test :config config}))
(assert (report :ok) "dry-run validates the composition")
(assert (index-of :db/pool (report :components)) "the pool is in the graph")

# the config slice is validated before anything starts
(def [cfg-ok cfg-err]
  (protect (plugin/dry-run {:plugins plugins :profile :test
                            :config {:env @{} :cli {:db {:pool {:size 0}
                                                         :n1-guard :loud}}}})))
(assert (not cfg-ok) "a bad :db config fails the boot")
(assert (string/find "n1-guard" cfg-err) "naming the offending key")

# without a driver the pool has nothing to stand on, and the graph says so
(def [ok err]
  (protect (plugin/dry-run {:plugins ["void/db/init"] :profile :test :config config})))
(assert (not ok) "the kernel alone does not boot")
(assert (string/find "void/db-driver" err) "the missing driver interface is named")

# -- boot ---------------------------------------------------------------

(def boot (plugin/start! {:plugins plugins :profile :test :config config}))

(defer (plugin/shutdown! boot 3)

  (def p (get-in boot [:system :instances :db/pool]))
  (assert p "the :db/pool component started")
  (assert (= p (state/active-pool)) "and is what db calls reach")
  (assert (= :up ((pool/health p) :status)) "health reports the pool")
  (assert (= 2 ((pool/health p) :size)) "with the configured size")

  # the configured guard mode reached the entity layer
  (assert (= :strict (entity/guard-mode))
          "[:db :n1-guard] decides how unplanned relations are treated")

  # -- a transactional route commits ------------------------------------
  (fake/clear! fake-state)
  (def created (http/with-request {:method :post :uri "/orders"}))
  (assert (= 201 (created :status)) "the handler ran")
  (def sqls (fake/sqls fake-state))
  (assert (= "BEGIN" (first sqls)) ":void.db/txn opened a transaction")
  (assert (some |(string/has-prefix? "INSERT" $) sqls) "the insert is inside it")
  (assert (= "COMMIT" (last sqls)) "and it committed")
  (assert (= 1 (length (distinct (map |($ :conn) (fake/log fake-state)))))
          "the whole request used one connection")

  # -- a failing handler rolls back, the error still renders ------------
  (fake/clear! fake-state)
  (def failed (http/with-request {:method :post :uri "/orders/boom"}))
  (assert (= 500 (failed :status)) "the error reached the renderer")
  (def sqls2 (fake/sqls fake-state))
  (assert (= "BEGIN" (first sqls2)) "the transaction opened")
  (assert (= "ROLLBACK" (last sqls2)) "and rolled back")

  # -- a route without the key is not wrapped ---------------------------
  (fake/clear! fake-state)
  (def plainly (http/with-request {:method :post :uri "/orders/plain"}))
  (assert (= 200 (plainly :status)))
  (assert (not (some |(= "BEGIN" $) (fake/sqls fake-state)))
          "no transaction where none was asked for")

  # the connection went back to the pool after each request
  (assert (zero? ((pool/stats p) :in-use)) "no connection leaked")

  # -- explain-route shows the key like any other metadata --------------
  (def explained (http/explain-route "/orders" :post))
  (assert (= true (get-in explained [:meta :void.db/txn]))
          "the metadata contract carries :void.db/txn")
  (assert (index-of :void.db/txn (explained :middleware))
          "and the route's chain carries the transaction wrapper")

  # -- the frozen v1 contract row for :void.db/txn ----------------------
  # (the generated CONTRACTS.md row comes from this very declaration —
  # pinned here as well so the kernel's own suite fails on a change to
  # the key, its owner or its merge strategy)
  (def txn-decl
    (find |(= :void.db/txn (get-in $ [:value :key]))
          (get-in boot [:extensions :void.http/route-meta-key :contributions])))
  (assert txn-decl ":void.db/txn is declared through the metadata contract")
  (assert (= :void/db-http (txn-decl :plugin)) "by void/db-http")
  (assert (= :replace (get-in txn-decl [:value :merge])) "with the reserved merge strategy")

  # -- the CLI commands are contributed ---------------------------------
  (def commands (plugin/extension boot :void.core/cli))
  (def names (map |($ :name) commands))
  (each n [:db/migrate :db/rollback :db/status :db/erd :db/new]
    (assert (index-of n names) (string "command " n " is contributed")))
  (def erd-cmd (find |(= :db/erd ($ :name)) commands))
  (def diagram (with-dyns [:out @""] ((erd-cmd :fn)) (string (dyn :out))))
  (assert (string/find "Order {" diagram) "void db erd renders the registered entities"))

(print "plugin-test: ok")
