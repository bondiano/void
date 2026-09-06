(import ../test-support/paths)
(import ../test-support/mysql :as server)
(import void/jobs/conformance/backend :as conformance)
(import void/core/log :as log)
(import void/db :as vdb)
(import void/db/pool :as pool)
(import void/db/state :as db)
(import void/jobs/backend :as backend)
(import void/jobs/db :as jobsdb)
(import void/jobs/record :as record)

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

    (conformance/run! "db-mysql" (jobsdb/store {:table tbl}))

    # -- retention, through the builder on this engine -------------------
    #
    # The prune is a SELECT of one batch (`LIMIT ?`, a bound parameter
    # MySQL takes only as an integer) and a DELETE by id (`IN` over the
    # batch) — the shape that replaced `DELETE ... WHERE id IN (SELECT
    # ... LIMIT n)`, which MySQL refuses. In batches of two, so that
    # the batching is exercised rather than read.

    (def keeper (backend/normalize (jobsdb/store {:table tbl :keep-for 0 :prune-batch 2})))
    (def finished-at (- (os/clock :realtime) 10))
    (def done-ids
      (seq [_ :range [0 3]]
        (def r ((keeper :push!) (record/make {:job :done :queue :default})))
        (def c ((keeper :claim!) {:queues [:default] :now (os/clock :realtime) :token "w"}))
        ((keeper :settle!) (record/complete! c nil finished-at))
        (r :id)))
    (defn still-there [] (filter |((keeper :fetch) $) done-ids))
    (assert (= 3 (length (still-there))) "three finished records, kept for 0 seconds")
    ((keeper :reap!) {:now (os/clock :realtime) :ttl 60 :token "w"})
    (assert (= 1 (length (still-there)))
            "one reaper pass prunes one batch — :prune-batch 2 of the three")
    ((keeper :reap!) {:now (os/clock :realtime) :ttl 60 :token "w"})
    (assert (empty? (still-there)) "and the next pass takes the rest")))

(print "db-mysql-test ok")
