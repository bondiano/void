# :void.db/load — the route says which row it is about, and the row
# is on the request before authz runs, so a :void.authz/resource reads
# it rather than querying again. Every case the middleware owns: the
# coerced id, the 404 for a malformed one (which never reaches the
# database), the 404 for a row that is not there, and the preload.
(import ../test-support/paths)
(import ../test-support/fake-driver :as fake)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/middleware :as middleware)
(import void/db :as db)
(import void/db/http :as db-http)

(log/set-level! "void.db" :error)

# -- the domain ----------------------------------------------------------

(db/defentity Order
  {:id [:int {:db/pk true}]
   :title :string}
  :db/table "orders"
  :db/rels {:things [:has-many :Thing :order-id]})

(db/defentity Thing
  {:id [:int {:db/pk true}]
   :order-id [:int {:db/fk :Order}]
   :name :string}
  :db/table "things")

# what the fake driver answers: the one order for an orders SELECT,
# its things for the preload's batched IN — and nothing when the row
# is supposed to be missing
(var present true)
(def [driver-value fake-state]
  (fake/make
    {:responder
     (fn respond [sql _]
       (when present
         (cond
           (string/find "things" sql)
           @{:rows @[@{:id 1 :order_id 7 :name "nut"}
                      @{:id 2 :order_id 7 :name "bolt"}]
             :count 2}
           (string/find "orders" sql)
           @{:rows @[@{:id 7 :title "widget"}] :count 1})))}))

(def driver-manifest
  (plugin/manifest 'test/driver
    :version "0.1.0"
    :requires {:void/db ">=0.0.1"}
    :components [(system/component :test/driver
                   :provides [:void/db-driver]
                   :start (fn start [_ _] driver-value))]))

# -- the app -------------------------------------------------------------

(defn show [req]
  (def row (req :void.db/row))
  {:status 200
   :body (string/format "%q %q" (row :id) (length (db/rel row :things)))})

(defn plain [req]
  {:status 200 :body (string ((req :void.db/row) :id))})

(def app-routes
  (router/routes {}
    (router/GET "/orders/:id" 'show
                {:name :orders/show
                 :void.db/load {:entity Order :preload [:things]}})
    (router/GET "/plain/:id" 'plain
                {:name :orders/plain
                 :void.db/load {:entity Order :param :id}})))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/db-http ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]}))

(def plugins ["void/http/init" "void/db/init" "void/db/http"
              driver-manifest app-manifest])

(def config {:env @{}
             :cli {:http {:port 0 :strict-meta true}
                    :db {:pool {:size 1} :n1-guard :strict}
                    :log {:level :error}}})

# -- the composition -----------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config config}))
(assert (report :ok) "the composition with :void.db/load validates")

(def boot (plugin/start! {:plugins plugins :profile :test :config config}))

(defer (plugin/shutdown! boot 3)

  # the chain carries the loader, and the route's meta carries the spec
  (def explained (http/explain-route "/orders/7"))
  (assert (index-of :void.db/load (explained :middleware))
          "the route's chain carries the row loader")
  (assert (deep= {:entity Order :preload [:things]}
                 (get-in explained [:meta :void.db/load]))
          "the metadata contract carries the spec")

  # and it sits exactly where the docstring says: after auth, before
  # authz — that is what lets a :void.authz/resource be (req :void.db/row)
  (def load-mw
    (find |(= :void.db/load (get-in $ [:value :name]))
          (get-in boot [:extensions :void.http/middleware :contributions])))
  (assert load-mw ":void.db/load contributes its middleware")
  (def at (get-in load-mw [:value :phase]))
  (assert (< middleware/phase/auth at middleware/phase/authz)
          (string "phase " at " is after auth and before authz"))
  (assert (> at 4500)
          "and after CSRF (4500): a forged request is refused before it can query")

  # -- the row, coerced and preloaded -----------------------------------

  (fake/clear! fake-state)
  (def shown (http/with-request {:uri "/orders/7"}))
  (assert (= 200 (shown :status)))
  (assert (string/find `7 2` (string (shown :body)))
          "the coerced row is on the request, things preloaded")
  (assert (not (empty? (fake/matching fake-state "things")))
          "the preload's batched query ran")

  (def plainly (http/with-request {:uri "/plain/7"}))
  (assert (= "7" (string (plainly :body)))
          "the same row without a preload — :param defaults to :id")

  # -- the two 404s ------------------------------------------------------

  (fake/clear! fake-state)
  (assert (= 404 ((http/with-request {:uri "/orders/not-a-number"}) :status))
          "a malformed id is a 404, not a 500")
  (assert (empty? (fake/sqls fake-state))
          "and it never reached the database — the schema refused it first")

  (set present false)
  (fake/clear! fake-state)
  (assert (= 404 ((http/with-request {:uri "/orders/999999"}) :status))
          "a well-formed id with no row is a 404 too")
  (assert (not (empty? (fake/sqls fake-state)))
          "this one did reach the database — it was the row that was missing")
  (set present true)

  # -- the frozen contract row ------------------------------------------

  (def load-decl
    (find |(= :void.db/load (get-in $ [:value :key]))
          (get-in boot [:extensions :void.http/route-meta-key :contributions])))
  (assert load-decl ":void.db/load is declared through the metadata contract")
  (assert (= :void/db-http (load-decl :plugin)) "by void/db-http")
  (assert (= :replace (get-in load-decl [:value :merge])) "with the reserved merge strategy"))

(print "load-test: ok")
