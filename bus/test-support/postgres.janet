# Is there a Postgres to test the db backend's *other* wake-up path
# against?
#
# void/bus-db has two of them, and they are different code: on Postgres
# a publish issues `pg_notify` on the connection that inserted — so the
# wake-up rides the commit — and the consumer parks on
# void/db-postgres's listener instead of on a poll interval.
# test/db-test.janet runs the conformance suite over the portable path
# (sqlite, which polls); this file is how the Postgres one gets run at
# all.
#
#     VOID_TEST_PG="host=127.0.0.1 port=5432 user=void dbname=void_test" jpm test
#     VOID_TEST_PG="postgres://void:void@127.0.0.1:5432/void_test" jpm test
#
# CI sets it against a service container, so the NOTIFY path is a real
# gate there. On a laptop without one the suite announces itself
# skipped rather than failing — the same bargain void/db-postgres,
# void/redis and void/jobs strike, for the same reason.
#
# The driver is loaded with `require` at runtime rather than imported,
# because importing it would drag in void/fdwait's native module and
# make `cd bus && jpm test` fail to *compile* on a machine that has not
# built it — on the suites that need no database at all.

(def env-var "VOID_TEST_PG")

(defn conninfo
  "The configured server, or nil."
  []
  (when-let [v (os/getenv env-var)]
    (unless (empty? (string/trim v)) (string/trim v))))

(defn available?
  "Is there a server to test against?"
  []
  (not (nil? (conninfo))))

(defn skip
  "Announce a skipped suite the way a passing one announces itself, so
  a scrolled-past CI log still says which is which."
  [suite]
  (printf "%s: SKIPPED (set %s to a conninfo or a postgres:// url)"
          suite env-var)
  nil)

(defn config
  ``The [:db-postgres] config slice for the configured server: the
  conninfo goes in as :url when it is one and as :params otherwise,
  since the slice speaks keywords either way.``
  [&opt extra]
  (def info (conninfo))
  (def base
    (if (string/find "://" info)
      {:url info}
      {:params (tabseq [pair :in (string/split " " info)
                        :let [kv (string/split "=" pair)]
                        :when (= 2 (length kv))]
                 (keyword (kv 0)) (kv 1))}))
  (merge base (or extra {})))

(defn- fetch
  "The value of one binding in a module loaded at runtime."
  [mod sym]
  (def entry (get mod sym))
  (unless entry
    (errorf "%q does not export %q" mod sym))
  (get entry :value))

(defn driver
  ``The normalized void/db driver for the configured server, with
  libpq loaded. Resolved through `require` so that nothing native is
  touched unless there is a server to talk to.``
  [&opt extra]
  ((fetch (require "void/db-postgres/libpq") 'load!))
  ((fetch (require "void/db") 'normalize-driver)
    ((fetch (require "void/db-postgres/driver") 'from-config) (config extra))))

(defn listener
  ``An opened and started void/db-postgres listener for the configured
  server, or nil. What makes the NOTIFY path testable: the bus backend
  finds it through `void/db-postgres/init`'s module-level
  `subscribe!`, which needs a *started* listener component — this
  stands one up without a bootstrap.``
  [&opt extra]
  (def init (require "void/db-postgres/init"))
  (def mod (require "void/db-postgres/listener"))
  (def l ((fetch mod 'open) (conninfo) (or extra {})))
  ((fetch mod 'start!) l)
  # `current-listener` is a module var, so its binding carries a :ref
  # array — writing through it is what `set` compiles to, and it is the
  # only way to reach a var of a module loaded at runtime
  (put (get-in init ['current-listener :ref]) 0 l)
  l)
