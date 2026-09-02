(import ../test-support/paths)
(import ../test-support/postgres :as server)
(import ../test-support/conformance :as conformance)
(import void/core/log :as log)
(import void/db :as vdb)
(import void/db/pool :as pool)
(import void/db/state :as db)
(import void/jobs/backend :as backend)
(import void/jobs/db :as jobsdb)
(import void/jobs/record :as record)

(each ns ["void.db" "void.db.query" "void.jobs" "void.jobs.db"]
  (log/set-level! ns :fatal))

# void/jobs-db has two claim paths and test/db-test.janet exercises the
# portable one. This is the other: on Postgres a claim is a single
# `UPDATE ... WHERE id = (SELECT ... FOR UPDATE SKIP LOCKED)
# RETURNING`, and it is the statement the whole backend rests on —
# "two workers asking at the same moment must not get the same
# record". Nothing below runs without a server, so the suite skips
# loudly rather than passing vacuously.

(if-not (server/available?)
  (do (server/skip "jobs db-postgres")
      (os/exit 0)))

# a table of this suite's own: the database is shared with void/db's
# and void/db-postgres's suites, and a conformance run that began by
# truncating *their* fixtures would be a nasty way to find that out
(def tbl "void_jobs_pg_test")

(def p (pool/make (server/driver {:application-name "void-jobs-pg-test"})
                  {:size 8}))

(defn- drop-tables! []
  # client_min_messages: DROP IF EXISTS on a table that is not there is
  # the normal case here, and three NOTICEs per run would train the eye
  # to skip the output this suite exists to produce
  (db/execute-sql "SET client_min_messages = warning" []
                  {:kind :write :prepared false})
  (each t [tbl (string tbl "_locks") (string tbl "_rates")]
    (db/execute-sql (string "DROP TABLE IF EXISTS " t) []
                    {:kind :write :prepared false})))

(defer (do (with-dyns [db/pool-dyn p] (drop-tables!))
           (pool/close-all! p))
  (with-dyns [db/pool-dyn p]
    (drop-tables!)
    (jobsdb/create-tables! tbl)

    (assert (= :postgres ((vdb/current-driver) :dialect))
            "VOID_TEST_PG names a Postgres, which is the point of this file")

    # -- the contract, over the SKIP LOCKED path -------------------------

    (conformance/run! "db-postgres" (jobsdb/store {:table tbl}))

    # -- what SKIP LOCKED is for -----------------------------------------
    #
    # The conformance suite claims one record at a time on one fiber,
    # which every backend passes by construction. The property that
    # needs a real Postgres is that *concurrent* claimants divide the
    # queue instead of colliding: with SKIP LOCKED a blocked row is
    # skipped rather than waited on, so N fibers claiming at once get N
    # distinct records and nobody deadlocks.

    (def b (backend/normalize (jobsdb/store {:table tbl})))
    ((b :clear!) {})

    (def n 8)
    (def ids @{})
    (each i (range n)
      (def r ((b :push!) (record/make {:job :race :queue :race})))
      (put ids (r :id) true))
    (assert (= n (length ids)) "n distinct records are queued")

    (def now (os/clock :realtime))
    (def done (ev/chan n))
    (each i (range n)
      (ev/go (fn claimer []
               (def r ((b :claim!) {:queues [:race] :now now
                                    :token (string "w" i)}))
               (ev/give done (or r :none)))))
    # every claimant reports, so a claim that came back empty is a
    # failed assertion below rather than a test that hangs
    (def claimed
      (filter dictionary? (seq [_ :range [0 n]] (ev/take done))))

    (def got (map |($ :id) claimed))
    (assert (= n (length got))
            (string/format "every claimant got a record (got %d of %d)" (length got) n))
    (assert (= n (length (distinct got)))
            "and no two claimants got the same one — this is what SKIP LOCKED buys")
    (each id got
      (assert (get ids id) "and every record claimed is one that was queued"))
    (assert (= n (length (filter |(= :running ($ :state)) claimed)))
            "each of them came back :running")

    # a queue drained concurrently is a queue drained: nothing is left
    # pending, and nothing was handed out twice
    (assert (nil? ((b :claim!) {:queues [:race] :now now :token "extra"}))
            "and the ninth claimant gets nothing rather than a duplicate")

    ((b :clear!) {})

    # -- the unique race, on the engine where losing aborts --------------
    #
    # Concurrent pushes of one unique key: each pusher's check sees
    # nothing (the winner's row is uncommitted), so the losers reach
    # the INSERT and hit the partial index. On Postgres that violation
    # aborts the transaction (SQLSTATE 25P02) — the documented
    # "already queued -> nil" branch only runs because the INSERT sits
    # in its own savepoint. sqlite cannot exercise this: a failed
    # constraint does not abort its transaction there.

    (def pushers 6)
    (def pushed (ev/chan pushers))
    (each i (range pushers)
      (ev/go (fn pusher []
               (ev/give pushed
                        (protect ((b :push!) (record/make {:job :uniq :queue :default
                                                           :unique-key "pg:race"})))))))
    (def outcomes (seq [_ :range [0 pushers]] (ev/take pushed)))
    (assert (all |(get $ 0) outcomes)
            "no pusher saw an error — the losing INSERT was confined to its savepoint")
    (assert (= 1 (length (filter |(get $ 1) outcomes)))
            "exactly one push stored the job and the rest were told nil")
    ((b :clear!) {})

    # -- the lease race, same 25P02 class --------------------------------

    (def lockers 6)
    (def leased (ev/chan lockers))
    (def lt (os/clock :realtime))
    (each i (range lockers)
      (ev/go (fn locker []
               (ev/give leased ((b :lock!) "pg:lease" 30 (string "t" i) lt)))))
    (assert (= 1 (length (filter truthy? (seq [_ :range [0 lockers]] (ev/take leased)))))
            "one lease, however many ask at once — and no aborted transactions")

    ((b :clear!) {})))

(print "db-postgres-test ok")
