### void/db-mysql — MySQL as the :void/db-driver (ADR-0033,
### SPEC.md §5.10).
###
### MySQL and MariaDB over libmysqlclient, which is synchronous all
### the way down: there is no non-blocking API to park on the way
### void/db-postgres parks on libpq's. So a connection lives on a
### worker thread of its own and the ev loop talks to it over a
### channel — a query parks the calling fiber and stops nobody else.
### ADR-0033 is that decision; what each piece does:
###
###   ./libmysql  the ffi surface, opened inside each worker thread
###   ./config    [:db-mysql] -> the plain-data connection spec
###   ./types     MySQL values in and out, and the `?` placeholders
###   ./worker    the thread body: owns the MYSQL*, serves commands
###   ./conn      the loop's side of one connection
###   ./driver    the :void/db-driver contract, and the handle that
###               survives a server restart under the pool
###
### The kernel never names MySQL: void/db's pool depends on the
### *interface*, so choosing this driver is a change to the plugin
### list and the config.
###
###     (void/run! {:plugins [:void/db :void/db-mysql ...]})
###     # config/prod.janet
###     {:db-mysql {:url "mysql://app@db.internal/app?ssl-mode=required"}
###      :db {:pool {:size 20}}}
###
### With more than one driver in a composition — a project that runs
### sqlite in tests and MySQL in production — the interface is
### ambiguous and the config says which:
###
###     {:void/db-driver {:impl :db.mysql/driver}}
###
### **A pool of N is N threads.** That is the price of the arrangement
### and the one number to size deliberately: [:db :pool :size] is no
### longer just "how many sessions the server sees", it is also how
### many OS threads this process runs. The component warns when the
### pool is wide enough for that to be the thing you did not mean —
### and a wide MySQL pool was already the wrong answer, since the
### server's own `max_connections` is what runs out first.
###
### The component holds a keeper connection from :start to :stop,
### outside the pool, for the same reason void/db-sqlite and
### void/db-postgres do: a wrong host, a refused password or a missing
### client library should fail the boot, not the first request. It is
### also what answers the health check without borrowing a connection
### from the pool.
###
### TLS costs nothing here: the client library does the handshake, so
### :ssl-mode and the certificate paths are ordinary connection
### parameters and there is no TLS code in this plugin at all
### (ADR-0010 — TLS stays out of the kernel).

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/db/state :as db-state)
(import ./config :as config)
(import ./conn :as conn)
(import ./driver :as mysql)
(import ./libmysql :as libmysql)
(import ./types :as types)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.db.mysql")

# -- public surface ------------------------------------------------------

(def Config "Schema of the [:db-mysql] config slice." config/Config)
(def defaults "Defaults of the [:db-mysql] slice — empty, and config/defaults says why." config/defaults)
(def fallbacks "See config/fallbacks — what a key falls back to." config/fallbacks)
(def connection-spec "See config/spec — the slice as a connection spec." config/spec)
(def parse-url "See config/parse-url — a mysql:// URL as config keys." config/parse-url)
(def safe-url "See config/safe-url — the same URL without its password." config/safe-url)

(def make-driver "See driver/make — the :void/db-driver value." mysql/make)
(def driver-from-config "See driver/from-config." mysql/from-config)
(def isolation-levels "See driver/isolation-levels — the :isolation values." mysql/isolation-levels)

(def open-connection "See conn/open — one connection, outside the pool." conn/open)
(def close-connection "See conn/close." conn/close)
(def error-info "See conn/error-info — the structured form of a driver error." conn/error-info)
(def sqlstate "See conn/sqlstate — the SQLSTATE of a driver error, or nil." conn/sqlstate)
(def errno "See conn/errno — the MySQL error number of a driver error." conn/errno)

(def decode "See types/decode — one text value, by field descriptor." types/decode)
(def error-codes "See libmysql/error-codes — the errors worth branching on." libmysql/error-codes)

(def library-available? "See libmysql/available? — opened in THIS VM?" libmysql/available?)

# -- the current driver --------------------------------------------------

(var current
  ``The started :db.mysql/driver component's value. MySQL-only
  operations reach the driver through it, the way void/db's state
  reaches its pool — they are not part of the :void/db-driver
  contract, so the kernel cannot route them.``
  nil)

(defn- driver-now []
  (or current
      (error "void/db-mysql is not started — no :db.mysql/driver component")))

(defn connection-info
  "What a checked-out connection is: server version, thread id,
  charset, transaction state, how many times it has been replaced."
  [h]
  (((driver-now) :connection-info) h))

