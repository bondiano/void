(import ../test-support/paths)
(import ../test-support/server)
(import void/core/log :as log)
(import void/db/conformance/lease :as lease-conformance)
(import void/db-mysql/driver :as mysql)

(each ns ["void.db" "void.db.query"] (log/set-level! ns :fatal))

# void/db/lease over MySQL — the engine with no RETURNING and a
# unique violation that arrives as errno 1062 under SQLSTATE 23000,
# which the kernel classifies into the kind the lease reads as
# "somebody else has it". The lease's SQL uses neither RETURNING nor
# SKIP LOCKED, so nothing here depends on the server's version.

(if-not (server/available?)
  (do (server/skip "db-mysql lease")
      (os/exit 0)))

(lease-conformance/run! "mysql" (mysql/from-config (server/config)))
