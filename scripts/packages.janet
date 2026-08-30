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
#
# :deps are direct edges only — the transitive closure is computed.

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
   # full wave-1 plugin list.
   {:dir "cli" :deps [:void/core]
    :test-deps [:void/http :void/html :void/htmx :void/dev] :jpm [:spork]}

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
   # collector through void/http/client (ADR-0027).
   # void/dev and void/cache are the suite's: inject for the endpoints,
   # a real component for the instrumentation. void/rest is
   # test-support/overhead-probe.janet's, which measures what obs costs
   # a request on the B1 shape (§8.2's ≤ 7%).
   {:dir "obs" :deps [:void/core :void/http :void/pressure]
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
   {:dir "examples/guestbook"
    :deps [:void/core :void/http :void/html :void/htmx :void/dev]
    :example true :jpm [:spork]}

   :example/shop
   # The wave-3 demo, and the one that puts the whole framework in one
   # application: catalog, cart, checkout, payments, an admin desk, a
   # JSON API with its OpenAPI document, and the enterprise layer under
   # all of it — obs, pressure, auth, authz, security, mail and bus.
   # Both drivers are edges for the same reason blog's are: the suite
   # runs on sqlite always and on Postgres when VOID_TEST_PG names a
   # server, and main.janet requires exactly one of them at boot.
   {:dir "examples/shop"
    :deps [:void/core :void/http :void/html :void/htmx
           :void/rest :void/openapi
           :void/db :void/db-sqlite :void/db-postgres
           :void/cache :void/jobs :void/redis
           :void/obs :void/pressure
           :void/crypto :void/auth :void/authz :void/security
           :void/mail :void/bus :void/mcp
           :void/dev]
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
    :example true :jpm [:spork :sqlite3]}})

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

(defn suites
  ``Everything with a `jpm test` suite: the bundle's packages in
  topological order, then the examples. The list of steps CI runs.``
  []
  [;(install-order)
   ;(sorted (filter |(get-in graph [$ :example]) (keys graph)))])

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
    "check" (let [problems (check)]
              (unless (empty? problems)
                (each p problems (eprint "  " p))
                (errorf "package graph: %d problem(s)" (length problems)))
              (printf "package graph ok (%d packages, %d examples)"
                      (length (packages))
                      (- (length graph) (length (packages)))))
    (errorf "usage: janet scripts/packages.janet [order|trees|deps|dev-deps|ci|check]")))
