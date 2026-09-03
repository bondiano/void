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
###
### Wave 3 added ten plugins and no engine-specific line: signing in
### (by password or by a link in the mail), deciding who may edit what,
### and the browser-facing protections are the same list on sqlite and
### on Postgres (test/auth-test.janet runs twice as well).
###
### Wave 3.6 added three more and one file (./audit). The audit trail
### is a bus consumer: no handler calls it, no entity has a callback,
### and deleting ./audit stops the trail without changing anything
### else.
(import void)
(import void/http)
(import void/html)
(import void/htmx)
(import void/db)
(import void/db/http)
(import void/cache)
(import void/jobs)
(import void/jobs/db)
(import void/crypto)
(import void/auth)
(import void/auth/http)
(import void/auth/db)
(import void/authz)
(import void/authz/http)
(import void/security)
(import void/mail)
(import void/mail/jobs)
(import void/mail/auth)
(import void/bus)
(import void/bus/db)
(import void/bus/jobs)
(import void/dev)
(import void/mcp)
(import void/admin)
(import void/admin/mcp)
(import ./app)
(import ./admin)

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
   # wave 3: sign in, decide, and the four things a browser needs.
   # void/auth-db reads the authors table this application already had
   # (config/default.janet says which columns); void/authz reads the
   # identity from a dyn key and never imports void/auth; void/security
   # signs the CSRF token with void/crypto's HMAC.
   :void/crypto
   :void/auth :void/auth-http :void/auth-db
   :void/authz :void/authz-http
   :void/security
   # 3.5: the sign-in link is a letter, and it goes out through the
   # queue this application already runs — void/mail-jobs is the whole of
   # that, and no handler mentions it
   :void/mail :void/mail-jobs :void/mail-auth
   # 3.6: the audit trail. void/bus-db puts the message log, the
   # consumer cursors and the outbox in the same database as the data — so
   # "the article exists" and "the trail says so" commit together.
   # void/bus-jobs puts the queue's own lifecycle on the bus, and the
   # trail gets it for nothing
   :void/bus :void/bus-db :void/bus-jobs
   # 4.4: the back office is a projection of the entities this
   # application already declared — ./admin.janet is declarations and
   # nothing else, and the audit trail above picks its changes up through
   # the bus without either side knowing the other ...and the *same*
   # declarations reach an agent through MCP, with the same gate and the
   # same per-action policies: void/admin-mcp is a projection of the
   # registry ./admin.janet fills, and neither it nor ./admin.janet says a
   # word about the other
   :void/admin :void/mcp :void/admin-mcp
   :void/dev
   :blog/app :blog/admin])

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
