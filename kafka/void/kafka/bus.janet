### void/kafka/bus — the :kafka contribution to `:void.bus/backend`
### (ADR-0035, ADR-0012, SPEC.md §5.22, ROADMAP 5).
###
### The last backend from ADR-0012's list, and the test of its claim
### that the contract was already shaped for streams with consumer
### groups. It was: a bus group IS a Kafka consumer group, ack and
### nack are already "returned" and "threw", and the one thing that
### had to be invented is the spelling of a topic.
###
### **What travels how.** The Kafka message value is the codec-encoded
### payload and nothing else, so a consumer that is not void reads it
### without knowing us; the envelope's id and encoded meta ride in
### headers (`void-id`, `void-meta`). A message that arrives WITHOUT
### those headers — a foreign producer on a topic we consume — is
### still a message: the id is synthesized from its coordinates
### (topic/partition/offset, which is what uniquely names a Kafka
### message anyway) and the meta is empty. Interop is a property of
### the wire format, in both directions.
###
### **Guarantees, honestly.** :at-least-once (the offset moves behind
### the handler — ./consumer), :durable and :shared (that is what a
### broker is; publish! returns only on the broker's acknowledgement,
### which is what lets the outbox forwarder trust it), and :ordering
### :none — Kafka orders within a partition, and the contract's
### :per-group promises publish order to the whole group, which
### partitions do not give. An application that needs order by key
### puts `:key` in the message meta; same key, same partition, same
### order.
###
### **A nack redelivers in place.** The failed message is already in
### this process's hands, so the backend re-runs the handler itself —
### backoff, `:redelivery` counter in the meta, the partition's head
### waiting behind it (order is worth more than progress, the same
### trade void/bus-db's cursor makes). The offset has not moved, so a
### crash mid-retry redelivers from the broker: a duplicate, not a
### loss. The poison middleware (on by default) is what bounds the
### loop; without it a permanently failing handler holds its partition
### and says so in the log at every attempt.

(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/bus/state :as bus-state)
(import ./client :as client)
(import ./config :as config)
(import ./consumer :as consumer)
(import ./producer :as producer)

(def log-ns "void.kafka.bus")

# -- the [:kafka-bus] slice ----------------------------------------------

(def Config
  "Schema of the [:kafka-bus] config slice."
  {# in front of every topic and group id — what keeps two
   # applications apart on a shared cluster
   :prefix [:optional :string]
   :redeliver [:optional {:interval [:optional [:number {:min 0.01}]]
                          :max-interval [:optional [:number {:min 0.01}]]}]})

(def defaults
  "Defaults of the [:kafka-bus] slice."
  {:prefix ""
   :redeliver {:interval 0.5 :max-interval 10}})

(defn- slice [cfg]
  (def d defaults)
  {:prefix (get cfg :prefix (d :prefix))
   :redeliver (merge (d :redeliver) (get cfg :redeliver {}))})

# -- topic spelling ------------------------------------------------------
#
# A bus topic is a keyword with / between segments; a Kafka topic name
# is [a-zA-Z0-9._-]. The / becomes a . and comes back, which is why a
# bus topic published through this backend may not contain a literal
# dot: :user.created and :user/created would land on the same Kafka
# topic and come back as the same keyword, and refusing the ambiguous
# spelling up front beats delivering to the wrong handler later.

(def- topic-peg
  (peg/compile ~(* (some (+ (range "az" "AZ" "09") (set "_-/"))) -1)))

(defn kafka-topic
  "A bus topic keyword as the Kafka topic name it travels on."
  [prefix topic]
  (def s (string topic))
  (unless (peg/match topic-peg s)
    (errorf (string "kafka bus backend: topic %q cannot travel — a Kafka "
                    "topic is [a-zA-Z0-9._-] and the / -> . mapping reserves "
                    "the dot (ADR-0035)") topic))
  (string prefix (string/replace-all "/" "." s)))

(defn bus-topic
  "The keyword a Kafka topic name comes back as, or nil for one
  outside our prefix — a foreign topic a consumer was pointed at
  stays addressable by its own spelling."
  [prefix name]
  (if (string/has-prefix? prefix name)
    (keyword (string/replace-all "." "/" (string/slice name (length prefix))))
    (keyword name)))

(defn- regex-quote [s]
  # the prefix alphabet is ours to keep small; the dot is the one
  # regex metacharacter in it
  (string/replace-all "." "\\." s))

(defn subscription
  ``What to subscribe for a consumer's topic hint: the exact Kafka
  names when the router's list is fully exact, else one ^regex over
  the prefix — the backend contract allows over-delivery (the router
  matches again on arrival), and Kafka's regex subscription follows
  topics that do not exist yet, which wildcard handlers want.``
  [prefix exact topics]
  (if exact
    (tuple ;(map |(kafka-topic prefix $) exact))
    [(string "^" (regex-quote prefix) ".*")]))

# -- envelopes across the wire -------------------------------------------

(def id-header "void-id")
(def meta-header "void-meta")

(defn- envelope-of
  "A fetched Kafka message as the envelope the broker hydrates."
  [prefix msg]
  (def headers (get msg :headers {}))
  @{:id (or (get headers id-header)
            # a foreign message: its coordinates are its name
            (string (msg :topic) "@" (msg :partition) ":" (msg :offset)))
    :topic (bus-topic prefix (msg :topic))
    :body (msg :value)
    :meta-body (get headers meta-header)})

# -- the backend ---------------------------------------------------------

(defn- backoff [redeliver attempt]
  (min (redeliver :max-interval)
       (* (redeliver :interval) (math/exp2 (min attempt 16)))))

