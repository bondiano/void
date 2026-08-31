# Is there a MySQL to test against?
#
# Everything that can be tested without a server is (the config, the
# placeholder scanner, the value encoding, the plugin's declarations),
# and it runs everywhere. The rest needs a real backend, and rather
# than guess at one, the suite asks for it by name:
#
#     VOID_TEST_MYSQL="mysql://void:void@127.0.0.1:3306/void_test" jpm test
#     VOID_TEST_MYSQL="host=127.0.0.1 port=3306 user=void password=void database=void_test" jpm test
#
# CI sets it against a service container, so the integration tests are
# a real gate there. On a laptop without one they announce themselves
# as skipped instead of failing — a missing database is not a broken
# driver, and a suite that cannot be run at all is a suite nobody runs.
# This is the same arrangement void/db-postgres has under VOID_TEST_PG.

(def env-var "VOID_TEST_MYSQL")

(defn dsn
  "The configured server, or nil."
  []
  (when-let [v (os/getenv env-var)]
    (unless (empty? (string/trim v)) (string/trim v))))

(defn available?
  "Is there a server to test against?"
  []
  (not (nil? (dsn))))

(defn skip
  "Announce a skipped suite the way a passing one announces itself, so
  a scrolled-past CI log still says which is which."
  [suite]
  (printf "%s: SKIPPED (set %s to a mysql:// url or a key=value list)"
          suite env-var)
  nil)

(def- numeric {:port true :connect-timeout true})
(def- booleans {:found-rows true :reconnect true})

(defn config
  ``The [:db-mysql] config slice for the configured server. A URL goes
  in as :url, which the slice already understands; a key=value list is
  read into the keys it names, so a CI environment can pass either.``
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
          [key (cond
                 (numeric key) (scan-number raw)
                 (booleans key) (not= "false" raw)
                 raw)]))))
  (merge base (or extra {})))

(defn table-name
  ``A table name nothing else in this run will pick. The suite creates
  and drops its own tables in whatever database it was pointed at, so
  the names have to be unlikely rather than pretty.``
  [prefix]
  (string "void_" prefix "_" (os/time) "_" (math/floor (* 100000 (math/random)))))
