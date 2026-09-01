### The package graph of the monorepo, as data (ADR-0020).
###
### It used to be written three times and read by nothing: sixteen
### copies of `*/test-support/paths.janet`, prose in every
### `project.janet` ("void-core (../core) must be on the module path as
### well"), and the order of the steps in CI. Here it is written once;
### everything else is a projection:
###
###   */test-support/paths.janet   the module path of a package's tests
###   project.janet                the `void` bundle's :source list
###   scripts/dry-run.janet        the trees the composition gate loads
###   .github/workflows/ci.yml     the per-package `jpm test` steps
###   scripts/bootstrap.janet      what a contributor has to build
###
### A forgotten edge stops being a silent error: it is a missing module
### in a test run, and `check` below refuses a graph that disagrees with
### the tree on disk.
###
### Run it to print a projection:
###
###     janet scripts/packages.janet order    # topological install order
###     janet scripts/packages.janet trees    # :source list for the bundle
###     janet scripts/packages.janet ci       # the `jpm test` steps
###     janet scripts/packages.janet deps     # the bundle's jpm dependencies
###     janet scripts/packages.janet dev-deps # what a checkout needs
###     janet scripts/packages.janet check    # graph vs. the tree on disk
###
### And, for the examples that run off an installed tree instead of the
### checkout (`:installed` below, scripts/install-tree.janet):
###
###     janet scripts/packages.janet ci-installed    # their `jpm test` steps
###     janet scripts/packages.janet installed-deps  # what the tree needs
###                                                  # besides the bundle

# -- the graph -----------------------------------------------------------
#
# Per package:
#
#   :dir        repo-relative directory
#   :deps       void packages this one's *sources* import
#   :test-deps  extra packages its test suite (or its sub-apps) reaches,
#               without the sources importing them
#   :jpm        external jpm dependencies, by git URL key (see `jpm-urls`)
#   :jpm-optional  the same, but deliberately not the bundle's — the
#               package declares it, an application opts in by plugin
#   :native     builds a native module into <dir>/build (only fdwait)
#   :example    an example application, not part of the bundle
#   :installed  an example that resolves void from an *installed* tree
#               rather than from the checkout (see below)
#
# :deps are direct edges only — the transitive closure is computed.
#
# `:installed` inverts what every other entry here is for. An ordinary
# example imports void through `test-support/paths.janet`, which is this
# graph projected onto module/paths — so its suite proves the sources
# work and proves nothing at all about the install. An installed example
# has no such file: it imports `void/...` the way a stranger does, from
# whatever `scripts/install-tree.janet` put in a tree, which means it
# also pays what a stranger pays — a change to the framework reaches it
# only after that script runs again. Its `:deps` stay written down
# because they are true (its sources do import those packages) and
# because they are the composition, in the one place compositions are
# written; nothing projects them onto a module path.

