### void/db — the database kernel plugin (SPEC.md §5.9, ADR-0009,
### ROADMAP 2.1).
###
### The kernel owns no driver: it declares the :void/db-driver
### interface and starts a pool over whichever component provides it
### (void/db-sqlite, void/db-postgres — the config picks, the code
### never names one). What lives here is everything above the wire:
### SQL as data (./builder), the fiber-aware pool (./pool), dyn-scoped
### connections and transactions (./state), the Data Mapper entity
### layer with its thin AR sugar and N+1 guard (./entity), migrations
### (./migrate) and the ERD projection (./erd) — all re-exported from
### this module, so applications import `void/db` alone.
###
### Route-level transactions (:void.db/txn) live in the companion
### plugin void/db-http (./http), which is the only piece that needs
### void/http to be active.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./builder :as builder)
(import ./driver :as driver)
(import ./pool :as pool)
(import ./state :as state)
(import ./entity :as entity)
(import ./migrate :as migrate)
(import ./erd :as erd)

# -- the driver interface ------------------------------------------------

(plugin/contribute! :void.core/interface
  {:name :void/db-driver
   :doc "A database driver: {:dialect :connect :close :execute} plus the optional :prepare/:execute-prepared, :begin/:commit/:rollback, savepoint and :ping keys (see void/db/driver). A driver component declares :provides [:void/db-driver]; [:db :driver] picks between several."
   :methods {:connect "(fn [] conn)"
             :close "(fn [conn])"
             :execute "(fn [conn sql params opts] {:rows [...] :count n})"}})

# -- public surface (re-exports) -----------------------------------------

(def null "See builder/null — the explicit SQL NULL." builder/null)
(def format "See builder/format — statement map -> [sql params]." builder/format)
(def snake "See builder/snake — identifier spelling." builder/snake)
(def register-dialect! "See builder/register-dialect!." builder/register-dialect!)

(def normalize-driver "See driver/normalize." driver/normalize)
(def driver-result "See driver/result — sugar for driver authors." driver/result)

(def pool-stats "See pool/stats — checkouts, waits, query timing." pool/stats)

(def conn-dyn "See state/conn-dyn." state/conn-dyn)
(def pool-dyn "See state/pool-dyn." state/pool-dyn)
(def active-pool "See state/active-pool." state/active-pool)
(def current-driver "See state/driver — the driver behind the pool." state/driver)
(def execute-sql "See state/execute-sql — raw SQL with parameters." state/execute-sql)
(def run "See state/run — execute a statement map, full driver result." state/run)
(def query-sql "See state/query — statement map (or [sql params]) -> rows." state/query)
(def one-row "See state/one — the first row of a statement, or nil." state/one)
(def value "See state/value — the single column of the first row." state/value)
(def execute! "See state/execute! — a write, returning the affected count." state/execute!)
(def in-transaction? "See state/in-transaction?." state/in-transaction?)
(def rollback! "See state/rollback! — abort the innermost with-tx." state/rollback!)
(def with-conn* "See state/with-conn*." state/with-conn*)
(defmacro with-conn
  "See state/with-conn — run the body on one pooled connection."
  [& body]
  ~(,state/with-conn* (fn with-conn-body [_] ,;body)))
(def with-tx* "See state/with-tx*." state/with-tx*)
(defmacro with-tx
  ``Run the body in a transaction (see state/with-tx): nested scopes
  become savepoints, an error rolls back and propagates.``
  [& body]
  (def [opts forms]
    (if (and (> (length body) 1) (dictionary? (first body)))
      [(first body) (drop 1 body)]
      [{} body]))
  ~(,state/with-tx* ,opts (fn with-tx-body [] ,;forms)))

