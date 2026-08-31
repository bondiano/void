# The declarations, and what composes with them. Phases 1-5 of the
# kernel need no librdkafka and no cluster — a plugin that is merely
# loaded must not require Kafka to exist (`void routes` on a laptop,
# the dry-run gate in CI) — so everything down to `plugin/dry-run`
# runs everywhere, and only `plugin/start!` at the bottom waits for a
# broker.

(import ../test-support/paths)
(import ../test-support/broker)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/kafka/init :as kafka)
(import void/kafka/bus :as kbus)

(log/set-level! "void" :error)

(def plugins ["void/bus/init" "void/kafka/init" "void/kafka/bus"])

(defn- config [extra]
  {:env @{}
   :cli (merge {:log {:level :error}} extra)})

# -- phases 1-5, with no client library ----------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test
                             :config (config {:bus {:backend :kafka}})}))
(assert (report :ok) "the bus and both kafka plugins compose")
(assert (index-of :kafka/client (report :components)) "the client is in the graph")
(assert (index-of :bus/broker (report :components)) "next to the broker")

(def [bad-timeout _]
  (protect (plugin/dry-run {:plugins plugins :profile :test
                            :config (config {:kafka {:message-timeout -1}})})))
(assert (not bad-timeout) "a config value outside the schema fails before anything starts")

(def [bad-prefix _]
  (protect (plugin/dry-run {:plugins plugins :profile :test
                            :config (config {:kafka-bus {:prefix 5}})})))
(assert (not bad-prefix) "and so does a prefix that is not a string")

# -- the manifest --------------------------------------------------------

(assert (empty? kafka/defaults)
        (string "the slice declares no kernel-merged defaults: a merged "
                "default is indistinguishable from a choice (the "
                "void/db-mysql argument), and the real values live in "
                "fallbacks"))
(assert (= "127.0.0.1:9092" (kafka/fallbacks :brokers)) "which are a real localhost")
(assert (not (kafka/library-available?))
        (string "and none of the above opened librdkafka — the client opens "
                "it at :start and nowhere else, which is what lets this "
                "file run on a machine that has no Kafka at all"))

# -- against a real cluster ----------------------------------------------

(if-not (broker/available?)
  (do (broker/skip "kafka plugin (start!)")
      (print "kafka plugin-test ok")
      (os/exit 0)))

(def topic (string "void.plugin." (broker/unique)))

(def boot (plugin/start! {:plugins ["void/kafka/init"] :profile :test
                          :config (config {:kafka (broker/config)})}))

(defer (plugin/shutdown! boot 15)
  (def v (get-in boot [:system :instances :kafka/client]))
  (assert v "the component started")
  (assert (= :ok (v :probe)) "and the boot probe saw the cluster answer")

  (def health ((get-in boot [:system :components :kafka/client :health]) v))
  (assert (= :up (health :status)))

  # the raw client round trip: no envelope, no bus — bytes, a key, a
  # header, and the broker's coordinates back
  (def where (kafka/produce! topic "raw-bytes"
                             {:key "k1" :headers {"h" "v"}}))
  (assert (number? (where :offset)) "a confirmed produce returns the broker's coordinates")

  (def got (ev/chan 8))
  (def co (kafka/consume! {:group (string "g" (broker/unique)) :topics [topic]}
                          (fn [msg] (ev/give got msg))))
  (def [ok msg] (protect (ev/with-deadline 20 (ev/take got))))
  (assert ok "the message came back within the join-and-fetch budget")
  (assert (= "raw-bytes" (msg :value)))
  (assert (= "k1" (msg :key)) "the key travelled")
  (assert (= "v" (get-in msg [:headers "h"])) "and so did the header")
  (assert (= topic (msg :topic)))
  (kafka/close-consumer! co))

(print "kafka plugin-test ok")
