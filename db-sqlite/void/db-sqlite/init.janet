### void/db-sqlite — the reference driver plugin (SPEC.md §5.10).
###
### One component, `:db.sqlite/driver`, declaring
### :provides [:void/db-driver]: void/db's pool depends on the
### *interface*, so adding this plugin to the composition is the whole
### wiring — the kernel never names sqlite, and swapping in
### void/db-postgres is a change to the plugin list.
###
###     (void/run! {:plugins [:void/db :void/db-sqlite ...]})
###     # config/dev.janet
###     {:db-sqlite {:path "db/dev.sqlite3"}
###      :db {:pool {:size 4}}}
###     # config/test.janet — in memory, and therefore one connection
###     {:db-sqlite {:path ":memory:"} :db {:pool {:size 1}}}
###
### The component owns a "keeper" connection, held from :start to
### :stop outside the pool. It earns its keep twice: a wrong path or a
### missing directory fails the boot instead of the first query, and
### for an in-memory database it *is* the connection — sqlite cannot
### reach one from a second connection at all (see ./driver), so the
### pool is handed this one over and over, and a pool wider than one
### connection is refused at boot rather than silently serving a
### different empty database per checkout.
###
### The contract itself, and what sqlite can and cannot honour of it,
### is in ./driver.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./driver :as sqlite)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.db.sqlite")

# -- public surface ------------------------------------------------------

(def make-driver "See driver/make — the :void/db-driver value." sqlite/make)
(def open-connection "See driver/open — one connection with its pragmas." sqlite/open)
(def memory-path? "See driver/memory-path? — one connection wide." sqlite/memory-path?)
(def file-of "See driver/file-of — the file behind a connection, if any." sqlite/file-of)
(def tx-modes "See driver/tx-modes — the :isolation values." sqlite/tx-modes)

(defn use-module!
  ``Hand the driver the janet-lang/sqlite3 module instead of letting it
  `require` one. There is exactly one caller: a single binary
  (docs/DEPLOY.md), which has the module linked into the executable and
  no tree to require it from.

      (def sqlite3-module (require "sqlite3"))   # at load time: this
                                                 # is what links it in

      (defn main [&]
        (db-sqlite/use-module! sqlite3-module)   # at run time
        ...)

  The two halves are in that order for the reason the whole file is
  written the way it is: `jpm build` evaluates the top level and
  marshals the result, so a `require` inside `main` would run on a
  machine that has nothing to require.``
  [m]
  (set sqlite/module m))

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:db-sqlite] config slice."
  {:path [:optional :string]
   :busy-timeout [:optional [:int {:min 0}]]
   :foreign-keys [:optional :boolean]
   :journal-mode [:optional [:enum :wal :delete :truncate :persist :memory :off]]
   :synchronous [:optional [:enum :off :normal :full :extra]]
   :tx-mode [:optional [:enum :deferred :immediate :exclusive :serializable]]
   :returning [:optional :boolean]
   :pragmas [:optional :dictionary]})

(def defaults
  ``Defaults of the [:db-sqlite] slice — a file (an in-memory
  database is one connection wide, so it cannot be the default a pool
  boots on), WAL and a busy timeout because a pool means several
  connections on one file, foreign keys on because sqlite's default
  (off, for 2005 compatibility) silently ignores every :db/fk in the
  schema.``
  {:path sqlite/default-path
   :busy-timeout 5000
   :foreign-keys true
   :journal-mode :wal
   :synchronous :normal
   :tx-mode :immediate})

(var current-boot
  ``Boot value, captured at :before-start. Two things are read off it:
  the profile (an in-memory database in :prod is worth a warning) and
  void/db's pool size, which decides whether an in-memory path can
  work at all.``
  nil)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :db-sqlite/capture-boot
   :doc "Remember the boot value — the profile and void/db's pool size"
   :fn (fn capture [boot] (set current-boot boot))})

