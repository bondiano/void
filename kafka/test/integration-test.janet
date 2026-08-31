# The :kafka bus backend against a real cluster — the scenarios
# void/bus's db conformance suite runs, re-derived for a transport
# whose log lives in a broker: fan-out by consumer group, the
# committed offset as the cursor that survives a consumer, redelivery
# in place with the counter the poison middleware reads, and the
# interop the wire format promises (a message produced by something
# that is not void is still a message).
#
# Gated on VOID_TEST_KAFKA; each run works under its own topic prefix,
# because the broker keeps the log — which is the point of the
# backend and the hazard of the suite.

(import ../test-support/paths)
(import ../test-support/broker)
(import void/core/log :as log)
(import void/bus/backend :as backend)
(import void/bus/codec :as codec)
(import void/bus/router :as router)
(import void/bus/state :as state)
(import void/kafka/config :as config)
(import void/kafka/producer :as producer)
(import void/kafka/bus :as kbus)

(log/set-level! "void" :error)
# the flaky-handler scenario throws on purpose, and the router says so
# at :error — true, intended, and noise in a green run
(log/set-level! "void.bus" :fatal)

(if-not (broker/available?)
  (do (broker/skip "kafka bus backend (integration)")
      (os/exit 0)))

# each bus topic is its own Kafka topic, and the wildcard scenarios
# meet topics born after the subscription — which a regex consumer
# only discovers on a metadata refresh, so the suite shortens the
# interval rather than waiting it out
(def kcfg (broker/config {:properties {"topic.metadata.refresh.interval.ms" "1000"}}))
(def prefix (string "void-it-" (broker/unique) "."))
(def bcfg {:prefix prefix :redeliver {:interval 0.15 :max-interval 0.5}})

(defn- await
  "Poll `pred` until it answers or `label` runs out of patience —
  broker latencies (group joins above all) are real but not worth a
  fixed sleep each."
  [label pred &opt timeout]
  (default timeout 25)
  (def deadline (+ (os/clock :monotonic) timeout))
  (while (and (not (pred)) (< (os/clock :monotonic) deadline))
    (ev/sleep 0.1))
  (unless (pred)
    (errorf "%s: not within %d s" label timeout))
  true)

(defn- fresh-broker [b &opt cfg]
  (state/make b (codec/normalize codec/json)
              (merge @{:group :default
                       :dedup {:enabled false}
                       :poison {:enabled false}
                       :retry {:enabled false}}
                     (or cfg {}))))

(defn- make-backend []
  (def p (producer/make
           (config/properties kcfg {} {"message.timeout.ms" (config/message-timeout-ms kcfg)})
           {:library (get kcfg :library) :timeout (get kcfg :message-timeout 30)}))
  (backend/normalize (kbus/store kcfg bcfg p)))

(def b (make-backend))

# -- what it promises, read back through the contract --------------------

(assert (backend/at-least-once? b) "the offset moves behind the handler")
(assert (backend/durable? b) "publish! is the broker's acknowledgement — the outbox may trust it")
(assert (backend/shared? b) "a broker is the definition of shared")
(assert (= :none (get-in b [:guarantees :ordering]))
        "and :none is the honest word for cross-partition order (ADR-0035)")
(assert (b :encoded?) "bytes on the wire, so a codec must produce some")

# -- publish, then consume from the beginning of the log -----------------

