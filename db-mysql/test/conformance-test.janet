(import ../test-support/paths)
(import ../test-support/server)
(import void/core/log :as log)
(import void/db/conformance/driver :as conformance)
(import void/db-mysql/driver :as mysql)

(each ns ["void.db" "void.db.query"] (log/set-level! ns :fatal))

# The :void/db-driver conformance suite against MySQL: the same
# assertions sqlite and Postgres pass, on the engine without RETURNING
# (the :insert-id path), with errno-disambiguated SQLSTATEs and a
# BOOLEAN that is really a TINYINT(1). No cancellation section: the
# client library blocks the fiber for the duration of a statement, so
# a cancel lands after the reply and there is no mid-flight to test.

(if-not (server/available?)
  (do (server/skip "db-mysql conformance")
      (os/exit 0)))

(conformance/run! "mysql" (mysql/from-config (server/config)))