(def graph
  "The monorepo's packages and the edges between them."
  {:void/core
   {:dir "core" :deps [] :jpm [:spork]}

   :void/fdwait
   # The one native module (ADR-0011). Depends on nothing — what Janet
   # cannot express, and nothing else.
   {:dir "fdwait" :deps [] :native true}

   :void/crypto
   # Every cryptographic primitive void has, from the system libcrypto
   # through ffi/ (ADR-0022): nothing is compiled and no jpm dependency
   # pulls the library in — it is opened at :start from a configured
   # path, the way void/db-postgres opens libpq (ADR-0011). spork is
   # here for base64, which is an alphabet rather than cryptography.
   {:dir "crypto" :deps [:void/core] :jpm [:spork]}

   :void/dev
   {:dir "dev" :deps [:void/core] :jpm [:spork]}

   :void/http
   # void/dev only in tests: the suite drives test/inject (ADR-0017)
   # against this package's own kernel.
   {:dir "http" :deps [:void/core] :test-deps [:void/dev]}

   :void/html
   {:dir "html" :deps [:void/core :void/http] :test-deps [:void/dev] :jpm [:spork]}

   :void/htmx
   {:dir "htmx" :deps [:void/core :void/http] :test-deps [:void/html] :jpm [:spork]}

   :void/rest
   {:dir "rest" :deps [:void/core :void/http] :jpm [:spork]}

   :void/openapi
   # The projection reads route metadata, not void/rest — but the suite
   # asserts on the schemas void/rest puts there.
   {:dir "openapi" :deps [:void/core :void/http] :test-deps [:void/rest] :jpm [:spork]}

   :void/cli
   # The binary boots whatever the *application* lists in :plugins, so
   # the CLI itself needs only the kernel. The suite reaches further: it
   # runs `void new` and then boots the generated project, which is the
   # full wave-1 plugin list — and it runs `void make resource`, whose
   # output declares an entity, so void/db loads there too.
   #
   # `void make auth` is why the second half of that list is here. Its
   # generated suite is the scaffold's own proof (ROADMAP 6.2): it
   # boots the generated plugin on a real database and drives register,
   # sign in, reset and verify through test/inject — so everything the
   # generated composition names has to be importable here. The
   # examples are deliberately not what checks this; the scaffold is
   # checked by what it itself generates.
   {:dir "cli" :deps [:void/core]
    :test-deps [:void/http :void/html :void/htmx :void/dev :void/db
                :void/db-sqlite :void/crypto :void/auth :void/security]
    :jpm [:spork]}

   :void/db
   # void/http for the optional void/db-http plugin (:void.db/txn route
   # metadata) — same package, separate plugin.
   {:dir "db" :deps [:void/core :void/http]}

   :void/db-sqlite
   # janet-lang/sqlite3 is :jpm-optional, not :jpm — db-sqlite's own
   # project.janet declares it (the contributor path), the bundle does
   # not: an application that never lists :void/db-sqlite in :plugins
   # never imports the driver, and a missing library is an error at
   # :start with a readable text, the way libpq is (ADR-0011, ADR-0020).
   {:dir "db-sqlite" :deps [:void/core :void/db] :jpm-optional [:sqlite3]}

   :void/db-postgres
   # libpq is opened at runtime through ffi/, so it is not a jpm
   # dependency; void/fdwait is, and it has to be built (ADR-0011).
   {:dir "db-postgres" :deps [:void/core :void/db :void/fdwait]}

   :void/db-mysql
   # libmysqlclient is opened at runtime through ffi/, so it is not a
   # jpm dependency — and unlike void/db-postgres there is no native
   # module either: this driver parks on a channel to a worker thread
   # rather than on a descriptor, so void/fdwait is not an edge
   # (ADR-0033).
   {:dir "db-mysql" :deps [:void/core :void/db]}

   :void/redis
   # A connection is a net/ stream — no client library. void/http only
   # for void/redis-http, which contributes the session store.
   {:dir "redis" :deps [:void/core] :test-deps [:void/http] :jpm [:spork]}

   :void/cache
   {:dir "cache" :deps [:void/core :void/http :void/redis]}

   :void/jobs
   # void/db-sqlite is what the db backend is tested against;
   # void/db-postgres is on the path for the SKIP LOCKED suite but is
   # resolved with `require` only when VOID_TEST_PG names a server.
   {:dir "jobs" :deps [:void/core :void/db :void/redis]
    :test-deps [:void/db-sqlite :void/db-postgres] :jpm [:spork]}

   :void/pressure
   # void/rest in tests only: the 503 goes out as problem+json wherever
   # it is in the composition.
   {:dir "pressure" :deps [:void/core :void/http] :test-deps [:void/rest]}

   :void/obs
   # void/pressure is here for its loop-lag *meter*
   # (`void/pressure/sample`), the way void/bench/probe takes it — the
   # module, never the plugin: a process that observes itself must not
   # thereby start shedding. void/http is two plugins' in this package
   # (the void/cache — void/cache-http split): void/obs-http's server
   # side, and void/obs-otlp's client — the OTLP exporter POSTs to a
   # collector through void/http/client (ADR-0027). void/proto is the
   # exporter's second encoding: void/obs/otlp-proto bakes the vendored
   # OTLP .proto files into descriptors, and only a composition that
   # configures [:obs-otlp :encoding] :protobuf ever loads it.
   # void/dev and void/cache are the suite's: inject for the endpoints,
   # a real component for the instrumentation. void/rest is
   # test-support/overhead-probe.janet's, which measures what obs costs
   # a request on the B1 shape (§8.2's ≤ 7%).
   {:dir "obs" :deps [:void/core :void/http :void/pressure :void/proto]
    :test-deps [:void/dev :void/cache :void/rest] :jpm [:spork]}

   :void/auth
   # Every primitive comes from void/crypto (ADR-0022, ADR-0023): this
   # package hashes nothing itself. void/http is void/auth-http's and
   # void/db is void/auth-db's — separate plugins in this package, the
   # void/cache — void/cache-redis split. void/auth-oauth is a fourth
   # (ADR-0032) and needs no new edge: it verifies JWS with
   # void/crypto/sign and talks to the issuer with void/http/client,
   # both already here. The suite reaches void/dev for inject
   # (ADR-0017) and void/db-sqlite for a real store under void/auth-db.
   {:dir "auth" :deps [:void/core :void/crypto :void/http :void/db]
    :test-deps [:void/dev :void/db-sqlite] :jpm [:spork]}

   :void/oauth
   # The OAuth client half (ADR-0034), now that ADR-0032 built the
   # resource server: void/auth for the jwk/jwt modules (the id_token
   # is verified by the same code that verifies an access token) and
   # for auth-http/login!, void/http for the two routes and the
   # back-channel client, void/crypto for PKCE and state. The suite
   # reaches void/dev for inject (ADR-0017) — the fake authorization
   # server stands on a socket of its own, the way the auth suite's
   # does.
   {:dir "oauth" :deps [:void/core :void/crypto :void/http :void/auth]
    :test-deps [:void/dev] :jpm [:spork]}

   :void/i18n
   # Dictionaries as contributions, the locale as a dyn (ADR-0036).
   # void/http is the one runtime edge: the middleware that resolves
   # the locale and binds it together with the :void.schema/messages
   # seam void/core/schema has carried since wave 0. No edge to
   # void/html, and that is the design — a template reaches `t`
   # through the dyn, because the render middleware runs inside the
   # chain. The suite reaches void/html to prove exactly that (a
   # hiccup view and a form error rendered in Russian through a full
   # boot) and void/dev for the test scaffolding.
   {:dir "i18n" :deps [:void/core :void/http]
    :test-deps [:void/dev :void/html]}

   :void/datastar
   # The Datastar experiment (ADR-0037): SSE patch events, data-*
   # builders, and the Biff idiom — the morph middleware slices the
   # page void/html already rendered, so the edge to void/html is
   # real (hiccup rendering inside morph-stream), and the SSE framing
   # is void/http's ring/sse from wave 0. No edge to void/htmx: the
   # two are alternative idioms an application picks between, not
   # layers. The suite reaches void/dev for inject (ADR-0017) — the
   # SSE frames are parsed out of :raw by test/sse-events.
   {:dir "datastar" :deps [:void/core :void/http :void/html]
    :test-deps [:void/dev] :jpm [:spork]}

   :void/authz
   # No edge to void/auth, and that is the design (ADR-0024): the
   # identity is read from the dyn key void/auth publishes, so an
   # application with its own authentication gets the same
   # authorization. void/http is void/authz-http's, a separate plugin
   # in this package. The suite reaches void/auth (and void/crypto
   # under it) to prove the seam works from both ends.
   {:dir "authz" :deps [:void/core :void/http]
    :test-deps [:void/dev :void/auth :void/crypto]}

   :void/security
   # void/crypto because every CSRF token is signed (ADR-0022 §6, the
   # decision to have one token rather than two). No edge to void/auth
   # or void/authz: the identity is a dyn key and the rate limiter keys
   # on whatever it finds. The suite reaches html and htmx for the form
   # slot and the meta tag, rest for the problem+json shape of a 429,
   # cache for the shared-counter path and auth for the cookie-borne
   # rule that decides when CSRF applies at all.
   {:dir "security" :deps [:void/core :void/http :void/crypto]
    :test-deps [:void/dev :void/html :void/htmx :void/rest :void/cache :void/auth]}

   :void/mail
   # A mail body is rendered through void/html's engine point, so it is
   # written the way a page is and temple works for both — that edge is
   # what "templates through void/html" (SPEC §5.19) means, and it is
   # the only one the mailer itself has. void/jobs is void/mail-jobs'
   # and void/auth is void/mail-auth's: two more plugins in this
   # package, the void/cache — void/cache-http split again, so an
   # application without a queue or without logins composes neither.
   # The suite reaches void/dev for the inject client under the
   # magic-link route and void/crypto because void/auth mints the code
   # with it.
   {:dir "mail" :deps [:void/core :void/html :void/jobs :void/auth]
    :test-deps [:void/dev :void/crypto] :jpm [:spork]}

   :void/bus
   # The messaging layer (ADR-0012). void/db is void/bus-db's — the
   # message log, the cursors and the transactional outbox are rows,
   # and they are rows in the application's own database on purpose;
   # void/jobs is void/bus-jobs', which forwards the queue's lifecycle
   # events onto the bus. Both are separate plugins in this package,
   # the void/cache — void/cache-redis split, so an application whose
   # messages never leave the process composes neither. The suite
   # reaches void/db-sqlite for a real log to consume from,
   # void/db-postgres for the LISTEN/NOTIFY and SKIP LOCKED paths
   # (resolved with `require` only when VOID_TEST_PG names a server)
   # void/obs to prove the trace continues out of a request and into a
   # consumer — bus imports none of the three — and void/dev for
   # `test/start!`, which boots the plugin the way an application
   # would.
   {:dir "bus" :deps [:void/core :void/db :void/jobs]
    :test-deps [:void/db-sqlite :void/db-postgres :void/obs :void/dev]
    :jpm [:spork]}

   :void/kafka
   # librdkafka is opened at runtime through ffi/, so it is not a jpm
   # dependency; void/fdwait IS an edge — the integration is a fiber
   # parked on the fd the library rings (ADR-0035). void/bus is
   # void/kafka-bus's, a separate plugin in this package (the
   # void/cache — void/cache-redis split): the :kafka backend factory
   # and the envelope spelling live there. The suite runs its
   # integration half only when VOID_TEST_KAFKA names a cluster.
   {:dir "kafka" :deps [:void/core :void/fdwait :void/bus]}

   :void/tls
   # Outbound TLS from the system libssl (ADR-0038). libssl is opened
   # at runtime through ffi/, so it is not a jpm dependency;
   # void/crypto IS an edge — BIO and the X509 error strings live in
   # libcrypto, and they are bound off crypto's open handle so the
   # process holds one crypto stack. The edges to http, redis and
   # mail point *backward* on purpose: each of those holds a seam
   # `(var tls-... nil)` (the void/mail-jobs pose), and this package's
   # :on-load installs the connector into every one — wave 1 never
   # imports wave 5. The suite reaches void/dev for the boot half.
   {:dir "tls" :deps [:void/core :void/crypto :void/http :void/redis :void/mail]
    :test-deps [:void/dev]}

   :void/storage
   # Files and uploads (ADR-0039). Four plugins in one package, the
   # void/cache — void/cache-http split: the kernel and the :local
   # store are plain Janet over the filesystem, so the real edges are
   # the other three's. void/http is void/storage-http's (the serve
   # route through the static machinery) and the s3 store's transport
   # (http/client — and void/tls closes the https seam at runtime,
   # never an edge, ADR-0038); void/crypto is SigV4's; void/security
   # is a *module* edge for temporary URLs (./sign reads the signing
   # keys the way void/obs reads void/pressure's sampler — composing
   # :void/security is what arms it); void/admin is
   # void/storage-admin's, the upload widget. The suite reaches
   # void/dev for test/start! (ADR-0017) and void/db-sqlite for a real
   # database under the admin resource whose form carries an upload.
   {:dir "storage" :deps [:void/core :void/crypto :void/http :void/security :void/admin]
    :test-deps [:void/dev :void/db-sqlite]}

   :void/notify
   # Unified notifications (ADR-0040). Five plugins in one package, the
   # void/cache — void/cache-http split: the kernel is core-only, and
   # every edge here belongs to one channel. void/mail is
   # void/notify-mail's (the letter is built by the mailer and goes
   # back out through mail/send-delivery, so [:mail :queue] keeps
   # meaning what it means); void/db, void/http and void/html are
   # void/notify-inapp's — the table the bell reads, the four routes
   # that draw it and the fragments they answer with; void/http is also
   # the webhook's transport (http/client — and void/tls closes the
   # https seam at runtime, never an edge, ADR-0038), with void/crypto
   # a *module* edge for its signature, the void/storage/sign pose:
   # composing :void/crypto is what arms it. void/jobs is
   # void/notify-jobs'. No edge to void/auth and that is the design
   # (ADR-0024): the bell reads the identity off the dyn key, so an
   # application with its own authentication gets the same widget. The
   # suite reaches void/dev for test/start! (ADR-0017), void/db-sqlite
   # for a real table under the in-app channel and void/auth to prove
   # the dyn seam works from both ends.
   {:dir "notify" :deps [:void/core :void/crypto :void/http :void/html
                         :void/db :void/jobs :void/mail]
    :test-deps [:void/dev :void/db-sqlite :void/auth] :jpm [:spork]}

   :void/ws
   # WebSocket over the HTTP kernel (ADR-0028): the handshake is
   # answered from an ordinary route handler, so the only edge is
   # void/http — everything that protects a route already protects a
   # socket. spork is here for base64, an alphabet rather than
   # cryptography (the same reason void/crypto declares it), and there
   # is deliberately no edge to void/crypto: see ws/void/ws/sha1.janet.
   # void/html and void/htmx are void/ws-htmx's, a separate plugin in
   # this package — the void/cache — void/cache-http split again.
   {:dir "ws" :deps [:void/core :void/http :void/html :void/htmx]
    :test-deps [:void/dev] :jpm [:spork]}

   :void/proto
   # protobuf, and no transport (ADR-0013): the codec, the `.proto`
   # parser and the JSON mapping are pure Janet over void/core's schema
   # layer, which is the one edge — void/proto/schema registers two
   # custom types and the :proto projection SPEC §3.3 reserved for it.
   # void/grpc is where a socket appears. The suite reaches void/dev for
   # nothing at all and says so by not listing it.
   {:dir "proto" :deps [:void/core] :jpm [:spork]}

   :void/grpc
   # Connect-RPC over the HTTP kernel (ADR-0013): a method is a route,
   # so void/http is the only transport edge and every policy that
   # protects a route — void/authz, void/security, void/obs — protects
   # an RPC method without knowing one exists. void/proto is the codec
   # on both sides of it. The suite reaches void/dev for inject
   # (ADR-0017), void/rest because the problem+json renderer and the
   # Connect error renderer have to coexist in one composition, and
   # void/authz to prove a policy on an RPC method is the same policy.
   {:dir "grpc" :deps [:void/core :void/http :void/proto]
    :test-deps [:void/dev :void/rest :void/authz] :jpm [:spork]}

   :void/mcp
   # The application as an MCP server (ADR-0031). void/openapi is a
   # *module* edge and not a plugin one: ./registry projects a
   # registered schema into JSON Schema with void/openapi/jsonschema,
   # the way void/obs takes void/pressure's loop-lag meter without
   # composing the shedder. void/http is void/mcp-http's and void/obs
   # is void/mcp-obs's — two more plugins in this package, the
   # void/cache — void/cache-http split, so an agent talking to a jobs
   # worker over stdio composes neither. The suite reaches void/dev for
   # inject (ADR-0017) under the HTTP transport.
   {:dir "mcp" :deps [:void/core :void/http :void/openapi :void/obs]
    :test-deps [:void/dev] :jpm [:spork]}

   :void/admin
   # The back office as a projection of what the application already
   # declared (ADR-0029). Every edge here is one the projection reads
   # from: void/db for the entity descriptor and the repository,
   # void/html for the form projection and the view responses,
   # void/htmx for the fragment half of the same route, void/authz for
   # the gate and the per-action policies. void/jobs is
   # void/admin-jobs' and void/mcp is void/admin-mcp's — two more
   # plugins in this package, the void/cache — void/cache-http split,
   # so an admin with no heavy actions composes no queue and an
   # application with no agent composes no MCP server. The suite
   # reaches void/dev for inject (ADR-0017), void/db-sqlite for a real
   # database to CRUD against and void/security for the CSRF slot the
   # forms carry.
   {:dir "admin" :deps [:void/core :void/http :void/html :void/htmx
                        :void/db :void/authz :void/jobs :void/mcp]
    :test-deps [:void/dev :void/db-sqlite :void/security]
    :jpm [:spork]}

   :void/bench
   # The B* mini-apps run as subprocesses and reach further than the
   # runner does — html for B3's SSR, rest for B1, db + db-postgres for
   # B2/B3, obs for the b1-obs row that measures §8.2's ≤ 7%
   # instrumentation budget, ws for B4's broadcast (see
   # bench/apps/prelude.janet, which asks for this same set).
   {:dir "bench" :deps [:void/core :void/http :void/db :void/pressure]
    :test-deps [:void/rest :void/html :void/db-postgres :void/obs :void/ws]
    :jpm [:spork]}

   # -- examples: smoke tests in CI, never part of the bundle ------------
   #
   # examples/demo is a single plugin file, not a package: the dry-run
   # gate loads it off the repository root and it has no suite of its own.

   :example/guestbook
   # void/cli because its entrypoint is the one `void new` writes, and
   # that one calls cli/app-main: with no arguments it runs the app,
   # with arguments it *is* the void binary — which is what makes a
   # single-binary deploy able to run its own migrations (docs/DEPLOY.md).
   {:dir "examples/guestbook"
    :deps [:void/core :void/http :void/html :void/htmx :void/dev :void/cli]
    :example true :jpm [:spork]}

   :example/counter
   # The wave-5 experiment's example (ADR-0037): the Biff idiom on
   # void/datastar — a live counter where every action returns the
   # full page, Datastar morphs the live DOM, and morph-stream + poke!
   # keep every open tab converging on the same count. void/cli for
   # the same reason as guestbook's: the entrypoint calls cli/app-main.
   {:dir "examples/counter"
    :deps [:void/core :void/http :void/html :void/datastar :void/dev :void/cli]
    :example true :jpm [:spork]}

   :example/shop
   # The demo that puts the whole framework in one application:
   # catalog, cart, checkout, payments, a declared back office, a JSON
   # API with its OpenAPI document, and the enterprise layer under all
   # of it — obs, pressure, auth, authz, security, mail and bus. Both
   # drivers are edges for the same reason blog's are: the suite runs
   # on sqlite always and on Postgres when VOID_TEST_PG names a
   # server, and main.janet requires exactly one of them at boot.
   # void/admin brings its three plugins (the desk, the agent's half
   # and the queue's), and void/cli is here because the entrypoint
   # calls cli/app-main: with no arguments it runs the app, with
   # arguments it *is* the void binary (docs/DEPLOY.md).
   {:dir "examples/shop"
    :deps [:void/core :void/http :void/html :void/htmx
           :void/rest :void/openapi
           :void/db :void/db-sqlite :void/db-postgres
           :void/cache :void/jobs :void/redis
           :void/obs :void/pressure
           :void/crypto :void/auth :void/authz :void/security
           :void/mail :void/bus :void/mcp :void/admin
           # product pictures (ADR-0039): the contract and the disk
           # store on a laptop, the bucket in the compose file — and
           # void/tls under it, because an https endpoint is a TLS
           # stack the composition has to carry (ADR-0038)
           :void/storage :void/tls
           :void/dev :void/cli]
    :example true :jpm [:spork :sqlite3]}

   :example/blog
   # The wave-2 demo: the same CRUD application on either driver. Both
   # are edges, because the suite runs against sqlite always and
   # against Postgres when VOID_TEST_PG names a server — main.janet
   # requires exactly one of them at boot.
   {:dir "examples/blog"
    :deps [:void/core :void/http :void/html :void/htmx
           :void/db :void/db-sqlite :void/db-postgres
           :void/cache :void/jobs
           # wave 3: the demo signs people in (by password and by a
           # link in the mail), decides what they may edit and protects
           # the forms — the exit criterion for 3.2-3.5
           :void/crypto :void/auth :void/authz :void/security
           # 3.5: the sign-in link is a letter, queued through the same
           # void/jobs the counter runs in
           :void/mail
           # 3.6: the audit trail is a bus consumer, and the facts it
           # records ride the transactional outbox
           :void/bus
           # 4.4: the back office, which is ./admin.janet and nothing
           # else — four declarations over the entities wave 2 wrote,
           # projected into pages for a person and (void/admin-mcp,
           # which lives in the same package) into tools for an agent
           :void/admin :void/mcp
           :void/dev]
    :example true :jpm [:spork :sqlite3]}

   :example/hub
   # The wave-6 application (ROADMAP 6.6): a webhook hub — GitHub
   # deliveries in, telegram out — and the one example that runs off an
   # *installed* void rather than off the checkout. It has no
   # test-support/paths.janet on purpose: `scripts/install-tree.janet`
   # puts the bundle in a tree, and from there the hub imports
   # `void/...` with no more privilege than a stranger has. That is why
   # its suite is not in `suites` below and does not run in CI's
   # checkout job — it runs in the clean-machine one, which is the only
   # place where what it proves is true.
   #
   # It began as `void new hub` plus `void make auth` and nothing else,
   # so its first commit is the scaffold's own output: every hand edit
   # after it is a line in a diff and a candidate for a task.
   {:dir "examples/hub"
    :deps [:void/core :void/http :void/html :void/htmx
           :void/db :void/db-sqlite
           # the sign-in the scaffold generated: identity, the stores it
           # keeps people in, the CSRF token its forms carry, and the
           # deliverer a challenge refuses to live without (ADR-0023 §7)
           :void/crypto :void/auth :void/security :void/mail
           :void/dev :void/cli]
    :example true :installed true :jpm [:spork :sqlite3]}})

