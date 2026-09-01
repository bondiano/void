# Is there a Postgres for the second pass of the suite?
#
#     VOID_TEST_PG="host=127.0.0.1 port=5432 user=void dbname=void_test" jpm test
#     VOID_TEST_PG="postgres://void:void@127.0.0.1:5432/void_test" jpm test
#
# CI sets it against a service container, so "the same application on
# Postgres" is a real gate there (exit criterion 1 of wave 2).
# On a laptop without one the suite runs the sqlite pass and says the
# other was skipped — the same bargain void/db-postgres, void/redis and
# void/jobs strike.

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

(defn config
  ``The [:db-postgres] config slice for the configured server: the
  conninfo goes in as :url when it is one and as :params otherwise,
  since the slice speaks keywords either way.``
  []
  (def info (conninfo))
  (if (string/find "://" info)
    {:url info}
    {:params (tabseq [pair :in (string/split " " info)
                      :let [kv (string/split "=" pair)]
                      :when (= 2 (length kv))]
               (keyword (kv 0)) (kv 1))}))
