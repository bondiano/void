### void/db-postgres — the production :void/db-driver (SPEC.md §5.10,
### ADR-0011, ROADMAP 2.2).
###
### Postgres over libpq's non-blocking API, driven from the ev loop
### through void/fdwait: no thread pool, no blocking syscall on the
### loop, N fibers issuing N queries on N connections are N concurrent
### queries on one OS thread. What each piece does:
###
###   ./libpq     the ffi surface, opened at :start from a configured
###               path — a plugin that is merely loaded must not need
###               libpq to exist (`void routes` on a laptop, dry-run
###               in CI)
###   ./config    [:db-postgres] -> the connection string, URL included
###   ./types     Postgres text values in and out
###   ./conn      one connection: connect / send / receive, all parked
###               in fdwait, plus prepared statements, single-row
###               streaming, pipeline mode and cancellation
###   ./driver    the :void/db-driver contract, and the handle that
###               survives a server restart under the pool
###   ./listener  LISTEN/NOTIFY on a connection of its own
###
### The kernel never names Postgres: void/db's pool depends on the
### *interface*, so choosing this driver is a change to the plugin
### list and the config.
###
###     (void/run! {:plugins [:void/db :void/db-postgres ...]})
###     # config/prod.janet
###     {:db-postgres {:url "postgres://app@db.internal/app?sslmode=verify-full"
###                    :statement-timeout 15000}
###      :db {:pool {:size 20}}}
###
### With both drivers in one composition — a project that runs sqlite
### in tests and Postgres in production — the interface is ambiguous
### and the config says which:
###
###     {:void/db-driver {:impl :db.postgres/driver}}
###
### The component holds a keeper connection from :start to :stop,
### outside the pool, for the same reason void/db-sqlite does: a wrong
### host, a refused password or a missing libpq should fail the boot,
### not the first request. It is also what answers the health check
### without borrowing a connection from the pool.
###
### TLS costs nothing here: libpq does the handshake, so `sslmode` and
### the certificate paths are ordinary connection parameters and there
### is no TLS code in this plugin at all (ADR-0010 — TLS stays out of
### the kernel).

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/db/state :as db-state)
(import ./config :as config)
(import ./conn :as conn)
(import ./driver :as postgres)
(import ./libpq :as libpq)
(import ./listener :as listener)
(import ./types :as types)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.db.postgres")

# -- public surface ------------------------------------------------------

(def Config "Schema of the [:db-postgres] config slice." config/Config)
(def defaults "Defaults of the [:db-postgres] slice." config/defaults)
(def conninfo "See config/conninfo — the slice as a connection string." config/conninfo)
(def safe-conninfo "See config/safe-conninfo — the same with secrets removed." config/safe-conninfo)
(def parse-url "See config/parse-url — a postgres:// URL as libpq keywords." config/parse-url)

(def make-driver "See driver/make — the :void/db-driver value." postgres/make)
(def driver-from-config "See driver/from-config." postgres/from-config)
(def isolation-levels "See driver/isolation-levels — the :isolation values." postgres/isolation-levels)

(def open-connection "See conn/open — one connection, outside the pool." conn/open)
(def close-connection "See conn/close." conn/close)
(def result-error "See conn/result-error — the structured error of a failed result." conn/result-error)
(def sqlstate "See conn/sqlstate — the SQLSTATE of a driver error, or nil." conn/sqlstate)
(def transaction-status "See conn/transaction-status." conn/transaction-status)

(def open-listener "See listener/open — LISTEN/NOTIFY on its own connection." listener/open)
(def notify-sql "See listener/notify-sql — [sql params] for a NOTIFY." listener/notify-sql)

(def decode "See types/decode — one text value, by column OID." types/decode)
(def type-oids "See types/oids — the OIDs this driver knows by name." types/oids)

(def libpq-available? "See libpq/available? — has the library been opened?" libpq/available?)
(def libpq-version "See libpq/version — [major minor] of the loaded libpq." libpq/version)

# -- the current driver --------------------------------------------------

