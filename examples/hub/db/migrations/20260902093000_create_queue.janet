### The tables void/jobs-db keeps its records in — created here, by a
### migration this application owns, out of the DDL the plugin ships as
### data.
###
### The plugin will create them at boot on its own
### (`[:jobs-db :auto-create]`), which is right for a laptop and wrong
### for a deployment: the web tier and the worker start together, and two
### processes racing on `CREATE INDEX IF NOT EXISTS` is an error one of
### them gets. It is the same bargain the generated `users` migration
### strikes with void/auth-db's tables — the DDL belongs to the plugin,
### the timeline belongs to the application.
###
### The queue is in **this** database rather than beside it, which is what
### lets a received delivery and the notification it caused be one commit.

(import void/db :as db)
(import void/jobs/db :as jobs-db)

(def jobs-table "void_jobs")

(defn up []
  # SQL strings for the dialect this migration runs against: the
  # plugin's declaration is one, the spelling is the engine's, and a
  # migration is where the two meet
  (jobs-db/ddl ((db/current-driver) :dialect) jobs-table))

(defn down []
  [{:drop-table (string jobs-table "_rates")}
   {:drop-table (string jobs-table "_locks")}
   {:drop-table jobs-table}])
