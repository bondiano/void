(import ../test-support/paths)
(import ../test-support/conformance :as conformance)
(import ../test-support/postgres :as pg)
(import void/core/log :as log)
(import void/db/pool :as pool)
(import void/db/state :as db)

(each ns ["void.db" "void.db.query" "void.db.postgres" "void.bus" "void.bus.db"]
  (log/set-level! ns :fatal))

# The Postgres half of void/bus-db: the same conformance suite
# test/db-test.janet runs over sqlite, plus the two things that only
# exist here — `bigserial` as the log's sequence, and a consumer woken
# by `pg_notify` rather than by a poll interval.
#
# Skipped without VOID_TEST_PG; a gate in CI, which runs a service
# container (ROADMAP 3.6, the bargain void/db-postgres and void/jobs
# already strike).

(if-not (pg/available?)
  (pg/skip "void/bus-db on Postgres")
  (do
    # imported at runtime, so a machine that has not built void/fdwait
    # can still compile every other suite in this package
    (def busdb (require "void/bus/db"))
    (def create-tables! (get-in busdb ['create-tables! :value]))
    (def store (get-in busdb ['store :value]))
    (def backend (require "void/bus/backend"))
    (def normalize (get-in backend ['normalize :value]))

    (def tbl (string "void_bus_pg_" (os/getpid)))
    (def p (pool/make (pg/driver) {:size 6}))

    (defer (do
             (with-dyns [db/pool-dyn p]
               (db/with-conn
                 (each t [tbl (string tbl "_cursors") (string tbl "_leases")
                          (string tbl "_outbox")]
                   (protect (db/execute-sql (string "DROP TABLE IF EXISTS " t) []
                                            {:kind :write :prepared false})))))
             (pool/close-all! p))
      (with-dyns [db/pool-dyn p]
        (db/with-conn (create-tables! tbl))

        # -- the contract, over the engine that has NOTIFY -------------
        #
        # The listener is started first, so the backend finds it the
        # public way (void/db-postgres/init's `subscribe!`) and the
        # consumers park on notifications. The poll interval is left
        # long on purpose: what wakes them here has to be the NOTIFY.

        (def listener (pg/listener))
        (defer ((get-in (require "void/db-postgres/listener") ['stop! :value]) listener)
          (conformance/run! "postgres"
                            {:settle 0.4
                             :store {:table tbl :poll-interval 5 :notify true}})

          # -- and the same suite with the wake-up taken away ---------
          #
          # A NOTIFY that never arrives must cost latency and never
          # correctness, so the polling path is run against Postgres
          # too rather than assumed to be sqlite's.

          (db/with-conn
            (each t [(string tbl "_cursors") (string tbl "_leases")]
              (db/execute-sql (string "DELETE FROM " t) [] {:kind :write :prepared false}))
            (db/execute-sql (string "DELETE FROM " tbl) [] {:kind :write :prepared false}))
          (conformance/run! "postgres (polling)"
                            {:settle 0.4
                             :store {:table tbl :poll-interval 0.05 :notify false}}))

        (print "void/bus-db Postgres tests OK")))))
