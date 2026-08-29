### shop — entrypoint. Run with `void dev` (or `janet main.janet`);
### the void CLI (void routes, void db migrate, void jobs work, void
### shop seed, ...) reads the app binding below.
###
### The composition is the whole point of this example. Thirty void
### plugins plus this application's own (thirty-three with redis), and
### the application code that knows about any of them is the route
### metadata in each module's controller: the transactions, the
### identity, the policies, the CSRF token, the rate limits, the
### caching, the metrics, the tracing and the load shedding are all
### *composed* here rather than called there.
###
### Two things are chosen by environment, and both are one line:
###
###   VOID_SHOP_DB=postgres     the driver (sqlite by default)
###   VOID_SHOP_REDIS=1         sessions and the cache in redis
###
### Everything else is identical between a laptop and the compose file
### in ./docker-compose.yml — which is the claim this example makes,
### and the reason test/shop-test.janet runs the same suite on both
### engines.
(import void)
(import void/http)
(import void/html)
(import void/htmx)
(import void/rest)
(import void/openapi)
(import void/db)
(import void/db/http)
(import void/cache)
(import void/cache/http)
(import void/jobs)
(import void/jobs/db)
(import void/obs)
(import void/obs/http)
(import void/pressure)
(import void/pressure/http)
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
(import ./src/app)

(def databases
  ``The :void/db-driver plugin per database. The driver module is
  required rather than imported: a process that never touches Postgres
  never loads libpq (or void/fdwait's native module) at all.``
  {:sqlite (fn [] (require "void/db-sqlite/init") :void/db-sqlite)
   :postgres (fn [] (require "void/db-postgres/init") :void/db-postgres)})

(defn- redis-plugins
  ``The three plugins that move state out of the process: sessions
  (:redis session store), the cache, and nothing else — the queue and
  the bus stay in the database on purpose, because both of them have
  to commit with the data they are about (ADR-0012).``
  []
  (require "void/redis/init")
  (require "void/redis/http")
  (require "void/cache/redis")
  [:void/redis :void/redis-http :void/cache-redis])

(defn plugins
  ``The composition, as a function of the two things a deployment
  changes. Everything else is the same list on a laptop and in the
  compose file.``
  [database &opt opts]
  (default opts {})
  (def load-driver
    (or (databases database)
        (errorf "unknown database %q (known: %s)" database
                (string/join (map string (sorted (keys databases))) " "))))
  [# the request path: kernel, views, htmx, and the JSON sugar plus its
   # OpenAPI projection — one process serves the storefront and the API
   :void/http :void/html :void/htmx :void/rest :void/openapi

   # data: the kernel, one driver, and the route-level transaction
   :void/db (load-driver) :void/db-http

   # the cache, plus response caching for the routes that ask
   :void/cache :void/cache-http

   # the queue, in the same database as the data — which is what lets
   # the checkout enqueue a payment capture inside its transaction
   :void/jobs :void/jobs-db

   # observability, and the load shedding that reads the same
   # event-loop meter. /metrics /health /ready come with obs-http, and
   # pressure-http never sheds them
   :void/obs :void/obs-http
   :void/pressure :void/pressure-http

   # who is asking, what they may do, and the four things a browser
   # needs. void/authz never imports void/auth: it reads the identity
   # from a dyn key, so the policies would work under somebody else's
   # authentication (ADR-0024)
   :void/crypto
   :void/auth :void/auth-http :void/auth-db
   :void/authz :void/authz-http
   :void/security

   # mail: the letters, the queue they go out through, and the
   # magic-link deliverer void/auth has been waiting for since 3.2
   :void/mail :void/mail-jobs :void/mail-auth

   # messaging: the log and the outbox in the database, and the
   # queue's own lifecycle forwarded onto the bus
   :void/bus :void/bus-db :void/bus-jobs

   ;(if (get opts :redis) (redis-plugins) [])

   :void/dev
   :shop/app])

(def database
  ``Which database this process boots on: :sqlite (the default — a
  file, nothing to install) or :postgres. `VOID_SHOP_DB=postgres void
  dev` is the whole of the change; the connection itself is
  config/<profile>.janet, or libpq's own PG* environment.``
  (keyword (or (os/getenv "VOID_SHOP_DB") "sqlite")))

(def redis?
  ``Whether this process keeps its sessions and its cache in redis.
  Off on a laptop (one process, nothing to install), on in the compose
  file, where the web tier is more than one process and an in-memory
  session store would be a login that works every other request
  (ADR-0010).``
  (truthy? (let [v (os/getenv "VOID_SHOP_REDIS")]
             (and v (not (index-of v ["" "0" "false" "no"]))))))

(def app
  "Boot options — what (void/run! ...) starts and the void CLI reads."
  {:plugins (plugins database {:redis redis?})
   :profile (keyword (or (os/getenv "VOID_PROFILE") "dev"))})

(defn main [& args]
  (void/run! app))