(var current
  ``The started :db.postgres/driver component's value. Postgres-only
  operations (`stream`, `pipeline`, `cancel!`) reach the driver
  through it, the way void/db's state reaches its pool — they are not
  part of the :void/db-driver contract, so the kernel cannot route
  them.``
  nil)

(defn- driver-now []
  (or current
      (error "void/db-postgres is not started — no :db.postgres/driver component")))

(defn- with-checkout
  ``Run (f handle) on the connection this fiber already holds, or on
  one taken from void/db's pool for the call — the same scope
  `db/with-conn` opens, so inside a transaction these run on the
  transaction's own connection.``
  [f]
  (db-state/with-conn* (fn [entry] (f (entry :conn)))))

(defn stream
  ``Run a statement in single-row mode, calling (f row) per row as it
  arrives, and return how many there were — a million-row export in a
  constant amount of memory. `f` runs while the query is still
  running, so it must not touch the database itself.

      (pg/stream "SELECT * FROM events WHERE day = $1" [day]
                 (fn [row] (write-line out row)))``
  [sql params f]
  (def drv (driver-now))
  (with-checkout (fn [h] ((drv :stream) h sql params f))))

(defn pipeline
  ``Send several statements without waiting for each answer — one
  round trip instead of N (libpq 14+). `statements` are [sql params]
  pairs; the result is one {:rows :count} each, in order.

      (pg/pipeline [["INSERT INTO hits (path) VALUES ($1)" [path]]
                    ["UPDATE counters SET n = n + 1 WHERE k = $1" [k]]])

  A failed statement aborts the rest — Postgres discards them until
  the sync point — and the error carries :index and the results
  collected before it. Not a transaction: wrap it in `db/with-tx` if
  it needs to be one.``
  [statements]
  (def drv (driver-now))
  (with-checkout (fn [h] ((drv :pipelined) h statements))))

(defn cancel!
  ``Ask the server to abort whatever `h` — a checked-out connection,
  as `db/with-conn` binds it — is running. The request travels over a
  socket of its own, so this is the one operation safe to call from a
  fiber other than the one parked on the query: a watchdog cancels,
  the query fiber wakes with the error.

  A statement_timeout (see [:db-postgres :statement-timeout]) is the
  better tool for the usual case — the server enforces it with nobody
  watching. Cancellation is a request, not a guarantee.``
  [h]
  (((driver-now) :cancel!) h))

(defn connection-info
  "What a checked-out connection is: server version, backend pid,
  transaction state, how many times it has been replaced."
  [h]
  (((driver-now) :connection-info) h))

# -- the driver component ------------------------------------------------

(def driver-component
  (system/component :db.postgres/driver
    :doc "The :void/db-driver void/db's pool runs on: async libpq over
    void/fdwait, with the prepared-statement pair, real isolation
    levels, savepoints and RETURNING. Holds a keeper connection so a
    wrong host or a missing libpq fails the boot rather than the first
    request."
    :provides [:void/db-driver]
    :config {:key :db-postgres :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (merge defaults (or cfg0 {})))
      (libpq/load! (get cfg :libpq))
      (def caps (postgres/capabilities))
      (def drv (postgres/from-config cfg))
      # the keeper proves the configuration before anything depends on
      # it, and answers the health check without borrowing from the pool
      (def keeper ((drv :connect)))
      (def info ((drv :connection-info) keeper))
      (log/info "postgres driver ready" :ns log-ns
                :conninfo (config/safe-conninfo cfg)
                :server (info :server-version)
                :libpq (caps :libpq)
                :library (caps :path)
                :pipeline (caps :pipeline)
                :prepared (not= false (get cfg :prepared)))
      (unless (caps :cancel)
        (log/debug (string "libpq is older than 17: a cancel request is sent "
                           "synchronously and briefly blocks the loop")
                   :ns log-ns :libpq (caps :libpq)))
      (def value (merge drv {:keeper keeper
                             :capabilities caps
                             :describe (config/describe cfg)}))
      (set current value)
      value)
    :stop
    (fn stop [drv]
      # the pool stops first (it depends on this component), so its own
      # connections are already closed; the keeper never was one
      (set current nil)
      (protect ((drv :close) (drv :keeper))))
    :health
    (fn health [drv]
      (def keeper (drv :keeper))
      (def [ok] (protect ((drv :ping) keeper)))
      (merge {:status (if ok :up :down)
              :libpq (get-in drv [:capabilities :libpq])
              :pipeline (get-in drv [:capabilities :pipeline])}
             (drv :describe)
             ((drv :connection-info) keeper)))))

