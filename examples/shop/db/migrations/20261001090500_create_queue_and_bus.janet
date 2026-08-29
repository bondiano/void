### The tables void/jobs-db and void/bus-db keep their records in —
### created here, by a migration this application owns, out of the DDL
### those two plugins ship as data.
###
### Both of them will create these at boot on their own
### (`[:jobs-db :auto-create]`, `[:bus-db :auto-create]`), which is the
### right default for a laptop and the wrong one for a deployment, for
### two reasons this example ran into in that order:
###
###   * two processes starting at once race on `CREATE INDEX IF NOT
###     EXISTS`, and Postgres answers one of them with an error — the
###     web tier and the worker in docker-compose.yml start together;
###   * a schema that appears when a process happens to boot is a
###     schema nobody reviewed, in a database somebody has to back up.
###
### So config/prod.janet turns auto-create off, and this file is what
### `void db migrate` runs instead. It is the same bargain the wave-3
### migration strikes with void/auth-db's tables: the DDL belongs to
### the plugin, the timeline belongs to the application (ADR-0023 §2).
###
### The table names are the two plugins' defaults. A deployment that
### renames them ([:jobs-db :table], [:bus-db :table]) passes the same
### name here — that is what the optional argument is for.

(import void/db :as db)
(import void/jobs/db :as jobs-db)
(import void/bus/db :as bus-db)

(def jobs-table "void_jobs")
(def bus-table "void_bus")

(defn- dialect []
  ((db/current-driver) :dialect))

(defn up []
  # SQL strings rather than statement maps: the message log needs a
  # monotonic sequence column, and how to declare one is the one piece
  # of DDL the two engines genuinely do not agree on (void/bus/db) —
  # so the plugin writes it per dialect and the migration asks for the
  # dialect it is running against
  [;(jobs-db/ddl jobs-table)
   ;(bus-db/ddl (dialect) bus-table)])

(defn down []
  [{:drop-table (string jobs-table "_rates")}
   {:drop-table (string jobs-table "_locks")}
   {:drop-table jobs-table}
   {:drop-table (string bus-table "_outbox")}
   {:drop-table (string bus-table "_leases")}
   {:drop-table (string bus-table "_cursors")}
   {:drop-table bus-table}])
