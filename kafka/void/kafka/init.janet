### void/kafka — Kafka through librdkafka's event API.
###
### librdkafka runs its own threads either way; what this package
### adds is the integration that keeps them out of Janet: the library
### parks its news on an event queue, tells us through a pipe's fd
### that there is some, and one fiber per client drains it —
### `void/fdwait` on the fd, `rd_kafka_queue_poll` with timeout 0, no
### callback ever crossing a VM boundary and no call ever blocking
### the loop. What each piece does:
###
###   ./librdkafka  the ffi surface, the two struct layouts, the pipe
###   ./config      [:kafka] -> the library's own property list
###   ./client      one handle: conf, queue, pipe, pump, boot probe
###   ./producer    produceva + delivery reports; publish is confirmed
###   ./consumer    a group member whose offset moves behind the handler
###   ./bus         void/kafka-bus — the :kafka `:void.bus/backend`
###
### Two plugins, the void/cache — void/cache-redis split: this one
### owns [:kafka] (brokers, properties, the client component for an
### application that talks to Kafka directly); void/kafka-bus puts
### the bus on it. The bus backend builds its OWN producer rather
### than borrowing this component's — the component graph promises no
### order between :kafka/client and :bus/broker, and a handle shared
### across an order nobody promised is a bug on some Tuesday. Two
### handles is the stated price, and each is a few OS threads — said
### here the way void/db-mysql says what a pool costs.
###
###     (void/run! {:plugins [:void/bus :void/kafka :void/kafka-bus ...]})
###     # config/prod.janet
###     {:bus {:backend :kafka}
###      :kafka {:brokers ["broker-1:9092" "broker-2:9092"]
###              :properties {"sasl.mechanism" "SCRAM-SHA-256" ...}}}

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./client :as client)
(import ./config :as config)
(import ./consumer :as consumer)
(import ./librdkafka :as librdkafka)
(import ./producer :as producer)

(def log-ns "void.kafka")

# -- public surface ------------------------------------------------------

(def Config "Schema of the [:kafka] config slice." config/Config)
(def defaults "Defaults of the [:kafka] slice — empty, and config/defaults says why." config/defaults)
(def fallbacks "See config/fallbacks — what a key falls back to." config/fallbacks)

(def library-available? "See librdkafka/available? — opened in this process?" librdkafka/available?)
(def library-version "See librdkafka/version." librdkafka/version)

(def make-producer "See producer/make — a producer over property pairs." producer/make)
(def make-consumer "See consumer/make — a group member over property pairs." consumer/make)

# -- the current client --------------------------------------------------

(var current
  "The started :kafka/client component's value — what the module-level
  produce!/consume! reach for, the way void/db-mysql's current does."
  nil)

(defn- client-now []
  (or current
      (error "void/kafka is not started — no :kafka/client component")))

(defn produce!
  ``Produce through the started client:

      (kafka/produce! "audit.log" bytes)
      (kafka/produce! "audit.log" bytes {:key id :headers {...} :wait? false})

  Confirmed by default (parked until the broker's delivery report;
  see ./producer). This is the raw client — a topic here is a Kafka
  topic name, not a bus keyword, and nobody envelopes anything.``
  [topic value &opt opts]
  (default opts {})
  (producer/produce! ((client-now) :producer)
                     (merge opts {:topic topic :value value})))

(defn consume!
  ``Start a consumer through the started client's configuration:

      (kafka/consume! {:group "importer" :topics ["their.topic"]}
                      (fn [msg] ...))

  `msg` is {:topic :partition :offset :value :key :headers}; returning
  stores the offset, throwing does not (./consumer). For handlers on
  bus topics with middleware and hot reload, compose void/kafka-bus
  and use `defhandler` instead — this is the primitive for reading
  topics that are not void's.``
  [opts deliver]
  (def cfg ((client-now) :cfg))
  (def gid (get opts :group "default"))
  (def co (consumer/make
            (config/properties cfg
                               {"auto.offset.reset" "earliest"}
                               {"group.id" gid
                                "enable.auto.commit" "true"
                                "enable.auto.offset.store" "false"})
            (get opts :topics [])
            {:group gid :library (get cfg :library)}
            deliver))
  (array/push ((client-now) :consumers) co)
  co)

(def close-consumer! "See consumer/close! — leave the group and release the handle." consumer/close!)

# -- the client component ------------------------------------------------

(def client-component
  (system/component :kafka/client
    :doc "The Kafka client an application produces and consumes
    through directly: one producer handle (created at :start, which is
    also when the boot probe runs — DescribeCluster through the event
    API, so an unreachable cluster fails the boot rather than the
    first message), and a factory for group consumers."
    :config {:key :kafka :schema Config}
    :start
    (fn start [_ cfg]
      (def p (producer/make
               (config/properties cfg {}
                                  {"message.timeout.ms"
                                   (config/message-timeout-ms cfg)})
               {:library (get cfg :library)
                :timeout (get cfg :message-timeout 30)}))
      (def probed
        (if (config/verify? cfg)
          (client/probe! (p :client) (config/brokers cfg)
                         (config/probe-timeout cfg))
          :off))
      (def described (config/describe cfg))
      (log/info "kafka client ready" :ns log-ns
                :library (librdkafka/version) :probe probed
                ;(mapcat |[$ (get described $)] (sorted (keys described))))
      (def value @{:producer p :cfg cfg :consumers @[] :probe probed})
      (set current value)
      value)
    :stop
    (fn stop [v]
      (set current nil)
      (each co (v :consumers) (protect (consumer/close! co)))
      (producer/close! (v :producer)))
    :health
    (fn health [v]
      (def last-err (get-in v [:producer :client :last-error]))
      (merge {:status :up
              :probe (v :probe)
              :producer (producer/stats (v :producer))
              :consumers (length (v :consumers))}
             (if last-err {:last-error (last-err :text)} {})))))

# -- CLI -----------------------------------------------------------------

(plugin/contribute! :void.core/cli
  {:name :kafka/info
   :read-only? true
   :doc "Show what the Kafka client is connected to: void kafka info"
   :needs [:kafka/client]
   :fn (fn cli-info [v & _]
         (def cfg (v :cfg))
         (printf "library     %s (%s)" (librdkafka/version)
                 (or librdkafka/library-path "?"))
         (printf "brokers     %s" (config/brokers cfg))
         (printf "boot probe  %s" (string (v :probe)))
         (def s (producer/stats (v :producer)))
         (each k [:produced :delivered :failed :outq :waiting]
           (printf "%-11s %d" (string k) (get s k 0)))
         (unless (empty? librdkafka/missing)
           (printf "missing     %s (an older librdkafka — features degrade as documented)"
                   (string/join librdkafka/missing " "))))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/kafka
  :doc "Kafka through librdkafka's event API: the library's news arrives on an fd one fiber sleeps on (void/fdwait), produce is confirmed by the broker's delivery report, and a consumer's offset moves only behind its handler. The raw client — the bus over it is void/kafka-bus."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :kafka
  :config-schema Config
  :config-defaults defaults
  :components [client-component])