# -- the listener component ----------------------------------------------

(var current-listener
  "The started :db.postgres/listener, for `subscribe!`."
  nil)

(defn listener-now
  "The running listener component, or an error naming what to add."
  []
  (or current-listener
      (error "void/db-postgres's listener is not started — no :db.postgres/listener component")))

(defn subscribe!
  ``Call `f` with every notification on `channel`
  ({:channel :payload :pid}). Returns `f`, which `unsubscribe!` takes
  back.

      (pg/subscribe! "cache-invalidation"
                     (fn [n] (cache/forget! (n :payload))))

  The subscription lives on the listener's own connection, not on a
  pooled one — LISTEN binds to a session, and a pooled session is
  whichever one the checkout happened to give you. The handler runs in
  the listening fiber: keep it short, and do not query the database
  from inside it (take a pooled connection in a fiber of your own).``
  [channel f]
  (listener/subscribe! (listener-now) channel f))

(defn unsubscribe!
  "Remove one handler, or all of a channel's when `f` is omitted."
  [channel &opt f]
  (listener/unsubscribe! (listener-now) channel f))

(defn notify!
  ``Send a notification through void/db's pool. Inside `db/with-tx` it
  is delivered on COMMIT and not at all on rollback, which is what
  makes it safe to announce a write with.``
  [channel &opt payload]
  (def [sql params] (listener/notify-sql channel payload))
  (db-state/execute-sql sql params {:kind :write})
  nil)

(def listener-component
  (system/component :db.postgres/listener
    :doc "LISTEN/NOTIFY on a connection of its own, outside the pool —
    a notification is delivered to the session that ran the LISTEN, and
    a pooled session is not the same one twice. One fiber parked in
    fdwait; it costs nothing until the server speaks."
    :deps [:db.postgres/driver]
    :config {:key :db-postgres :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (merge defaults (or cfg0 {})))
      (def l (listener/open (config/conninfo cfg)
                            {:connect-timeout (get cfg :connect-timeout)
                             :decode (config/decode-opts cfg)}))
      # started, but idle: the connection is opened by the listening
      # fiber on the first subscription, so an application that never
      # subscribes never pays for one
      (listener/start! l)
      (set current-listener l)
      l)
    :stop
    (fn stop [l]
      (set current-listener nil)
      (listener/stop! l))
    :health
    (fn health [l]
      (merge {:status (if (l :running) :up :down)} (listener/stats l)))))

# -- CLI -----------------------------------------------------------------

(plugin/defcontribution :void.core/cli
  {:name :db/postgres-info
   :doc "Show what the Postgres driver connected to: void db postgres-info"
   :needs [:db.postgres/driver]
   # :needs instances come first, then the string arguments
   :fn (fn cli-info [drv & _]
         (def caps (drv :capabilities))
         (def info ((drv :connection-info) (drv :keeper)))
         (printf "libpq       %s (%s)"
                 (string/join (map string (caps :libpq)) ".") (caps :path))
         (printf "server      %s" (string/join (map string (info :server-version)) "."))
         (printf "backend pid %d" (info :backend-pid))
         (printf "pipeline    %s" (if (caps :pipeline) "yes" "no (libpq 14+)"))
         (printf "cancel      %s" (if (caps :cancel) "non-blocking" "blocking (libpq 17+)"))
         (eachp [k v] (sorted-by first (pairs (drv :describe)))
           (printf "%-11s %s" (string k) v)))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/db-postgres
  :doc "Postgres as the :void/db-driver: async libpq on the ev loop through void/fdwait (ADR-0011) — no thread pool, prepared statements, pipeline mode, single-row streaming, LISTEN/NOTIFY, cancellation, and TLS because libpq does it."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/db ">=0.0.1"}
  :config-key :db-postgres
  :config-schema Config
  :config-defaults defaults
  :components [driver-component listener-component])