(def seen @[])
(each n (router/defined) (router/forget! n))
(router/define! :collect {:topic :it/*} {:fn (fn [m] (array/push seen (m :payload)))})

(def br (fresh-broker b))
(with-dyns [state/broker-dyn br]
  (state/publish :it/one {:n 1})
  (state/publish :it/two {:n 2})
  (state/start-consumers! br)
  (await "a new group reads the log from the beginning (auto.offset.reset=earliest)"
         |(= 2 (length seen)))
  (state/publish :it/three {:n 3})
  (await "and keeps up with what arrives after" |(= 3 (length seen)))
  # sorted, not in publish order: these are three TOPICS, and :none is
  # exactly the guarantee the backend declared across them — an
  # ordered assertion here passed once and flaked the second run,
  # which is :none demonstrating itself
  (assert (deep= @[1 2 3] (sorted (map |(get $ "n") seen))) "all three, whatever the interleaving")
  (state/stop-consumers! br))

# -- one topic, one partition: order the way Kafka does offer it ---------

(def in-order @[])
(router/forget! :collect)
(router/define! :seq {:topic :it-seq/m :group :seq}
                {:fn (fn [m] (array/push in-order (get-in m [:payload "n"])))})
(def br-seq (fresh-broker b {:group :seq}))
(with-dyns [state/broker-dyn br-seq]
  (each n [1 2 3 4] (state/publish :it-seq/m {:n n}))
  (state/start-consumers! br-seq)
  (await "one topic delivers in publish order" |(= 4 (length in-order)))
  (assert (deep= @[1 2 3 4] in-order)
          "an auto-created topic is one partition, and one partition is ordered")
  (state/stop-consumers! br-seq))

# -- the committed offset is the cursor, and it survives -----------------

(def resumed @[])
(router/forget! :seq)
(router/define! :resume {:topic :it/*} {:fn (fn [m] (array/push resumed (m :payload)))})
(def br2 (fresh-broker b))
(with-dyns [state/broker-dyn br2]
  (state/start-consumers! br2)
  (state/publish :it/four {:n 4})
  (await "a restarted consumer resumes at its committed offset" |(= 1 (length resumed)))
  # the wait above already proves the point: had the group replayed,
  # :it/one..three would have arrived first and the length would be 4
  (assert (= 4 (get (first resumed) "n"))
          "rather than replaying what the first consumer acknowledged")
  (state/stop-consumers! br2))

# -- fan-out: a second group reads the whole log -------------------------

(def audit @[])
(router/forget! :resume)
(router/define! :audit-all {:topic :it/* :group :audit}
                {:fn (fn [m] (array/push audit (m :topic)))})
(def br3 (fresh-broker b))
(with-dyns [state/broker-dyn br3]
  (state/start-consumers! br3)
  (await "a new group reads everything — fan-out is the difference from a queue"
         |(<= 4 (length audit)))
  (state/stop-consumers! br3))

# -- a nack redelivers in place, with the counter ------------------------

(def attempts @[])
(each n (router/defined) (router/forget! n))
(var fail? true)
(router/define! :flaky {:topic :it-flaky/one :group :flaky}
                {:fn (fn [m]
                       (array/push attempts (get-in m [:meta :redelivery] 0))
                       (when fail? (error "not yet")))})
(def br4 (fresh-broker b {:group :flaky}))
(with-dyns [state/broker-dyn br4]
  (state/publish :it-flaky/one {:n 1})
  (state/start-consumers! br4)
  (await "a message whose handler threw comes back" |(<= 2 (length attempts)))
  (assert (= 0 (first attempts)) "the first delivery is not a redelivery")
  (assert (pos? (last attempts)) "and a redelivery knows how often it has been tried")
  (set fail? false)
  (await "once it succeeds it stops coming back"
         (fn []
           (when fail? (error "unreachable"))
           # settled: no new attempts for a while
           (def n (length attempts))
           (ev/sleep 0.6)
           (= n (length attempts))))
  (state/stop-consumers! br4))

# -- interop: a foreign producer's message is still a message ------------
#
# Raw bytes onto the same Kafka topic a handler consumes, with no
# void-id and no void-meta: the id is synthesized from the message's
# coordinates and the payload decodes alone — the wire format's
# promise (ADR-0035), tested from the outside in.

(def foreign @[])
(each n (router/defined) (router/forget! n))
(router/define! :foreign {:topic :it-ext/raw :group :foreign}
                {:fn (fn [m] (array/push foreign m))})
(def br5 (fresh-broker b {:group :foreign}))
(with-dyns [state/broker-dyn br5]
  # through the backend once, so the topic exists before the raw bytes
  (state/publish :it-ext/raw {"kind" "ours"})
  (state/start-consumers! br5)
  (await "the enveloped message arrives" |(= 1 (length foreign)))
  # now the foreign one: a bare producer, no headers
  (def raw (producer/make
             (config/properties kcfg {} {"message.timeout.ms" "10000"})
             {:timeout 10}))
  (producer/produce! raw {:topic (kbus/kafka-topic prefix :it-ext/raw)
                          :value `{"kind":"theirs"}`})
  (producer/close! raw 5)
  (await "and so does the foreign one" |(= 2 (length foreign)))
  (def m (get foreign 1))
  (assert (= "theirs" (get-in m [:payload "kind"])) "its payload decodes alone")
  (assert (string/find "@" (m :id)) "its id is its coordinates")
  # the only meta it has is what the framework's own middleware put
  # there on arrival (a correlation id) — nothing pretended to have
  # crossed the wire
  (assert (nil? (get (m :meta) :redelivery)))
  (assert (nil? (get (m :meta) :traceparent)))
  (state/stop-consumers! br5))

# -- one reader per group ------------------------------------------------
#
# Two consumers of one group split partitions; a single-partition
# topic therefore delivers each message exactly once between them.

(def counted @{})
(each n (router/defined) (router/forget! n))
(router/define! :count-once {:topic :it-once/one :group :leased}
                {:fn (fn [m] (put counted (get-in m [:payload "n"])
                                  (inc (get counted (get-in m [:payload "n"]) 0))))})
(def br6 (fresh-broker b {:group :leased}))
(def br7 (fresh-broker b {:group :leased}))
(with-dyns [state/broker-dyn br6]
  (state/start-consumers! br6)
  (with-dyns [state/broker-dyn br7]
    (state/start-consumers! br7))
  (state/publish :it-once/one {:n 1})
  (await "two consumers of one group deliver the message once between them"
         |(= 1 (get counted 1 0)))
  (ev/sleep 1)
  (assert (= 1 (get counted 1 0)) "exactly once, not once each")
  (with-dyns [state/broker-dyn br7] (state/stop-consumers! br7))
  (state/stop-consumers! br6))

# -- stats say what happened ---------------------------------------------

(def s ((b :stats)))
(assert (<= 7 (s :published)) "every publish counted")
(assert (pos? (s :delivered)))
(assert (pos? (s :redelivered)) "the flaky handler's retries are visible")

((b :close))
(each n (router/defined) (router/forget! n))
(print "kafka bus backend integration: OK")
