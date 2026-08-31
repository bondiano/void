# Is there a Kafka to test against?
#
# Everything that can be tested without a broker is (the config, the
# property list, the topic spelling, the vu layout, the plugin's
# declarations), and it runs everywhere. The rest needs a real
# cluster, and rather than guess at one, the suite asks for it by
# name:
#
#     VOID_TEST_KAFKA="127.0.0.1:9092" jpm test
#
# CI sets it against a service container (a single redpanda broker
# answers the same protocol), so the integration tests are a real
# gate there. On a laptop without one they announce themselves as
# skipped instead of failing — a missing broker is not a broken
# backend, and a suite that cannot be run at all is a suite nobody
# runs. This is the same arrangement void/db-mysql has under
# VOID_TEST_MYSQL and void/db-postgres under VOID_TEST_PG.

(def env-var "VOID_TEST_KAFKA")

(defn brokers
  "The configured bootstrap servers, or nil."
  []
  (when-let [v (os/getenv env-var)]
    (unless (empty? (string/trim v)) (string/trim v))))

(defn available?
  "Is there a cluster to test against?"
  []
  (not (nil? (brokers))))

(defn skip
  "Announce a skipped suite the way a passing one announces itself, so
  a scrolled-past CI log still says which is which."
  [suite]
  (printf "%s: SKIPPED (set %s to bootstrap servers, e.g. 127.0.0.1:9092)"
          suite env-var)
  nil)

(defn config
  "The [:kafka] config slice for the configured cluster."
  [&opt extra]
  (merge {:brokers (brokers)
          # the suite's own bound: a test cluster that cannot answer
          # in five seconds is down, and waiting the default out just
          # slows the failure
          :probe-timeout 5
          :message-timeout 10}
         (or extra {})))

(defn unique
  "A per-run name part, so suites do not meet yesterday's topics: the
  broker keeps the log, which is the point of the backend and the
  hazard of the suite."
  []
  (string (math/floor (* 1000 (os/clock :realtime))) "-" (math/floor (* 1000000 (math/random)))))
