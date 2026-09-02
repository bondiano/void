### The tables void/jobs-db keeps its records in — created here, by a
### migration this application owns, out of the DDL the plugin ships as
### data.
###
### The plugin will create them at boot on its own
### (`[:jobs-db :auto-create]`), which is right for a laptop and wrong
### for a deployment: the web tier and the worker start together, and
### two processes racing on `CREATE INDEX IF NOT EXISTS` is an error
### one of them gets. It is the same bargain the generated `users`
### migration strikes with void/auth-db's tables — the DDL belongs to
### the plugin, the timeline belongs to the application (ADR-0023 §2).
###
### The queue is in **this** database rather than beside it, which is
### what lets a received delivery and the notification it caused be one
### commit (ADR-0012).

(import void/jobs/db :as jobs-db)

(def jobs-table "void_jobs")

(defn up []
  (jobs-db/ddl jobs-table))

(defn down []
  [{:drop-table (string jobs-table "_rates")}
   {:drop-table (string jobs-table "_locks")}
   {:drop-table jobs-table}])
