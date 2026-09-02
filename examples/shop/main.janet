### shop — entrypoint. Run with `void dev` (or `janet main.janet`);
### the void CLI (void routes, void db migrate, void jobs work, void
### admin resources, void deploy check, void shop seed, void mcp
### serve, ...) reads the app binding below — and so does this file's
### own `main`, which *is* that CLI when it is given arguments.
###
### The composition is the whole point of this example. Thirty-eight
### void plugins plus this application's own (forty-three with redis
### and a bucket), and the application code that knows about any of them is
### the route metadata in each module's controller: the transactions,
### the identity, the policies, the CSRF token, the rate limits, the
### caching, the metrics, the tracing, the load shedding and the whole
### back office are all *composed* here rather than called there.
###
### Three things are chosen by environment, and each is one line:
###
###   VOID_SHOP_DB=postgres     the driver (sqlite by default)
###   VOID_SHOP_REDIS=1         sessions and the cache in redis
###   VOID_SHOP_STORAGE=s3      product pictures in a bucket (a
###                             directory by default)
###
### Everything else is identical between a laptop and the compose file
### in ./docker-compose.yml — which is the claim this example makes,
### and the reason test/shop-test.janet runs the same suite on both
### engines.
# void/cli rather than void: the entrypoint below hands its boot
# options to `cli/app-main`, which runs them when there are no
# arguments and dispatches the CLI when there are — so this file never
# calls `void/run!` itself (examples/guestbook is the same shape, and
# examples/blog is the plain one)
(import void/cli)
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
(import void/mcp)
(import void/mcp/obs)
(import void/admin)
(import void/admin/jobs)
(import void/admin/mcp)
(import void/storage)
(import void/storage/http)
(import void/storage/admin)
(import void/dev)
(import void/dash)
(import ./src/app)

(def databases
  ``The :void/db-driver plugin per database. The driver module is
  required rather than imported: a process that never touches Postgres
  never loads libpq (or void/fdwait's native module) at all.``
  {:sqlite (fn [] (require "void/db-sqlite/init") :void/db-sqlite)
   :postgres (fn [] (require "void/db-postgres/init") :void/db-postgres)})

(defn- s3-plugins
  ``The bucket, when this deployment has one. Required rather than
  imported, for the reason the driver is: a laptop keeping product
  pictures in ./storage never loads a signer, and never opens the TLS
  stack that an https endpoint would need (ADR-0038, ADR-0039).``
  []
  (require "void/storage/s3")
  (require "void/tls/init")
  [:void/storage-s3 :void/tls])

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
  ``The composition, as a function of the three things a deployment
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

   # the same application to an agent: `void mcp serve` speaks MCP on
   # stdin/stdout, and every tool it offers is a command an operator
   # already runs — `void jobs stats`, `void bus tail`, `void db
   # status` — because each of those declared itself read-only.
   # Nothing that writes is there: `void db migrate` and this
   # application's own `void shop seed` are withheld until somebody
   # puts them in [:mcp :tools] (ADR-0031). The HTTP transport
   # (:void/mcp-http) is deliberately *not* composed here: it is one
   # more line and one token, and an example should not hand out a
   # tool endpoint by default
   :void/mcp :void/mcp-obs

   # the back office, which is not a module of this application: every
   # `src/modules/*/*.admin.janet` is declarations over the entities
   # that module already had, and these three plugins are the three
   # readers of them — void/admin mounts every action as an ordinary
   # named route, void/admin-jobs runs the bulk that is too big for a
   # request (and is refused at start if the queue is per-process),
   # and void/admin-mcp projects the *same* declarations into tools,
   # so the desk and the agent cannot drift apart (ADR-0029,
   # ADR-0031). The gate is `[:admin :access] :staff` in
   # config/default.janet — one line, naming the policy the shop
   # already had
   :void/admin :void/admin-jobs :void/admin-mcp

   # product pictures (ADR-0039): the contract, the route that serves
   # what a disk store holds, and the admin widget that puts an upload
   # behind the one `:file` field in catalog.model. Which store is
   # behind them is the third thing a deployment changes — see
   # `storage` below
   :void/storage :void/storage-http :void/storage-admin

   ;(if (get opts :s3) (s3-plugins) [])
   ;(if (get opts :redis) (redis-plugins) [])

   # void/dev stays in the :prod composition of *this* application, and
   # that is a decision rather than an oversight. The compose file
   # deploys from source, where the netrepl costs a unix socket inside
   # the container and buys `docker compose exec web void repl` — a
   # REPL in the running web process, which is a thing void is for
   # (SPEC §4); the watcher half is off in config/prod.janet, because
   # nothing in a container changes on disk. A **single binary** is the
   # case where it has to go: void/dev builds that repl's environment
   # with `require`, and a marshalled image has no module tree to
   # require from — so a `jpm build` of this application drops it from
   # the list, which is one line and what examples/guestbook shows
   # (docs/DEPLOY.md rule 2)
   :void/dev

   # the dev dashboard (ADR-0043): six pages projected off the same
   # boot value the REPL reads — composition, components, config with
   # provenance, routes, logs with a live tail, and dash/tap. Open in
   # :dev; any other profile refuses until [:dash :access] names a
   # predicate, the same construction as the admin's gate
   :void/dash
   :shop/app])

