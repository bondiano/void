(import ../test-support/paths)
(import ../test-support/server)
(import void/core/log :as log)
(import void/db/conformance/driver :as conformance)
(import void/db-postgres/driver :as postgres)
(import void/db-postgres/libpq :as libpq)

(each ns ["void.db" "void.db.query"] (log/set-level! ns :fatal))

# The :void/db-driver conformance suite against Postgres: the same
# assertions sqlite passes, on the engine with native SQLSTATEs, a
# prepared-statement pair and RETURNING. The cancellation section is
# on, because pg_sleep exists and the driver can be interrupted.

(if-not (server/available?)
  (do (server/skip "db-postgres conformance")
      (os/exit 0)))

(libpq/load!)
(conformance/run! "postgres"
                  (postgres/from-config (server/config {:application-name "void-conformance"}))
                  {:sleep-sql "SELECT pg_sleep(5)"})
