# Is there a redis to test the redis-backed store against?
#
# Everything that can be tested without a server is (the key algebra,
# the store contract, the memory store, the funnel, the decorator, the
# plugin's declarations), and it runs everywhere. The store that talks
# to redis needs a real one, and rather than guess at one — or start
# one — the suite asks for it by name, exactly as void/redis's own
# suite does:
#
#     VOID_TEST_REDIS="redis://127.0.0.1:6379/9" jpm test
#
# Tests never FLUSHDB: the database named may be someone's. Every
# suite works under a prefix of its own and takes its keys away
# afterwards.

(import void/redis/codec :as rcodec)
(import void/redis/config :as rconfig)
(import void/redis/pool :as rpool)
(import void/redis/state :as redis)

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
  "A key prefix nothing else is using: the suite name and this process."
  [suite]
  (string "void-test:cache:" suite ":" (os/getpid) ":"))

(defn with-client*
  ``Run (f client) against the configured server under this suite's
  own key prefix, with the redis client bound — no plugin bootstrap
  behind it, which is what makes the store testable on its own.``
  [suite f]
  (def slice {:url (url) :prefix (prefix suite)})
  (def client @{:pool (rpool/make (rconfig/options slice) (rconfig/pool-options slice))
                :codec rcodec/raw
                :prefix (slice :prefix)
                :retry true
                :conn-opts (rconfig/options slice)})
  (defer (rpool/close-all! (client :pool))
    (with-dyns [redis/client-dyn client]
      (defer (each k (redis/call ["KEYS" (string (slice :prefix) "*")])
               (redis/call ["DEL" k]))
        (f client)))))
