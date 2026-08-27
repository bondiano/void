# Is there a Postgres to test against?
#
# Everything that can be tested without a server is (config, types,
# the plugin's declarations), and it runs everywhere. The rest needs a
# real backend, and rather than guess at one, the suite asks for it by
# name:
#
#     VOID_TEST_PG="host=127.0.0.1 port=5432 user=void dbname=void_test" jpm test
#     VOID_TEST_PG="postgres://void:void@127.0.0.1:5432/void_test" jpm test
#
# CI sets it against a service container, so the integration tests are
# a real gate there. On a laptop without one they announce themselves
# as skipped instead of failing — a missing database is not a broken
# driver, and a suite that cannot be run at all is a suite nobody runs.

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
      # a keyword string is already the shape `config/keywords` builds,
      # so it goes straight into the escape hatch
      {:params (from-pairs
                 (seq [pair :in (string/split " " info)
                       :when (not (empty? pair))]
                   (def i (string/find "=" pair))
                   [(string/slice pair 0 i)
                    # unquote a 'quoted value', which is how a conninfo
                    # carries a password with a space in it
                    (let [v (string/slice pair (inc i))]
                      (if (and (string/has-prefix? "'" v)
                               (string/has-suffix? "'" v))
                        (string/slice v 1 -2)
                        v))]))}))
  (merge base (or extra {})))
