(import ../test-support/paths)
(import ../test-support/fake-driver :as fake)
(import void/db/driver :as driver)
(import void/db/pool :as pool)
(import void/db/state :as state)
(import void/db/migrate :as migrate)
(import void/core/log :as log)

# migrations narrate themselves at :info — quiet for the test run
(log/set-level! "void.db" :error)

# work in a throwaway directory; jpm test runs with cwd = db/
(def root (os/cwd))
(def sandbox (string root "/.tmp-migrate-test-" (os/time)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

# the version table, simulated: the driver answers SELECTs from this
# array and INSERT/DELETE keep it up to date, so migrate/* sees the
# state a real database would give back
(def versions @[])

(defn- responder [sql params]
  (cond
    (string/find "SELECT" sql)
    @{:rows (seq [v :in (sorted versions)] {:version v}) :count (length versions)}

    (string/find `INSERT INTO "schema_migrations"` sql)
    # the builder emits columns alphabetically: applied_at, name, version
    (do (array/push versions (in params 2)) @{:rows [] :count 1})

    (string/find "DELETE FROM \"schema_migrations\"" sql)
    (do (def v (first params))
        (when-let [i (index-of v versions)] (array/remove versions i))
        @{:rows [] :count 1})

    @{:rows [] :count 0}))

(def [drv st] (fake/make {:responder responder}))
(setdyn state/pool-dyn (pool/make (driver/normalize drv) {:size 1}))

(defer (rimraf sandbox)
  (def dir (string sandbox "/migrations"))
  (os/mkdir dir)

  # -- filenames ---------------------------------------------------------
  (assert (deep= {:version "20260101120000" :name "create_users"}
                 (migrate/parse-name "20260101120000_create_users.janet"))
          "version and name come from the filename")
  (assert (nil? (migrate/parse-name "README.md")) "non-janet files are ignored")
  (assert (nil? (migrate/parse-name "nounderscore.janet")) "so are unversioned ones")

  # -- three migrations, one of them irreversible ------------------------
  (spit (string dir "/20260101_create_users.janet")
        `(defn up [] "CREATE TABLE users (id integer primary key)")
         (defn down [] "DROP TABLE users")`)
  (spit (string dir "/20260102_add_email.janet")
        `(defn up [] ["ALTER TABLE users ADD COLUMN email text"
                      "CREATE UNIQUE INDEX users_email ON users (email)"])
         (defn down [] "ALTER TABLE users DROP COLUMN email")`)
  (spit (string dir "/20260103_backfill.janet")
        `(defn up [] "UPDATE users SET email = ''")`)
  # DDL as data: the step returns a statement map and the builder
  # spells it for whatever dialect the driver speaks
  (spit (string dir "/20260104_create_orders.janet")
        `(defn up [] [{:create-table "orders"
                       :columns [[:id :serial {:primary-key true}]
                                 [:user-id :int {:null false :refs [:users :id]}]]}
                      {:create-index "orders_user_idx" :on "orders"
                       :columns [:user-id]}])
         (defn down [] {:drop-table "orders"})`)
  (spit (string dir "/notes.txt") "not a migration")

  (assert (= 4 (length (migrate/files dir))) "only migration files are picked up")
  (assert (deep= @["20260101" "20260102" "20260103" "20260104"]
                 (map |($ :version) (migrate/files dir)))
          "ordered by version")

  # -- status before anything ran ----------------------------------------
  (def before (migrate/status dir))
  (assert (= 4 (length before)) "every migration shows up")
  (assert (not (some |($ :applied) before)) "none applied yet")

  # -- up ----------------------------------------------------------------
  (fake/clear! st)
  (def applied (migrate/up! {:dir dir :step 2}))
  (assert (= 2 (length applied)) ":step limits how many run")
  (assert (deep= @["20260101" "20260102"] versions) "recorded oldest first")
  (def sqls (fake/sqls st))
  (assert (some |(string/find "CREATE TABLE users" $) sqls) "the up ran")
  (assert (some |(string/find "CREATE UNIQUE INDEX" $) sqls)
          "an array of statements runs in order")
  (assert (= 2 (length (filter |(= "BEGIN" $) sqls)))
          "each migration gets its own transaction")

  (assert (= 2 (length (migrate/pending dir))) "two still pending")
  (fake/clear! st)
  (migrate/up! {:dir dir})
  (assert (= 4 (length versions)) "the rest applied")
  (assert (empty? (migrate/pending dir)) "nothing pending afterwards")
  (assert (empty? (migrate/up! {:dir dir})) "a second run is a no-op")

  # the statement map became SQL for the driver's dialect
  (def ddl-sqls (fake/sqls st))
  (assert (some |(string/find `CREATE TABLE "orders"` $) ddl-sqls)
          "a step may return a statement map — DDL as data (void/db/builder)")
  (assert (some |(string/find `REFERENCES "users" ("id")` $) ddl-sqls)
          "compiled the way the builder compiles everything else")
  (assert (some |(string/find `CREATE INDEX "orders_user_idx"` $) ddl-sqls)
          "and a tuple of them runs in order")

  # -- down --------------------------------------------------------------
  (fake/clear! st)
  (def ddl-back (migrate/down! {:dir dir}))
  (assert (= "20260104" ((first ddl-back) :version)) "the newest applied one")
  (assert (some |(string/find `DROP TABLE "orders"` $) (fake/sqls st))
          "and its `down` is a statement map too")

  (def [ok err] (protect (migrate/down! {:dir dir})))
  (assert (not ok) "a migration without `down` refuses to roll back")
  (assert (string/find "irreversible" err) "and says so")
  (assert (= 3 (length versions)) "nothing was recorded as rolled back")

  # the same holds for a range: the newest one in it has no `down`
  (def [ok2 _] (protect (migrate/down! {:dir dir :to "20260101"})))
  (assert (not ok2) "a range rollback stops at the irreversible migration")
  (assert (= 3 (length versions)) "and records nothing")

  # drop the irreversible one from the recorded state and roll the
  # reversible pair back
  (array/remove versions (index-of "20260103" versions))
  (fake/clear! st)
  (def one-back (migrate/down! {:dir dir}))
  (assert (= 1 (length one-back)) "rollback defaults to one step")
  (assert (= "20260102" ((first one-back) :version)) "the newest applied one")
  (assert (some |(string/find "DROP COLUMN email" $) (fake/sqls st)) "its down ran")
  (assert (deep= @["20260101"] versions) "the version record is gone")

  # -- drift: a recorded version whose file disappeared ------------------
  (array/push versions "20259999")
  (def drifted (find |(= "20259999" ($ :version)) (migrate/status dir)))
  (assert (drifted :missing) "status flags a recorded migration with no file")

  # -- scaffolding -------------------------------------------------------
  (def path (migrate/create! "add orders" dir))
  (assert (os/stat path :mode) "create! writes the file")
  (def parsed (migrate/parse-name (last (string/split "/" path))))
  (assert (= "add_orders" (parsed :name)) "spaces become underscores")
  (assert (= 14 (length (parsed :version))) "the version is a UTC timestamp"))

# -- the lock a fleet's boot needs ---------------------------------------
#
# Two processes starting together both find the same migration pending.
# The pass takes an advisory lock — a lock on a name, held by the
# connection — and reads the pending list *inside* it, so the one that
# loses the race finds nothing left to do.

(defn- lock-fixture [dialect got]
  (def applied @[])
  (def [d st]
    (fake/make
      {:dialect dialect
       :responder
       (fn [sql params]
         (cond
           (string/find "GET_LOCK" sql) @{:rows [{:got got}] :count 1}
           (string/find "SELECT" sql)
           @{:rows (seq [v :in (sorted applied)] {:version v}) :count (length applied)}
           (string/find "INSERT INTO" sql)
           (do (array/push applied (in params 2)) @{:rows [] :count 1})
           @{:rows [] :count 0}))}))
  [d st applied])

(def lock-dir (string root "/.tmp-migrate-lock-" (os/time)))
(os/mkdir lock-dir)
(defer (rimraf lock-dir)
  (spit (string lock-dir "/20260101_one.janet") `(defn up [] "CREATE TABLE one (id int)")`)

  (def [pg-drv pg-st _] (lock-fixture :postgres nil))
  (with-dyns [state/pool-dyn (pool/make (driver/normalize pg-drv) {:size 1})]
    (migrate/up! {:dir lock-dir})
    (def sqls (fake/sqls pg-st))
    (def lock-at (find-index |(string/find "pg_advisory_lock" $) sqls))
    (def begin-at (find-index |(= "BEGIN" $) sqls))
    (assert lock-at "postgres takes the advisory lock")
    (assert (< lock-at begin-at) "before it reads what is pending, let alone applies it")
    (assert (some |(string/find "pg_advisory_unlock" $) sqls)
            "and gives it back at the end of the pass"))

  # MySQL's GET_LOCK waits and then *answers*: 0 is "somebody else is
  # still migrating", and reading it is the difference between waiting
  # and applying a migration twice
  (def [my-drv my-st my-applied] (lock-fixture :mysql 0))
  (with-dyns [state/pool-dyn (pool/make (driver/normalize my-drv) {:size 1})]
    (def [ok err] (protect (migrate/up! {:dir lock-dir})))
    (assert (not ok) "a lock nobody could take stops the pass")
    (assert (string/find "another process" err) "and says why")
    (assert (empty? my-applied) "with nothing applied")
    (assert (not (some |(= "BEGIN" $) (fake/sqls my-st)))
            "and no migration even started"))

  (def [my2-drv my2-st my2-applied] (lock-fixture :mysql 1))
  (with-dyns [state/pool-dyn (pool/make (driver/normalize my2-drv) {:size 1})]
    (assert (= 1 (length (migrate/up! {:dir lock-dir}))) "with the lock, the pass runs")
    (assert (some |(string/find "RELEASE_LOCK" $) (fake/sqls my2-st))
            "and releases the lock after it")))

(print "migrate-test: ok")
