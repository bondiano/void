# Is there a redis to test against?
#
# Everything that can be tested without a server is (the wire format,
# the config slice, the codecs, the plugin's declarations), and it runs
# everywhere. The rest needs a real server, and rather than guess at
# one — or start one — the suite asks for it by name:
#
#     VOID_TEST_REDIS="redis://127.0.0.1:6379/9" jpm test
#
# CI sets it against a service container, so the integration tests are
# a real gate there. On a laptop without one they announce themselves
# as skipped instead of failing — a missing server is not a broken
# client, and a suite that cannot be run at all is a suite nobody runs.
#
# Tests never FLUSHDB: the database named may be someone's, and a test
# suite that deletes a developer's keys is a test suite they run once.
# Every suite works under a prefix of its own (`prefix`) and takes its
# own keys away afterwards (`clean!`).

(import void/redis/codec :as codec)
(import void/redis/config :as config)
(import void/redis/pool :as pool)
(import void/redis/state :as state)

(def env-var "VOID_TEST_REDIS")

(defn url
  "The configured server, or nil."
  []
  (when-let [v (os/getenv env-var)]
    (unless (empty? (string/trim v)) (string/trim v))))

(defn available?
  "Is there a server to test against?"
  []
  (not (nil? (url))))

(defn skip
  "Announce a skipped suite the way a passing one announces itself, so
  a scrolled-past CI log still says which is which."
  [suite]
  (printf "%s: SKIPPED (set %s to a redis:// url)" suite env-var)
  nil)

(defn prefix
  ``A key prefix nothing else is using: the suite name and this
  process. Two suites, or two checkouts, can share one database
  without sharing keys.``
  [suite]
  (string "void-test:" suite ":" (os/getpid) ":"))

(defn config
  "The [:redis] slice for the configured server, under this suite's
  own prefix."
  [suite &opt extra]
  (merge {:url (url) :prefix (prefix suite)} (or extra {})))

(defn clean!
  ``Delete every key this suite made. Takes the client functions as
  arguments rather than importing them, so the helper stays usable
  from a suite that is testing a different layer.``
  [scan-each del]
  (def doomed @[])
  (scan-each |(array/push doomed $) {:match "*"})
  (unless (empty? doomed) (del ;doomed))
  (length doomed))

(defn client
  ``A client value — a pool, a codec and this suite's prefix — without
  a plugin bootstrap behind it. `state/client-dyn` takes one of these,
  which is what makes every layer above the pool testable on its own.``
  [suite &opt extra]
  (def cfg (config suite extra))
  @{:pool (pool/make (config/options cfg) (config/pool-options cfg))
    :codec (get {:raw codec/raw :jdn codec/jdn :json codec/json}
                (get cfg :codec :raw))
    :prefix (get cfg :prefix "")
    :retry (not= false (get cfg :retry))
    :conn-opts (config/options cfg)})

(defn with-client*
  "Run (f client) with the client bound, and close its pool after."
  [suite extra f]
  (def c (client suite extra))
  (defer (pool/close-all! (c :pool))
    (with-dyns [state/client-dyn c] (f c))))
