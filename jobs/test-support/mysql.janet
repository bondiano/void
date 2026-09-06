# Is there a MySQL to test the db backend against?
#
# The third engine the backend claims to run on, and the one with the
# most to say back: no RETURNING, no partial indexes, no `CREATE INDEX
# IF NOT EXISTS`, a TEXT column that cannot be a key — every one of
# them a branch in void/jobs/db that only a real server exercises.
# test/db-test.janet runs the conformance suite over sqlite and
# test/db-postgres-test.janet over Postgres; this file is how the
# MySQL run gets a server at all:
#
#     VOID_TEST_MYSQL="mysql://void:void@127.0.0.1:3306/void_test" jpm test
#     VOID_TEST_MYSQL="host=127.0.0.1 port=3306 user=void password=void database=void_test" jpm test
#
# CI sets it against a service container, so the MySQL path is a real
# gate there. On a laptop without one — or without libmysqlclient —
# the suite announces itself skipped rather than failing, the same
# bargain void/db-mysql strikes under the same variable.
#
# The driver is loaded with `require` at runtime rather than imported,
# for the reason ./postgres gives: nothing this suite does not need
# should be touched on a machine that cannot run it.

(import void/test :as test)

(def env-var "VOID_TEST_MYSQL")

(def- gate (test/service env-var "a mysql:// url or a key=value list"))

(def dsn "The configured server, or nil." (gate :value))
(def available? "Is there a server to test against?" (gate :available?))
(def skip "Announce a skipped suite the way a passing one announces itself." (gate :skip))

(def- numeric {:port true :connect-timeout true})

(defn config
  ``The [:db-mysql] config slice for the configured server: a URL goes
  in as :url, a key=value list as the keys it names — the slice speaks
  both, so a CI environment can pass either.``
  [&opt extra]
  (def v (dsn))
  (def base
    (if (string/find "://" v)
      {:url v}
      (from-pairs
        (seq [pair :in (string/split " " v) :when (not (empty? pair))]
          (def i (or (string/find "=" pair)
                     (errorf "%s: %q is not key=value" env-var pair)))
          (def key (keyword (string/slice pair 0 i)))
          (def raw (string/slice pair (inc i)))
          [key (if (numeric key) (scan-number raw) raw)]))))
  (merge base (or extra {})))

(defn- fetch
  "The value of one binding in a module loaded at runtime."
  [mod sym]
  (def entry (get mod sym))
  (unless entry
    (errorf "%q does not export %q" mod sym))
  (get entry :value))

(defn driver
  ``The normalized void/db driver for the configured server. Resolved
  through `require`, so that nothing of void/db-mysql is touched
  unless there is a server to talk to.``
  [&opt extra]
  ((fetch (require "void/db") 'normalize-driver)
    ((fetch (require "void/db-mysql/driver") 'from-config) (config extra))))