(defn database
  ``Which database this process boots on: :sqlite (the default — a
  file, nothing to install) or :postgres. `VOID_SHOP_DB=postgres void
  dev` is the whole of the change; the connection itself is
  config/<profile>.janet, or libpq's own PG* environment.``
  []
  (keyword (or (os/getenv "VOID_SHOP_DB") "sqlite")))

(defn redis?
  ``Whether this process keeps its sessions and its cache in redis.
  Off on a laptop (one process, nothing to install), on in the compose
  file, where the web tier is more than one process and an in-memory
  session store would be a login that works every other request
  (ADR-0010).``
  []
  (truthy? (let [v (os/getenv "VOID_SHOP_REDIS")]
             (and v (not (index-of v ["" "0" "false" "no"]))))))

(defn s3?
  ``Whether product pictures live in a bucket. Off on a laptop (a
  directory, nothing to install), on in the compose file, where minio
  is the bucket and the web tier is more than one process — a picture
  uploaded to one replica's disk is a 404 on the next, which is what
  `[:deploy :shape] :fleet` refuses to start with (ADR-0030).``
  []
  (truthy? (let [v (os/getenv "VOID_SHOP_STORAGE")]
             (and v (= "s3" (string/ascii-lower v))))))

(defn profile
  "The profile this process runs under."
  []
  (keyword (or (os/getenv "VOID_PROFILE") "dev")))

(def app
  ``Boot options — what the `void` CLI reads when it loads this module
  out of a source checkout (`void routes`, `void db migrate`, `void
  admin resources`).

  `main` builds its own rather than using this one, and the difference
  is the single binary: `jpm build` marshals every *value* on the
  machine that built it, so an `os/getenv` in a `def` is the
  environment of the CI runner frozen into the executable
  (docs/DEPLOY.md rule 1). Here that is harmless — the CLI loads this
  file on the machine it runs on — and there it would be a lie.

  :plugins-for is the contract `void dev` and run! resolve: this
  shop's composition does not depend on the profile at all — it
  depends on the three environment switches, and the closure reads
  them when it is *called*, which is the running process.``
  {:plugins-for (fn [_] (plugins (database) {:redis (redis?) :s3 (s3?)}))
   :profile (profile)})

(defn main [& args]
  # every one of these is read *now*, in the process that is starting,
  # rather than in a value that a build would have frozen
  (def prof (profile))
  # cli/app-main runs the application when it is given no arguments and
  # *is* the void binary when it is given some — `./shop db migrate`,
  # `./shop deploy check`, `./shop plugins check`, `./shop jobs work`
  # against the composition inside this file and no other. A deployment
  # that cannot run its own migrations is not a deployment
  # (docs/DEPLOY.md)
  (cli/app-main {:plugins (plugins (database) {:redis (redis?) :s3 (s3?)})
                 :profile prof}
                ;(drop 1 args)))