(def entity-descriptor "See entity/descriptor." entity/descriptor)
(def entities "See entity/registered — names of declared entities." entity/registered)
(def entity-of "See entity/descriptor-of — the mapping behind an instance." entity/descriptor-of)
(def resolve-entity "See entity/resolve — descriptor from a name, node or descriptor." entity/resolve)
(def define-entity! "See entity/define! — the runtime half of defentity." entity/define!)
(defmacro defentity
  ``Define an entity — schema plus db-mapping in one declaration (see
  void/db/entity):

      (db/defentity User
        {:id [:int {:db/pk true}] :email :string}
        :db/table "users"
        :db/rels {:bets [:has-many :Bet :user-id]})``
  [name form & kvs]
  ~(def ,name (,entity/define! ,(keyword name) ,form [,;kvs])))
(def find "See entity/find — one entity by primary key, or nil." entity/find)
(def find! "See entity/find! — like find, but throws when missing." entity/find!)
(def query "See entity/query — entities by :where/:order-by/:preload." entity/query)
(def one "See entity/one — the first matching entity, or nil." entity/one)
(def count "See entity/count — matching rows, without building entities." entity/count)
(def exists? "See entity/exists?." entity/exists?)
(def insert! "See entity/insert!." entity/insert!)
(def insert-all! "See entity/insert-all! — one multi-row INSERT." entity/insert-all!)
(def update! "See entity/update! — patch by primary key." entity/update!)
(def delete! "See entity/delete! — by primary key." entity/delete!)
(def delete-where! "See entity/delete-where!." entity/delete-where!)
(def save! "See entity/save! — partial UPDATE of what changed." entity/save!)
(def reload "See entity/reload." entity/reload)
(def rel "See entity/rel — navigate a relation (N+1-guarded)." entity/rel)
(def preload! "See entity/preload! — batched relation load onto instances." entity/preload!)
(def preloaded? "See entity/preloaded?." entity/preloaded?)
(def changes "See entity/changes — the diff against the snapshot." entity/changes)
(def dirty? "See entity/dirty?." entity/dirty?)
(def snapshot "See entity/snapshot — the load-time column values." entity/snapshot)
(def instance? "See entity/instance?." entity/instance?)
(def with-identity-map* "See entity/with-identity-map*." entity/with-identity-map*)
(defmacro with-identity-map
  "See entity/with-identity-map — one instance per row inside the scope."
  [& body]
  ~(,entity/with-identity-map* (fn identity-map-body [] ,;body)))

(def migrate-up! "See migrate/up! — apply pending migrations." migrate/up!)
(def migrate-down! "See migrate/down! — roll the newest ones back." migrate/down!)
(def migration-status "See migrate/status." migrate/status)
(def erd-mermaid "See erd/mermaid — the ER diagram projection." erd/mermaid)

# -- config --------------------------------------------------------------

(def Config
  "Schema of the :db config slice."
  {:pool [:optional {:size [:optional [:int {:min 1}]]
                     :checkout-timeout [:optional [:number {:min 0.001}]]}]
   :n1-guard [:optional [:enum :off :warn :strict]]
   :migrations [:optional {:dir [:optional :string]
                           :table [:optional :string]}]})

(var current-profile
  "Boot profile, captured at :before-start — it decides the default
  N+1 guard mode (warn while developing, off in :prod)."
  nil)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :db/capture-profile
   :doc "Remember the boot profile for the N+1 guard default"
   :fn (fn capture [boot] (set current-profile (boot :profile)))})

(defn- guard-default [cfg]
  (or (get cfg :n1-guard)
      (if (= :prod current-profile) :off :warn)))

(defn migration-opts
  "Migration options from the :db config slice merged with overrides."
  [cfg &opt extra]
  (def m (get cfg :migrations {}))
  (merge @{:dir (get m :dir migrate/default-dir)
           :table (get m :table migrate/default-table)}
         (or extra {})))

# -- the pool component --------------------------------------------------

