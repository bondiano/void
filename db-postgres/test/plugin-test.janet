(import ../test-support/paths)
(import ../test-support/server)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/db :as db)
(import void/db/pool :as pool)
(import void/db-postgres/init :as pg)

(log/set-level! "void.db" :error)

(def plugins ["void/db/init" "void/db-postgres/init"])

(defn- config [extra]
  {:env @{}
   :cli (merge {:db {:pool {:size 2}}
                :log {:level :error :levels {"void.db.query" :fatal}}}
               extra)})

# -- phases 1-5, with no libpq and no server anywhere --------------------

# This is the property the ffi layer is arranged around: a plugin that
# is merely *loaded* — `void routes` on a laptop, the dry-run gate in
# CI — must not need a Postgres client library to exist. The bindings
# are installed at :start, not at import.

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "the kernel and this driver compose")
(assert (index-of :db.postgres/driver (report :components)) "the driver is in the graph")
(assert (index-of :db.postgres/listener (report :components)) "so is the listener")
(assert (index-of :db/pool (report :components)) "and the pool stands on the interface")

(def [ok err]
  (protect (plugin/dry-run {:plugins plugins :profile :test
                            :config (config {:db-postgres {:sslmode :verify-everything}})})))
(assert (not ok) "a bad [:db-postgres] config fails the boot")
(assert (string/find "sslmode" err) "naming the offending key")

(def [pok perr]
  (protect (plugin/dry-run {:plugins plugins :profile :test
                            :config (config {:db-postgres {:port 0}})})))
(assert (not pok) "and so does one that is out of range")
(assert (string/find "port" perr))

# -- the driver value ----------------------------------------------------

# built without connecting to anything: the contract is a dictionary,
# and every claim about what Postgres can honour is checkable here
(def drv (db/normalize-driver (pg/driver-from-config {:host "nowhere.invalid"})))
(assert (= :postgres (drv :dialect)) "the builder dialect is the one with $1 placeholders")
(assert (drv :returning) "INSERT ... RETURNING hands the stored row back")
(assert (drv :prepare) "prepared statements are real, not a fallback")
(assert (drv :execute-prepared))
(assert (drv :ping))
(each k [:begin :commit :rollback :savepoint :release-savepoint :rollback-to-savepoint]
  (assert (get drv k) (string k " is the driver's own, not generated SQL")))

(def no-prep (db/normalize-driver (pg/driver-from-config {:prepared false})))
(assert (nil? (no-prep :prepare))
        ":prepared false leaves the pair off — what a transaction-pooling pgbouncer needs")

# -- BEGIN --------------------------------------------------------------

(import void/db-postgres/driver :as postgres)

(assert (= "BEGIN" (postgres/begin-sql nil)) "no isolation asked for, none stated")
(assert (= "BEGIN ISOLATION LEVEL SERIALIZABLE" (postgres/begin-sql :serializable)))
(assert (= "BEGIN ISOLATION LEVEL READ COMMITTED" (postgres/begin-sql nil :read-committed))
        "[:db-postgres :tx-mode] is the default for a with-tx that names none")
(assert (= "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY"
           (postgres/begin-sql {:level :repeatable-read :read-only true})))
(assert (= "BEGIN ISOLATION LEVEL SERIALIZABLE DEFERRABLE"
           (postgres/begin-sql {:level :serializable :deferrable true})))

(def [iok ierr] (protect (postgres/begin-sql :snapshot)))
(assert (not iok) "an isolation level Postgres does not have is refused")
(assert (string/find "serializable" ierr) "listing the ones it does")

# -- channel names -------------------------------------------------------

(import void/db-postgres/listener :as listener)

(assert (= `"orders"` (listener/quote-channel "orders"))
        "LISTEN takes no parameters, so a channel name is a quoted identifier")
(assert (= `"say ""hi"""` (listener/quote-channel `say "hi"`))
        "and a quote in one is doubled rather than ending it")
(assert (not (first (protect (listener/quote-channel ""))))
        "a channel with no name is a mistake")

(def [nsql nparams] (listener/notify-sql "orders" "42"))
(assert (string/find "pg_notify" nsql)
        "NOTIFY goes through pg_notify so the channel is a parameter, not SQL")
(assert (deep= ["orders" "42"] nparams))
(assert (nil? (get (last (listener/notify-sql "orders")) 1))
        "and a notification without a payload sends NULL, not an empty string")

# -- with a server -------------------------------------------------------

(if-not (server/available?)
  (server/skip "db-postgres plugin")
  (do
    (def boot (plugin/start! {:plugins plugins :profile :test
                              :config (config {:db-postgres
                                               (server/config
                                                 {:application-name "void-test"
                                                  :statement-timeout 15000})})}))
    (defer (plugin/shutdown! boot 3)
      (def started (get-in boot [:system :instances :db.postgres/driver]))
      (assert started "the driver component started")
      (assert (started :keeper)
              "holding a keeper connection — a bad host fails the boot, not the first request")
      (assert (pg/libpq-available?) "and libpq was opened at :start")

      (def health (get-in (system/health (boot :system))
                          [:components :db.postgres/driver]))
      (assert (= :up (health :status)) "which is also what answers the health check")
      (assert (health :server-version) "reporting the server it reached")
      (assert (= "void-test" (health :application-name))
              "and the name it is visible under in pg_stat_activity")

      # the settings really reached the backend, rather than being
      # assembled into a string nobody read
      (assert (= "15s" (db/value ["SELECT current_setting('statement_timeout') AS v" []]))
              "[:db-postgres :statement-timeout] arrives as a startup option")

      (assert (= 1 (db/value ["SELECT 1 AS n" []])) "and the pool runs statements")
      (assert (pos? (get (pool/stats (db/active-pool)) :queries))
              "through the instrumented funnel")

      (def listener (get-in boot [:system :instances :db.postgres/listener]))
      (assert listener "the listener component started")
      (assert (not (get (listener/stats listener) :connected))
              "and holds no connection until something subscribes")

      (print "db-postgres plugin: ok (with a server)"))))

(print "db-postgres plugin: ok")
