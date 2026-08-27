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
  (spit (string dir "/notes.txt") "not a migration")

  (assert (= 3 (length (migrate/files dir))) "only migration files are picked up")
  (assert (deep= @["20260101" "20260102" "20260103"]
                 (map |($ :version) (migrate/files dir)))
          "ordered by version")

  # -- status before anything ran ----------------------------------------
  (def before (migrate/status dir))
  (assert (= 3 (length before)) "every migration shows up")
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

  (assert (= 1 (length (migrate/pending dir))) "one still pending")
  (migrate/up! {:dir dir})
  (assert (= 3 (length versions)) "the rest applied")
  (assert (empty? (migrate/pending dir)) "nothing pending afterwards")
  (assert (empty? (migrate/up! {:dir dir})) "a second run is a no-op")

  # -- down --------------------------------------------------------------
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

(print "migrate-test: ok")