(defn last-insert-id
  ``The id the last INSERT on THIS fiber's connection generated.

  Only meaningful inside `db/with-conn` or `db/with-tx`, and that is
  not a limitation of the implementation — `mysql_insert_id` is per
  connection, and outside a held connection the pool is free to hand
  the next call a different one. The entity layer does not need this
  (the driver's :insert-id carries the value out of the write that
  produced it); hand-written SQL does.``
  []
  (get-in (db-state/execute-sql "SELECT LAST_INSERT_ID() AS id" [] {:kind :select})
          [:rows 0 :id]))

# -- pool width ----------------------------------------------------------

(var current-boot
  "Boot value, captured at :before-start — read for void/db's pool
  size, which here is also a thread count."
  nil)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :db-mysql/capture-boot
   :doc "Remember the boot value — void/db's pool size is this plugin's thread count"
   :fn (fn capture [boot] (set current-boot boot))})

(defn pool-size
  "The [:db :pool :size] void/db will run with (its own default is 10)."
  []
  (get-in current-boot [:config :values :db :pool :size] 10))

(def thread-warning-at
  ``Pool size past which the component says out loud that these are
  threads. Not a limit — the number is a judgement call and the
  application's, not this plugin's — but 32 OS threads is far enough
  past what a MySQL server wants from one process that a deployment
  arriving there by copying a Postgres config deserves to be told.``
  32)

# -- the driver component ------------------------------------------------

(def driver-component
  (system/component :db.mysql/driver
    :doc "The :void/db-driver void/db's pool runs on: libmysqlclient on
    a worker thread per connection (ADR-0033), with real isolation
    levels and savepoints. Holds a keeper connection so a wrong host or
    a missing client library fails the boot rather than the first
    request."
    :provides [:void/db-driver]
    :config {:key :db-mysql :schema Config}
    :start
    (fn start [_ cfg0]
      (def drv (mysql/from-config cfg0))
      # the keeper proves the configuration before anything depends on
      # it, and answers the health check without borrowing from the
      # pool. It is also the first thing that opens the client library
      # — inside its own worker thread, which is the only place this
      # plugin ever opens it
      (def keeper ((drv :connect)))
      (def info ((drv :connection-info) keeper))
      (def described (config/describe cfg0))
      (log/info "mysql driver ready" :ns log-ns
                :server (info :server)
                :client (info :client)
                :library (info :library)
                :charset (info :charset)
                ;(mapcat |[$ (get described $)] (sorted (keys described))))
      (def size (pool-size))
      (when (>= size thread-warning-at)
        (log/warn (string "[:db :pool :size] is " size ", and this driver runs "
                          "one OS thread per pooled connection (ADR-0033) — "
                          "size the pool for the server's max_connections, "
                          "which is the smaller number")
                  :ns log-ns :size size))
      (def value (merge drv {:keeper keeper :describe described}))
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
      # :threads, because on this driver that is what the pool size
      # means and a health report is where an operator looks for it
      (merge {:status (if ok :up :down)
              :threads (pool-size)}
             (drv :describe)
             ((drv :connection-info) keeper)))))

# -- CLI -----------------------------------------------------------------

(plugin/contribute! :void.core/cli
  {:name :db/mysql-info
   :read-only? true
   :doc "Show what the MySQL driver connected to: void db mysql-info"
   :needs [:db.mysql/driver]
   # :needs instances come first, then the string arguments
   :fn (fn cli-info [drv & _]
         (def info ((drv :connection-info) (drv :keeper)))
         (printf "server      %s" (info :server))
         (printf "client      %s (%s)" (info :client) (info :library))
         (printf "host        %s" (info :host))
         # the NEGOTIATED charset, which is the one that matters and is
         # not necessarily the configured one below
         (printf "charset     %s" (info :charset))
         (printf "thread id   %v" (info :thread-id))
         (printf "threads     %d (one per pooled connection)" (pool-size))
         # `each`, not `eachp`: `pairs` already yields [key value], and
         # `eachp` over that array would bind the index instead of the key
         (each [k v] (sorted-by first (pairs (drv :describe)))
           (printf "%-11s %s" (string k) (string v))))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/db-mysql
  :doc "MySQL and MariaDB as the :void/db-driver: libmysqlclient on a worker thread per connection (ADR-0033) — the blocking client API kept off the ev loop, with real isolation levels, savepoints, insert ids in place of RETURNING, and TLS because the client library does it."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/db ">=0.0.1"}
  :config-key :db-mysql
  :config-schema Config
  :config-defaults defaults
  :components [driver-component])
