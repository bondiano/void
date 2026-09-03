### The table the database session store keeps its sessions in —
### created here, by a migration this application owns, out of the DDL
### void/db-http ships as data (`void db-http session-ddl` prints the
### same statements).
###
### The same bargain as the queue's tables one migration ago, and for the
### same two reasons: the plugin would create them at boot on its own
### (`[:db-http :session :auto-create]`), which is right for a laptop and
### wrong for a deployment where the web tier and the worker start
### together — and a schema that appears on its own is a schema nobody
### reviewed.
###
### Why sessions are in the database at all: `[:deploy :shape] :fleet`
### asks every store whether a second replica would see its contents, and
### an in-memory session store answers no — a login lands on whichever
### replica accept() gave it and works every other request. The other
### shared answer is redis, and this deployment does not run one: the
### queue is already in this database, and a second server for one table
### is a second thing to operate.
###
### `session-ddl` returns SQL strings rather than statement maps, which
### migrations execute as they are: `CREATE TABLE IF NOT EXISTS`
### spelled once by the plugin that owns the shape, for whichever engine
### is under it.
(import void/db/http :as db-http)

(def sessions-table "void_sessions")

(defn up []
  (db-http/session-ddl sessions-table))

(defn down []
  [{:drop-table sessions-table}])
