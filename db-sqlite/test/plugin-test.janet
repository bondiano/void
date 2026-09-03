(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/db :as db)
(import void/db/state :as state)
(import void/db/pool :as pool)
(import void/db-sqlite/init :as sqlite)

(log/set-level! "void.db" :error)

# work in a throwaway directory; jpm test runs with cwd = db-sqlite/
(def sandbox (string (os/cwd) "/.tmp-plugin-test-" (os/time)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

# -- the composition: the kernel plus this driver, nothing else ----------

(def plugins ["void/db/init" "void/db-sqlite/init"])

(defn- config [extra]
  {:env @{}
   :cli (merge {:db {:pool {:size 2} :n1-guard :strict}
                # plugin/start! wires the logger from config; the query
                # funnel logs the statements this suite makes fail on
                # purpose, so it is quieter than the rest
                :log {:level :error :levels {"void.db.query" :fatal}}}
               extra)})

# -- the pragma list is what the config says -----------------------------

# the in-C busy handler blocks the loop, so the connection carries a
# token 100 ms cap for the open-time pragmas and the configured budget
# is waited out cooperatively in the driver (see driver/run)
(assert (deep= @[[:busy_timeout 100] [:foreign_keys true]
                 [:journal_mode :wal] [:synchronous :normal]]
               (sqlite/pragmas sqlite/defaults))
        "the declared defaults become pragmas, in order — busy capped at 100")
(assert (deep= @[[:busy_timeout 100] [:foreign_keys true]]
               (sqlite/pragmas sqlite/defaults true))
        "an in-memory database has no journal and no fsync to configure")
(assert (deep= @[[:foreign_keys false]]
               (sqlite/pragmas {:foreign-keys false}))
        "a false value is a setting, not an absent one")
(assert (deep= @[[:cache-size -20000]]
               (sqlite/pragmas {:pragmas {:cache-size -20000}}))
        "[:db-sqlite :pragmas] adds whatever else sqlite understands")

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "the kernel and the driver compose")
(assert (index-of :db.sqlite/driver (report :components)) "the driver is in the graph")
(assert (index-of :db/pool (report :components)) "and the pool stands on it")

(def [ok err]
  (protect (plugin/dry-run {:plugins plugins :profile :test
                            :config (config {:db-sqlite {:journal-mode :wall}})})))
(assert (not ok) "a bad [:db-sqlite] config fails the boot")
(assert (string/find "journal-mode" err) "naming the offending key")

(defer (rimraf sandbox)

  # -- a file database under a pool of two -------------------------------

  (def file (string sandbox "/data/app.sqlite3"))
  (def file-config (config {:db-sqlite {:path file}}))
  (def boot (plugin/start! {:plugins plugins :profile :test :config file-config}))

  (defer (plugin/shutdown! boot 3)
    (def drv (get-in boot [:system :instances :db.sqlite/driver]))
    (assert drv "the driver component started")
    (assert (= :sqlite (drv :dialect)) "and speaks the sqlite dialect")
    (assert (not (drv :memory)) "a configured path is a file")
    (assert (= file (sqlite/file-of (drv :keeper)))
            "and sqlite agrees about which file it is")
    (assert (= :directory (os/stat (string sandbox "/data") :mode))
            "its directory was created rather than demanded")
    (assert (drv :returning)
            "RETURNING is detected from the library version, not assumed")

    (def health ((get-in boot [:system :components :db.sqlite/driver :health]) drv))
    (assert (= :up (health :status)) "health pings the keeper connection")
    (assert (= file (health :path)) "and reports the configured path")

    (def p (state/active-pool))
    (assert (= :sqlite ((pool/driver-of p) :name)) "the pool runs on it")
    (assert (= "wal" (db/value ["PRAGMA journal_mode" []]))
            "the journal mode from the config reached the connection")

    # -- migrations ------------------------------------------------------

    (def migrations (string sandbox "/migrations"))
    (os/mkdir migrations)
    # an array of statements, not one string with semicolons: sqlite
    # compiles every statement of a multi-statement string before it
    # runs any of them, so DDL and its dependants must be separate
    (spit (string migrations "/20260101_create_users.janet")
          ``(defn up []
              ["CREATE TABLE users (id integer primary key,
                                    email text not null unique,
                                    role text not null default 'member',
                                    note text,
                                    lock_version integer not null default 0)"
               "CREATE TABLE posts (id integer primary key,
                                    user_id integer not null references users(id),
                                    title text not null)"
               "CREATE INDEX posts_user ON posts (user_id)"])
            (defn down [] ["DROP TABLE posts" "DROP TABLE users"])``)

    (def opts {:dir migrations :table "schema_migrations"})
    (assert (= 1 (length (db/migrate-up! opts))) "the migration applied")
    (assert (empty? (db/migrate-up! opts)) "and is not applied twice")
    (def status (db/migration-status migrations "schema_migrations"))
    (assert (get-in status [0 :applied]) "status reads it back from the database")

    # -- entities --------------------------------------------------------

    (db/defentity User
      {:id [:int {:db/pk true}]
       :email [:string {:format :email :db/unique true}]
       :role [:optional :string]
       :note [:optional :string]
       :lock-version [:optional [:int {:db/version true}]]}
      :db/table "users"
      :db/rels {:posts [:has-many :Post :user-id]})

    (db/defentity Post
      {:id [:int {:db/pk true}]
       :user-id [:int {:db/fk :User}]
       :title :string}
      :db/table "posts"
      :db/rels {:user [:belongs-to :User :user-id]})

    (def u (db/insert! User {:email "a@b.c"}))
    (assert (= 1 (u :id)) "the generated key came back")
    (assert (= "member" (u :role))
            "and the column default with it — RETURNING hands back the stored row")
    (assert (nil? (u :note)) "a NULL column reads as nil")

    (db/insert! User {:email "d@e.f" :role "admin"})
    (assert (= 2 (db/count User)) "both rows are there")
    (assert (= 1 (db/count User {:where {:role "admin"}})) "counted with a filter")
    (assert (db/exists? User {:where [:like :email "a@%"]}))

    (assert (= "a@b.c" ((db/find! User 1) :email)) "find by primary key")
    (assert (nil? (db/find User 99)) "and nil for a row that is not there")

    # -- partial update through the AR sugar -----------------------------
    (def loaded (db/find! User 1))
    (put loaded :note "hello")
    (assert (deep= @{:note "hello"} (db/changes loaded)) "only the touched column is dirty")
    (db/save! loaded)
    (assert (not (db/dirty? loaded)) "the snapshot moved with the write")
    (assert (= "hello" ((db/find! User 1) :note)) "and the row really changed")
    (assert (= 1 ((db/find! User 1) :lock-version))
            ":db/version was bumped by the guarded UPDATE")

    (assert (= 1 (db/update! User 2 {:role "owner"})) "update! reports the affected count")
    (assert (zero? (db/update! User 99 {:role "ghost"})) "nothing matched, nothing written")

    # -- relations are preloaded in one batched IN -----------------------
    (db/insert-all! Post [{:user-id 1 :title "first"}
                          {:user-id 1 :title "second"}
                          {:user-id 2 :title "third"}])
    (def users (db/query User {:order-by [[:id :asc]] :preload [:posts]}))
    (assert (= 2 (length (db/rel (first users) :posts))) "the has-many loaded")
    (assert (= 1 (length (db/rel (last users) :posts))))
    (assert (not (first (protect (db/rel (db/find! User 1) :posts))))
            "and an unplanned relation is an error under :strict")

    # -- transactions ----------------------------------------------------
    (db/with-tx
      (db/insert! User {:email "tx@commit"}))
    (assert (db/exists? User {:where {:email "tx@commit"}}) "a committed transaction")

    (def [tok] (protect (db/with-tx
                          (db/insert! User {:email "tx@rollback"})
                          (error "handler failed"))))
    (assert (not tok) "the error propagated out of with-tx")
    (assert (not (db/exists? User {:where {:email "tx@rollback"}}))
            "and took the write back")

    (assert (nil? (db/with-tx
                    (db/insert! User {:email "tx@explicit"})
                    (db/rollback!)))
            "db/rollback! ends the scope quietly")
    (assert (not (db/exists? User {:where {:email "tx@explicit"}})))

    # nested scopes are savepoints, not a flattened transaction
    (db/with-tx
      (db/insert! User {:email "outer@tx"})
      (protect (db/with-tx
                 (db/insert! User {:email "inner@tx"})
                 (error "inner failed"))))
    (assert (db/exists? User {:where {:email "outer@tx"}}) "the outer write survived")
    (assert (not (db/exists? User {:where {:email "inner@tx"}}))
            "the savepoint took the inner one back")

    # an isolation level the driver has a BEGIN for
    (db/with-tx {:isolation :serializable}
      (db/insert! User {:email "iso@tx"}))
    (assert (db/exists? User {:where {:email "iso@tx"}}))

    # -- the pool's second connection is the same database ---------------
    (def e1 (pool/checkout p))
    (def e2 (pool/checkout p))
    (defer (do (pool/checkin p e1) (pool/checkin p e2))
      (assert (= 2 ((pool/stats p) :created)) "two physical connections")
      (assert (not= (e1 :conn) (e2 :conn)) "and they really are two")
      (def d (pool/driver-of p))
      (def seen ((d :execute) (e2 :conn) "SELECT count(*) AS n FROM users" []
                              {:kind :select}))
      (assert (pos? (get-in seen [:rows 0 :n]))
              "the second one sees the migrated schema and the rows"))

    # -- foreign keys are enforced, unlike sqlite's own default ----------
    (assert (not (first (protect (db/insert! Post {:user-id 999 :title "orphan"}))))
            "[:db-sqlite :foreign-keys] is on, so the reference is checked")

    # -- rolling back ----------------------------------------------------
    (assert (= 1 (length (db/migrate-down! opts))) "the migration rolled back")
    (assert (not (first (protect (db/count User)))) "the table is gone with it")

    (db/execute-sql "CREATE TABLE notes (id integer primary key, body text)" []
                    {:kind :write})
    (assert (= 1 (db/execute! {:insert "notes" :values {:body "written once"}}))
            "one row written"))

  (assert (os/stat file) "the database file outlived the process it was made in")

  (def boot2 (plugin/start! {:plugins plugins :profile :test :config file-config}))
  (defer (plugin/shutdown! boot2 3)
    (assert (= "written once" (db/value {:select [:body] :from "notes"}))
            "a second boot reads what the first one wrote"))

  # -- an in-memory database is served as the one connection it is -------

  (def mem-config (config {:db {:pool {:size 1} :n1-guard :strict}
                           :db-sqlite {:path ":memory:"}}))
  (def memboot (plugin/start! {:plugins plugins :profile :test :config mem-config}))
  (defer (plugin/shutdown! memboot 3)
    (def drv (get-in memboot [:system :instances :db.sqlite/driver]))
    (assert (drv :memory) "the path says memory")
    (assert (= "" (sqlite/file-of (drv :keeper))) "and sqlite kept it off disk")

    (db/execute-sql "CREATE TABLE t (n int)" [] {:kind :write})
    (db/execute! {:insert "t" :values {:n 7}})
    # each statement checks a connection out and hands it back: the
    # schema surviving that round trip is the whole point of :shared
    (assert (= 7 (db/value {:select [:n] :from "t"}))
            "a later checkout is still the same database")
    (assert (= (get-in memboot [:system :instances :db.sqlite/driver :keeper])
               ((pool/checkout (state/active-pool)) :conn))
            "because the pool is handed the keeper itself"))

  # a wider pool over an in-memory database would be several different
  # empty databases, so it is refused at boot rather than half-working
  (def [mok merr]
    (protect (plugin/start! {:plugins plugins :profile :test
                             :config (config {:db-sqlite {:path ":memory:"}})})))
  (assert (not mok) "in-memory plus a pool of two does not boot")
  (assert (string/find "single-connection" merr) "and says why")
  (assert (string/find "[:db :pool :size]" merr) "and what to set"))

(print "plugin-test: ok")