(defn pool-size
  "The [:db :pool :size] void/db will run with (1 when unknown)."
  []
  (get-in current-boot [:config :values :db :pool :size] 1))

(defn pragmas
  ``The pragmas applied to every connection, in order: the timeout
  first (so the rest can wait for a busy database), then the declared
  ones, then whatever [:db-sqlite :pragmas] adds. An in-memory
  database has no journal and no fsync to configure, so those two are
  skipped there.``
  [cfg &opt memory?]
  (def out @[])
  (defn add [pragma key]
    (def v (get cfg key))
    (unless (nil? v) (array/push out [pragma v])))
  # the in-C busy handler blocks the whole event loop while it waits,
  # so the connection carries only a token timeout — enough for the
  # open-time pragmas below (journal_mode wants the file for a moment)
  # — and the configured budget is waited out *cooperatively* in the
  # driver (driver/run: retry + ev/sleep), where other fibers keep
  # running
  (when-let [bt (get cfg :busy-timeout)]
    (array/push out [:busy_timeout (min bt 100)]))
  (add :foreign_keys :foreign-keys)
  (unless memory?
    (add :journal_mode :journal-mode)
    (add :synchronous :synchronous))
  (eachp [name value] (get cfg :pragmas {})
    (array/push out [name value]))
  out)

# -- the driver component ------------------------------------------------

(def driver-component
  (system/component :db.sqlite/driver
    :doc "The :void/db-driver void/db's pool runs on: janet-lang/sqlite3
    with the configured pragmas, plus the keeper connection that fails
    a bad path at boot and holds an in-memory database open."
    :provides [:void/db-driver]
    :config {:key :db-sqlite :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (merge defaults (or cfg0 {})))
      (def path (cfg :path))
      (def memory? (sqlite/memory-path? path))
      (when memory?
        (def size (pool-size))
        (unless (= 1 size)
          (errorf (string "sqlite: %q is a single-connection database — set "
                          "[:db :pool :size] to 1 (it is %d), or give "
                          "[:db-sqlite :path] a file")
                  path size)))
      (unless memory? (sqlite/ensure-directory! path))
      (def prags (pragmas cfg memory?))
      (def keeper (sqlite/open path prags))
      (def ver (sqlite/version keeper))
      (def returning
        (let [v (get cfg :returning)]
          (if (nil? v) (sqlite/supports-returning? ver) v)))
      (when (and memory? (= :prod (get current-boot :profile)))
        (log/warn "sqlite runs in memory in :prod — nothing is persisted"
                  :ns log-ns :path path))
      (log/info "sqlite driver ready" :ns log-ns
                :path path :file (sqlite/file-of keeper)
                :version ver :returning returning :pragmas (length prags))
      (merge (sqlite/make {:path path
                           :pragmas prags
                           :busy-timeout (get cfg :busy-timeout 0)
                           :tx-mode (get cfg :tx-mode)
                           :returning returning
                           # in memory the keeper is the connection,
                           # and every checkout gets this same one
                           :shared (when memory? keeper)})
             {:keeper keeper
              :version ver
              :configured-path path
              :memory memory?}))
    :stop
    (fn stop [drv]
      # the pool stops first (it depends on this component), so its own
      # connections are closed by now; the keeper is never one of them
      # — the driver's :close deliberately spares it
      (protect (sqlite/close-connection (drv :keeper))))
    :health
    (fn health [drv]
      (def [ok] (protect ((drv :ping) (drv :keeper))))
      {:status (if ok :up :down)
       :path (drv :configured-path)
       :version (drv :version)
       :memory (drv :memory)
       :returning (drv :returning)})))

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/db-sqlite
  :doc "The reference :void/db-driver: janet-lang/sqlite3 behind the void/db contract — pragmas per connection, RETURNING when the library has it, and an in-memory database served as the single connection sqlite makes it."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/db ">=0.0.1"}
  :config-key :db-sqlite
  :config-schema Config
  :config-defaults defaults
  :components [driver-component])