(def jpm-urls
  "External jpm dependencies, by the key packages name them with."
  {:spork "https://github.com/janet-lang/spork.git"
   :sqlite3 "https://github.com/janet-lang/sqlite3.git"})

# -- where the repository is ---------------------------------------------
#
# Derived from this file, not from (os/cwd): jpm test runs with cwd set
# to a package directory, the bench apps are spawned from anywhere, and
# the shims must work in all of it.

(defn- dirname [p]
  (def idxs (string/find-all "/" p))
  (if (empty? idxs) "." (string/slice p 0 (last idxs))))

(def root
  "Absolute path of the repository root."
  (os/realpath (string (dirname (dyn *current-file*)) "/..")))

(defn dir
  "Absolute path of a package's directory."
  [name]
  (def entry (or (graph name) (errorf "unknown package %q" name)))
  (string root "/" (entry :dir)))

# -- projections ---------------------------------------------------------

(defn- edges [name with-tests?]
  (def entry (or (graph name) (errorf "unknown package %q" name)))
  [;(entry :deps) ;(if with-tests? (or (entry :test-deps) []) [])])

(defn closure
  ``The transitive closure of `names` in topological order: every
  package comes after the packages it depends on, and `names`
  themselves come last. `test-deps` edges are followed only for the
  roots, not for the dependencies they drag in — a package's suite is
  its own business.``
  [names &opt with-tests?]
  (def seen @{})
  (def order @[])
  (defn visit [name tests?]
    (case (seen name)
      :done nil
      :open (errorf "dependency cycle at %q" name)
      (do
        (put seen name :open)
        (each dep (edges name tests?) (visit dep false))
        (put seen name :done)
        (array/push order name))))
  (each name names (visit name with-tests?))
  order)