(def pool-component
  (system/component :db/pool
    :doc "The connection pool over the active :void/db-driver: lazy
    connections up to :size, fiber-parking checkout with a deadline,
    per-connection prepared-statement cache and the pool metrics
    (:waits, :wait-us, :queries) void/obs will export."
    :deps [:void/db-driver]
    :config {:key :db :schema Config}
    :start
    (fn start [deps cfg0]
      (def cfg (or cfg0 {}))
      (def drv (driver/normalize (deps :void/db-driver)))
      (def p (pool/make drv (get cfg :pool {})))
      (set state/current-pool p)
      (set entity/default-guard (guard-default cfg))
      (log/info "db pool ready" :ns "void.db"
                :driver (drv :name) :dialect (drv :dialect)
                :size (p :size) :n1-guard (guard-default cfg))
      p)
    :stop
    (fn stop [p]
      (pool/close-all! p)
      (set state/current-pool nil))
    :health (fn health [p] (pool/health p))))

# -- CLI commands --------------------------------------------------------

(defn- config-slice []
  (or (get-in plugin/current-boot [:config :values :db]) {}))

(defn- print-status [rows]
  (if (empty? rows)
    (print "no migrations")
    (each m rows
      (printf "%s  %-20s %s"
              (m :version) (m :name)
              (cond
                (get m :missing) "applied (file missing!)"
                (m :applied) "applied"
                "pending")))))

(plugin/contribute! :void.core/cli
  {:name :db/migrate
   :read-only? false
   :doc "Apply pending migrations: void db migrate [--step N] [--to VERSION]"
   :needs [:db/pool]
   :fn (fn cli-migrate [_ & args]
         (def opts (migration-opts (config-slice)))
         (var i 0)
         (while (< i (length args))
           (def a (args i))
           (case a
             "--step" (do (put opts :step (scan-number (args (inc i)))) (+= i 2))
             "--to" (do (put opts :to (args (inc i))) (+= i 2))
             (errorf "void db migrate: unknown flag %q" a)))
         (def done (migrate/up! opts))
         (if (empty? done)
           (print "nothing to migrate")
           (each m done (printf "applied %s_%s" (m :version) (m :name)))))})

(plugin/contribute! :void.core/cli
  {:name :db/rollback
   :read-only? false
   :doc "Roll the last migration back: void db rollback [--step N] [--to VERSION]"
   :needs [:db/pool]
   :fn (fn cli-rollback [_ & args]
         (def opts (migration-opts (config-slice)))
         (var i 0)
         (while (< i (length args))
           (def a (args i))
           (case a
             "--step" (do (put opts :step (scan-number (args (inc i)))) (+= i 2))
             "--to" (do (put opts :to (args (inc i))) (+= i 2))
             (errorf "void db rollback: unknown flag %q" a)))
         (def done (migrate/down! opts))
         (if (empty? done)
           (print "nothing to roll back")
           (each m done (printf "reverted %s_%s" (m :version) (m :name)))))})

(plugin/contribute! :void.core/cli
  {:name :db/status
   :read-only? true
   :doc "Show migration state: void db status"
   :needs [:db/pool]
   :fn (fn cli-status [_ & args]
         (unless (empty? args)
           (errorf "void db status takes no arguments (got %q)" (string/join args " ")))
         (def opts (migration-opts (config-slice)))
         (print-status (migrate/status (opts :dir) (opts :table))))})

(plugin/contribute! :void.core/cli
  {:name :db/new
   :read-only? false
   :doc "Scaffold a migration file: void db new NAME"
   :fn (fn cli-new [& args]
         (unless (= 1 (length args))
           (error "usage: void db new NAME"))
         (def opts (migration-opts (config-slice)))
         (print (migrate/create! (first args) (opts :dir))))})

(plugin/contribute! :void.core/cli
  {:name :db/erd
   :read-only? true
   :doc "Print a Mermaid ER diagram of the registered entities: void db erd"
   :fn (fn cli-erd [& args]
         (unless (empty? args)
           (errorf "void db erd takes no arguments (got %q)" (string/join args " ")))
         (prin (erd/mermaid)))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/db
  :doc "Database kernel: the :void/db-driver contract, a fiber-aware connection pool, SQL as data, dyn-scoped transactions, migrations and the Data Mapper entity layer with thin AR sugar (ADR-0009)."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :db
  :config-schema Config
  :config-defaults {:pool {:size 10 :checkout-timeout 5}}
  :components [pool-component])