(defn store
  ``The backend value over a producer and the two config slices —
  what ./backend in void/bus normalizes.``
  [kcfg bcfg p]
  (def prefix (bcfg :prefix))
  (def redeliver (bcfg :redeliver))
  (def subs @[])
  (def stats @{:published 0 :delivered 0 :redelivered 0})

  {:name :kafka
   :encoded? true
   :guarantees {:delivery :at-least-once
                :ordering :none
                :durable true
                :shared true}

   :publish!
   (fn publish [env]
     (def headers @{id-header (string (env :id))})
     (when-let [mb (get env :meta-body)] (put headers meta-header mb))
     # :key in the message meta is the partition key — the only order
     # Kafka offers, chosen by the application that needs it
     (def key (when-let [k (get-in env [:meta :key])] (string k)))
     (producer/produce! p {:topic (kafka-topic prefix (env :topic))
                           :value (get env :body "")
                           :key key
                           :headers headers})
     (put stats :published (inc (stats :published)))
     nil)

   :consume!
   (fn consume [opts deliver]
     (def group (get opts :group :default))
     (def gid (kafka-topic prefix group))
     (def names (subscription prefix (get opts :exact-topics) (get opts :topics [])))
     (def sub @{:group group :stopped false :consumer nil})
     (defn deliver-with-redelivery [msg]
       (def env (envelope-of prefix msg))
       (var attempt 0)
       (var done false)
       (while (and (not done) (not (sub :stopped)))
         (when (pos? attempt) (put env :redelivery attempt))
         (def [ok err] (protect (deliver env)))
         (if ok
           (do (set done true)
               (put stats :delivered (inc (stats :delivered)))
               (when (pos? attempt)
                 (put stats :redelivered (+ (stats :redelivered) attempt))))
           (do
             (log/warn "message handler failed — redelivering in place (the offset has not moved)"
                       :ns log-ns :group group
                       :topic (env :topic) :id (env :id) :attempt attempt
                       :err (if (string? err) err (describe err)))
             (ev/sleep (backoff redeliver attempt))
             (++ attempt))))
       # a stop mid-retry must NOT store the offset: throwing out of
       # deliver is how ./consumer is told
       (unless done (error "stopped while redelivering")))
     (def regex? (string/has-prefix? "^" (first names)))
     (put sub :consumer
          (consumer/make
            (config/properties kcfg
                               (merge
                                 {"auto.offset.reset" "earliest"}
                                 # a regex subscription only meets a topic
                                 # born after it on a metadata refresh, and
                                 # the library's default interval is five
                                 # minutes — a wildcard handler would not
                                 # see a new topic's first message for that
                                 # long. Overridable, like any base
                                 (if regex?
                                   {"topic.metadata.refresh.interval.ms" "10000"}
                                   {}))
                               {"group.id" gid
                                # the at-least-once pair (./consumer);
                                # forced, because it is the declared
                                # guarantee and not a tuning knob
                                "enable.auto.commit" "true"
                                "enable.auto.offset.store" "false"})
            names {:group gid :library (get kcfg :library)}
            deliver-with-redelivery))
     (array/push subs sub)
     sub)

   :stop!
   (fn stop [sub]
     (unless (sub :stopped)
       (put sub :stopped true)
       (when-let [co (sub :consumer)]
         (consumer/close! co)))
     nil)

   :close
   (fn close []
     (each sub subs
       (unless (sub :stopped)
         (put sub :stopped true)
         (when-let [co (sub :consumer)] (protect (consumer/close! co)))))
     (array/clear subs)
     (producer/close! p)
     nil)

   :health
   (fn health []
     (def last-err (get-in p [:client :last-error]))
     (merge {:status :up :brokers (config/brokers kcfg)}
            (if last-err {:last-error (last-err :text)} {})))

   :stats
   (fn backend-stats []
     (merge (table/to-struct stats)
            {:producer (producer/stats p)
             :groups (map |(string ($ :group)) subs)
             :consumers (map |(consumer/stats ($ :consumer))
                             (filter |($ :consumer) subs))}))})

# -- the contribution ----------------------------------------------------

(plugin/contribute! :void.bus/backend
  {:name :kafka
   :doc "Kafka through librdkafka's event API (ADR-0035): at-least-once with the offset moving behind the handler, durable because publish! returns on the broker's acknowledgement, shared because that is what a broker is. Payload travels as the message value, envelope id and meta as headers — readable by consumers that are not void."
   :make (fn make-kafka-backend [_]
           (def kcfg (bus-state/config-slice :kafka))
           (def bcfg (slice (bus-state/config-slice :kafka-bus)))
           (def p (producer/make
                    (config/properties kcfg {}
                                       {"message.timeout.ms"
                                        (config/message-timeout-ms kcfg)})
                    {:library (get kcfg :library)
                     :timeout (get kcfg :message-timeout 30)}))
           (when (config/verify? kcfg)
             (client/probe! (p :client) (config/brokers kcfg)
                            (config/probe-timeout kcfg)))
           (def described (config/describe kcfg))
           (log/info "kafka bus backend ready" :ns log-ns
                     ;(mapcat |[$ (get described $)] (sorted (keys described))))
           (store kcfg bcfg p))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/kafka-bus
  :doc "The bus over Kafka: consumer groups are Kafka's own, publish! is the broker's acknowledgement, a nack redelivers in place while the offset waits, and the payload on the wire is readable by consumers that never heard of void (ADR-0035)."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/bus ">=0.0.1" :void/kafka ">=0.0.1"}
  :config-key :kafka-bus
  :config-schema Config
  :config-defaults defaults)