(defn packages
  "The bundle's packages (everything but the examples), in declaration order."
  []
  (filter |(not (get-in graph [$ :example])) (sorted (keys graph))))

(defn install-order
  "The bundle's packages in topological order."
  []
  (closure (packages)))

(defn source-trees
  ``The `void/` trees of the bundle's packages, repo-relative — the
  :source list of the root project.janet. They install into one merged
  <modpath>/void/.``
  []
  (map |(string (get-in graph [$ :dir]) "/void") (install-order)))

(defn- installed-example? [name]
  (and (get-in graph [name :example]) (get-in graph [name :installed])))

(defn suites
  ``Everything with a `jpm test` suite that runs against the checkout:
  the bundle's packages in topological order, then the examples that
  reach them through `test-support/paths.janet`. The list of steps CI's
  test job runs.

  Installed examples are deliberately absent — see `installed-suites`.``
  []
  [;(install-order)
   ;(sorted (filter |(and (get-in graph [$ :example])
                          (not (get-in graph [$ :installed])))
                    (keys graph)))])

(defn installed-suites
  ``The examples that run against an *installed* tree rather than the
  checkout. They are a separate list because they need a different
  thing done first: not a module path, an install.``
  []
  (sorted (filter installed-example? (keys graph))))

(defn jpm-dependencies
  ``External jpm dependencies, in install order and without duplicates.
  Without `optional?` this is the bundle's :dependencies list, which
  leaves janet-lang/sqlite3 out on purpose: void/db-sqlite is a plugin
  an application opts into, and a missing library is an error at :start,
  not at install (ADR-0011, ADR-0020). With it, this is what a checkout
  needs before `jpm test` — a suite does not get to opt out.``
  [&opt optional?]
  (def urls @[])
  (each name (install-order)
    (each key [;(or (get-in graph [name :jpm]) [])
               ;(if optional? (or (get-in graph [name :jpm-optional]) []) [])]
      (def url (or (jpm-urls key) (errorf "unknown jpm dependency %q" key)))
      (unless (index-of url urls) (array/push urls url))))
  urls)

