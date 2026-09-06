(import ../test-support/paths)
(import void/bus/conformance/backend :as conformance)
(import ../test-support/mysql :as server)
(import void/core/log :as log)
(import void/db :as vdb)
(import void/db/pool :as pool)
(import void/db/state :as db)
(import void/bus/db :as busdb)

(each ns ["void.db" "void.db.query" "void.bus" "void.bus.db"]
  (log/set-level! ns :fatal))

# The MySQL half of void/bus-db: the same conformance suite
# test/db-test.janet runs over sqlite, on the engine with no NOTIFY
# (so the polling path, and only that), no ON CONFLICT (the insert's
# one dialect branch), and a `bigint auto_increment` as the log's
# sequence.
#
# Skipped without VOID_TEST_MYSQL; a gate in CI, which runs a service
# container (the bargain void/db-mysql strikes under the same name).

(if-not (server/available?)
  (do (server/skip "void/bus-db on MySQL")
      (os/exit 0)))

(def tbl (string "void_bus_my_" (os/getpid)))
(def p (pool/make (server/driver) {:size 6}))

(defn- drop-tables! []
  (each t [tbl (string tbl "_cursors") (string tbl "_leases") (string tbl "_outbox")]
    (protect (db/execute-sql (string "DROP TABLE IF EXISTS " t) []
                             {:kind :write :prepared false}))))

(defer (do (with-dyns [db/pool-dyn p] (db/with-conn (drop-tables!)))
           (pool/close-all! p))
  (with-dyns [db/pool-dyn p]
    (db/with-conn (drop-tables!))
    (db/with-conn (busdb/create-tables! tbl))

    (assert (= :mysql ((vdb/current-driver) :dialect))
            "VOID_TEST_MYSQL names a MySQL, which is the point of this file")

    # the second boot: every table exists, and every index answers
    # ER_DUP_KEYNAME, which the schema pass reads as "done"
    (db/with-conn (busdb/create-tables! tbl))

    (conformance/run! "mysql"
                      (fn [] (busdb/store {:table tbl :poll-interval 0.05 :notify false
                                           :stuck-interval 0.05 :stuck-max 0.2}))
                      {:settle 0.4})

    (print "void/bus-db MySQL tests OK")))
