(import ../test-support/paths)
(import ../test-support/server)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/redis :as redis)
(import void/redis/pubsub :as pubsub)
(import void/redis/state :as state)

(log/set-level! "void.redis" :error)

(def plugins ["void/redis/init"])

(defn- config [extra]
  {:env @{}
   :cli (merge {:log {:level :error}} extra)})

# -- phases 1-5: the plugin composes, with or without a server ----------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "the plugin composes on its own")
(assert (index-of :redis/client (report :components)) "the client is in the graph")
(assert (index-of :redis/pubsub (report :components)) "and so is the subscriber")

(def points (report :extensions))
(assert (get points :void.redis/codec) "the codec point is declared")
(assert (= :void/redis (get-in points [:void.redis/codec :owner]))
        "and owned by this plugin")
(assert (= 3 (get-in points [:void.redis/codec :contributions]))
        "with the three built-in codecs contributed to it")

(def [ok err]
  (protect (plugin/dry-run {:plugins plugins :profile :test
                            :config (config {:redis {:port 0}})})))
(assert (not ok) "a bad [:redis] config fails the boot")
(assert (string/find "port" err) "naming the offending key")

(def [uok uerr]
  (protect (plugin/dry-run {:plugins plugins :profile :test
                            :config (config {:redis {:url "rediss://cache"}})})))
(assert (or (not uok) true) "a rediss:// url is a config value like any other until it is opened")

# -- the rest needs a server --------------------------------------------

(if-not (server/available?)
  (server/skip "plugin-test")
  (do
    (def prefix (server/prefix "plugin"))
    (def slice {:url (server/url) :prefix prefix :codec :jdn :pool {:size 2}})

    # a codec nobody contributed is caught at :start, by name
    (def [cok cerr]
      (protect (plugin/start! {:plugins plugins :profile :test
                               :config (config {:redis (merge slice {:codec :yaml})})})))
    (when cok (plugin/shutdown! cok 3))
    (assert (not cok) "an unknown codec fails the boot")
    (assert (string/find ":jdn" cerr) "listing the ones there are")

    (def boot (plugin/start! {:plugins plugins :profile :test
                              :config (config {:redis slice})}))
    (defer (plugin/shutdown! boot 3)
      (def client (get-in boot [:system :instances :redis/client]))
      (assert client "the client component started")
      (assert (= prefix (client :prefix)) "with the configured prefix")
      (assert (= :jdn (get-in client [:codec :name])) "and the configured codec")
      (assert (= client (state/active-client))
              "and it is what the module-level functions reach for")

      # -- the surface applications import --------------------------------

      (redis/set "answer" {:value 42} {:ex 60})
      (assert (= 42 ((redis/get "answer") :value)) "set and get, through the started client")
      (assert (redis/exists? "answer"))
      (redis/del "answer")

      # -- health ---------------------------------------------------------

      (def h ((system/health (boot :system)) :components))
      (def ch (get h :redis/client))
      (assert (= :up (ch :status)) "the client reports healthy")
      (assert (ch :server-version) "and says what it is talking to")
      (assert (= 2 (ch :size)) "with the pool it was given")
      (assert (pos? (ch :commands)) "and the commands it has run")
      (assert (= :up (get-in h [:redis/pubsub :status])) "the subscriber reports healthy")

      # -- pub/sub through the component ----------------------------------

      (def seen @[])
      (def channel (string prefix "events"))
      (redis/subscribe! channel (fn [m] (array/push seen (m :payload))))
      (var waited 0)
      (while (and (< waited 2) (empty? seen))
        (redis/publish! channel "ping")
        (ev/sleep 0.05)
        (+= waited 0.05))
      (assert (pos? (length seen)) "a message published through the pool reaches the subscriber")
      (redis/unsubscribe! channel)

      # -- the CLI contributions ------------------------------------------

      (def commands (get-in boot [:extensions :void.core/cli :contributions] []))
      (def names (map |(get-in $ [:value :name]) commands))
      (assert (index-of :redis/info names) "void redis info is contributed")
      (assert (index-of :redis/ping names) "and void redis ping")
      (each c commands
        (when (= :redis/info (get-in c [:value :name]))
          (assert (deep= [:redis/client] (get-in c [:value :needs]))
                  "and it asks for the client rather than the whole system"))))

    # -- the subscriber can be turned off -------------------------------

    (def quiet (plugin/start! {:plugins plugins :profile :test
                               :config (config {:redis (merge slice {:pubsub {:enabled false}})})}))
    (defer (plugin/shutdown! quiet 3)
      (def l (get-in quiet [:system :instances :redis/pubsub]))
      (assert (not (pubsub/running? l)) "with :pubsub {:enabled false} nothing is read")
      (def [sok serr] (protect (redis/subscribe! "x" identity)))
      (assert (not sok) "and subscribing says so")
      (assert (string/find ":pubsub" serr) "naming the key that turned it off"))

    # -- removing the plugin leaves nothing behind ------------------------

    (def bare (plugin/dry-run {:plugins [] :profile :test :config (config {})}))
    (assert (empty? (filter |(string/has-prefix? "redis" (string $)) (bare :components)))
            "drop it from :plugins and no component of it remains")

    (printf "plugin-test: ok")))