(defn installed-jpm-dependencies
  ``What has to be in the installed tree besides the bundle itself for
  the installed examples to run: the external dependencies they declare
  and the bundle does not carry. janet-lang/sqlite3 is the whole of the
  list today, and it is here for the reason it is *not* in the bundle —
  the driver is an application's opt-in (ADR-0011, ADR-0020), so the
  application that opts in installs it, which is what this is.``
  []
  (def bundled (jpm-dependencies))
  (def urls @[])
  (each name (installed-suites)
    (each key (or (get-in graph [name :jpm]) [])
      (def url (or (jpm-urls key) (errorf "unknown jpm dependency %q" key)))
      (unless (or (index-of url bundled) (index-of url urls))
        (array/push urls url))))
  urls)

(defn native?
  "Does the closure of `names` include a package with a native module?"
  [names]
  (some |(get-in graph [$ :native]) (closure names true)))

# -- module paths --------------------------------------------------------

(defn- add-tree [path]
  (array/insert module/paths 0 [(string path "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string path "/:all:.janet") :source]))

(defn add-paths
  ``Put the closure of `names` on the module path, so every package in
  it is importable as void/... from the checkout, with nothing
  installed. Later insertions win, so the roots shadow their
  dependencies.``
  [names &opt with-tests?]
  (def order (closure names with-tests?))
  (each name order (add-tree (dir name)))
  # The native module lives where `jpm build` leaves it, out of the
  # source tree (cd fdwait && jpm build).
  (when (some |(get-in graph [$ :native]) order)
    (array/insert module/paths 0
                  [(string (dir :void/fdwait) "/build/:all:.so") :native]))
  order)

(defn test-paths
  ``What `*/test-support/paths.janet` calls: the package's own tree plus
  everything its sources and its suite reach.``
  [name]
  (add-paths [name] true))

# -- the graph agrees with the tree on disk ------------------------------

(defn check
  "Validate the graph against the repository. Returns a list of problems."
  []
  (def problems @[])
  (each name (sorted (keys graph))
    (def entry (graph name))
    (def d (string root "/" (entry :dir)))
    (unless (= :directory (os/stat d :mode))
      (array/push problems (string/format "%q: no such directory %s" name (entry :dir))))
    (unless (or (entry :example) (= :directory (os/stat (string d "/void") :mode)))
      (array/push problems (string/format "%q: no source tree %s/void" name (entry :dir))))
    (unless (= :file (os/stat (string d "/project.janet") :mode))
      (array/push problems (string/format "%q: no %s/project.janet" name (entry :dir))))
    (each key [;(or (entry :jpm) []) ;(or (entry :jpm-optional) [])]
      (unless (jpm-urls key)
        (array/push problems (string/format "%q: unknown jpm dependency %q" name key))))
    # an installed example is one that imports void the way a stranger
    # does. A test-support/paths.janet would put the checkout back on
    # its module path, and the arrangement would go on looking exactly
    # the same while proving nothing — so the file's absence is the
    # whole of the rule, and it is checked rather than remembered
    (when (entry :installed)
      (unless (entry :example)
        (array/push problems
                    (string/format "%q: :installed without :example" name)))
      (when (= :file (os/stat (string d "/test-support/paths.janet") :mode))
        (array/push problems
                    (string/format "%q: is :installed but has test-support/paths.janet — it would import the checkout, not the install"
                                   name))))
    (each dep [;(entry :deps) ;(or (entry :test-deps) [])]
      (unless (graph dep)
        (array/push problems (string/format "%q: depends on unknown package %q" name dep)))
      (when (get-in graph [dep :example])
        (array/push problems (string/format "%q: depends on the example %q" name dep)))))
  # cycles
  (each name (sorted (keys graph))
    (unless (first (protect (closure [name] true)))
      (array/push problems (string/format "%q: dependency cycle" name))))
  # every package directory in the repository is in the graph
  (def declared (from-pairs (seq [n :in (keys graph)] [(get-in graph [n :dir]) true])))
  (defn- scan [prefix]
    (each f (sorted (os/dir (string root "/" prefix)))
      (def rel (if (empty? prefix) f (string prefix "/" f)))
      (when (and (= :directory (os/stat (string root "/" rel) :mode))
                 (= :file (os/stat (string root "/" rel "/project.janet") :mode))
                 (not (declared rel)))
        (array/push problems
                    (string/format "%s/ has a project.janet but is not in the graph" rel)))))
  (scan "")
  (scan "examples")
  problems)

# -- CLI -----------------------------------------------------------------

(defn main [_ &opt what]
  (case (or what "check")
    "order" (each name (install-order) (print name))
    "trees" (each tree (source-trees) (print tree))
    "deps" (each url (jpm-dependencies) (print url))
    "dev-deps" (each url (jpm-dependencies true) (print url))
    "ci" (each name (suites)
           (printf "%s\t%s" (string name) (get-in graph [name :dir])))
    "ci-installed" (each name (installed-suites)
                     (printf "%s\t%s" (string name) (get-in graph [name :dir])))
    "installed-deps" (each url (installed-jpm-dependencies) (print url))
    "check" (let [problems (check)]
              (unless (empty? problems)
                (each p problems (eprint "  " p))
                (errorf "package graph: %d problem(s)" (length problems)))
              (printf "package graph ok (%d packages, %d examples)"
                      (length (packages))
                      (- (length graph) (length (packages)))))
    (errorf "usage: janet scripts/packages.janet [order|trees|deps|dev-deps|installed-deps|ci|ci-installed|check]")))
