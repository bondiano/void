(import ../test-support/paths)
(import ../test-support/mysql :as server)
(import void/jobs/conformance/backend :as conformance)
(import void/core/log :as log)
(import void/db :as vdb)
(import void/db/pool :as pool)
(import void/db/state :as db)
(import void/jobs/db :as jobsdb)

(each ns ["void.db" "void.db.query" "void.jobs" "void.jobs.db"]
  (log/set-level! ns :fatal))

# void/jobs-db on MySQL: the portable claim path (test/db-test.janet's,
# over sqlite) on the engine whose DDL differs the most — a varchar
# where the others have text, a plain unique index where they have a
# partial one, no `CREATE INDEX IF NOT EXISTS` — and whose
# unique violation arrives as errno 1062. Nothing below runs without a
# server, so the suite skips loudly rather than passing vacuously.

(if-not (server/available?)
  (do (server/skip "jobs db-mysql")
      (os/exit 0)))

# a table of this suite's own: the database is shared with
# void/db-mysql's suite, which must not find its fixtures truncated
(def tbl (string "void_jobs_my_" (os/getpid)))

(def p (pool/make (server/driver) {:size 4}))

(defn- drop-tables! []
  (each t [tbl (string tbl "_locks") (string tbl "_rates")]
    (db/execute-sql (string "DROP TABLE IF EXISTS " t) []
                    {:kind :write :prepared false})))

(defer (do (with-dyns [db/pool-dyn p] (drop-tables!))
           (pool/close-all! p))
  (with-dyns [db/pool-dyn p]
    (drop-tables!)
    (jobsdb/create-tables! tbl)

    (assert (= :mysql ((vdb/current-driver) :dialect))
            "VOID_TEST_MYSQL names a MySQL, which is the point of this file")

    # the second boot: every table exists, and every index answers
    # ER_DUP_KEYNAME, which the schema pass reads as "done"
    (jobsdb/create-tables! tbl)

    (conformance/run! "db-mysql" (jobsdb/store {:table tbl}))))

(print "db-mysql-test ok")
