(import ../test-support/paths)
(import ../test-support/server)
(import void/core/log :as log)
(import void/db/conformance/lease :as lease-conformance)
(import void/db-postgres/driver :as postgres)
(import void/db-postgres/libpq :as libpq)

(each ns ["void.db" "void.db.query"] (log/set-level! ns :fatal))

# void/db/lease over Postgres — the engine where a failed statement
# poisons the transaction it is in (SQLSTATE 25P02), which is what the
# savepoint around the first taker's INSERT exists for, and where the
# racers really do run concurrently on separate connections.

(if-not (server/available?)
  (do (server/skip "db-postgres lease")
      (os/exit 0)))

(libpq/load!)
(lease-conformance/run! "postgres"
                        (postgres/from-config (server/config {:application-name "void-lease"})))
