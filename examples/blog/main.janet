### blog — entrypoint. Run with `void dev` (or `janet main.janet`);
### the void CLI (void routes, void db migrate, void jobs stats, ...)
### reads the app binding below.
###
### The composition is the interesting part. Every plugin here is the
### same on both engines except one: which :void/db-driver is in the
### list. Swap it and the entities, the migrations, the handlers, the
### jobs and the cache are untouched — that is the claim wave 2 makes,
### and test/crud-test.janet runs the whole suite twice to keep it
### honest.
(import void)
(import void/http)
(import void/html)
(import void/htmx)
(import void/db)
(import void/db/http)
(import void/cache)
(import void/jobs)
(import void/jobs/db)
(import void/dev)
(import ./app)

(def databases
  ``The :void/db-driver plugin per database. The driver module is
  required rather than imported: a process that never touches Postgres
  never loads libpq (or void/fdwait's native module) at all.``
  {:sqlite (fn [] (require "void/db-sqlite/init") :void/db-sqlite)
   :postgres (fn [] (require "void/db-postgres/init") :void/db-postgres)})

(defn plugins
  ``The composition, as a function of the one thing that changes.
  Everything but the driver is the same list on either engine — which
  is the wave-2 demo, and what test/crud-test.janet asserts.``
  [database]
  (def load-driver
    (or (databases database)
        (errorf "unknown database %q (known: %s)" database
                (string/join (map string (sorted (keys databases))) " "))))
  [:void/http :void/html :void/htmx
   :void/db (load-driver) :void/db-http
   :void/cache
   :void/jobs :void/jobs-db
   :void/dev
   :blog/app])

(def database
  ``Which database this process boots on: :sqlite (the default — a
  file, nothing to install) or :postgres. `VOID_BLOG_DB=postgres void
  dev` is the whole of the change; the connection itself is
  config/<profile>.janet, or libpq's own PG* environment.``
  (keyword (or (os/getenv "VOID_BLOG_DB") "sqlite")))

(def app
  "Boot options — what (void/run! ...) starts and the void CLI reads."
  {:plugins (plugins database)
   :profile (keyword (or (os/getenv "VOID_PROFILE") "dev"))})

(defn main [& args]
  (void/run! app))
