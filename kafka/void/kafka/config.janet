### void/kafka/config — from the [:kafka] config slice to the
### property list librdkafka is configured with (ADR-0035, SPEC.md
### §5.11).
###
### librdkafka is configured entirely through string properties
### ("bootstrap.servers", "acks", ...), of which there are several
### hundred. This module does not rename them: the handful the plugin
### has an opinion about get config keys and stated fallbacks, and
### everything else travels through [:kafka :properties] under the
### library's own names — an escape hatch that ages better than a
### schema chasing librdkafka's CONFIGURATION.md.
###
### Two kinds of property never make it through:
###
###   * the ones the integration owns. The event machinery only works
###     with librdkafka's callbacks unset and its events routed to a
###     queue; a [:properties] entry that would repoint them is a boot
###     error naming this file, not a silent override.
###   * on a consumer the bus runs, the two offset settings that ARE
###     the at-least-once semantics (./consumer): enable.auto.commit
###     and enable.auto.offset.store. Overriding them would change
###     what a nack means, which is the backend's declared guarantee
###     and not a tuning knob.
###
### Nothing here loads the library: this module is pure data, testable
### without a broker.

(def Config
  "Schema of the [:kafka] config slice."
  {:brokers [:optional [:union :string [:vector :string]]]
   :client-id [:optional :string]
   :library [:optional :string]

   # the boot probe (ADR-0035): DescribeCluster through the event API,
   # parked, bounded — the keeper-connection bargain for a client that
   # has no "connect" moment
   :verify [:optional :boolean]
   :probe-timeout [:optional [:number {:min 0}]]

   # how long a produced message may wait for its delivery report
   # before the report says it failed — the bound on publish! (seconds
   # here, milliseconds on the wire)
   :message-timeout [:optional [:number {:min 0}]]

   # librdkafka's own property names, verbatim
   :properties [:optional [:map-of :string [:union :string :number :boolean]]]})

(def defaults
  ``Defaults of the [:kafka] slice — empty on purpose, the
  void/db-mysql argument: a kernel-merged default is
  indistinguishable from a choice, and this module resolves
  precedence itself (config key beats [:properties] beats fallbacks).``
  {})

(def fallbacks
  ``What a key falls back to when nothing says otherwise. A real
  localhost, not "whatever resolves": the machine this matters on is
  the laptop running one broker in a container.

  30 s for the message timeout, not the library's 300: the report is
  what publish! parks on, and five minutes is not a wait — it is a
  request that got lost with a fiber attached.``
  {:brokers "127.0.0.1:9092"
   :verify true
   :probe-timeout 10
   :message-timeout 30})

(def reserved
  ``Properties the integration owns, and why a config that sets them
  is refused rather than obeyed (ADR-0035): the event pump is the only
  consumer of the library's news, and these are the knobs that would
  point the news elsewhere.``
  ["enabled_events"           # set by rd_kafka_conf_set_events
   "log.queue"                # logs must come out as events, not callbacks
   "background_event_cb"      # a callback on the library's own thread
   "dr_msg_cb" "dr_cb"        # delivery reports arrive as events
   "consume_cb" "rebalance_cb" "offset_commit_cb"
   "error_cb" "throttle_cb" "stats_cb" "log_cb" "socket_cb"
   "connect_cb" "closesocket_cb" "open_cb" "resolve_cb"])

(defn brokers
  "The bootstrap.servers string for a slice."
  [cfg]
  (def b (get cfg :brokers (fallbacks :brokers)))
  (if (indexed? b) (string/join b ",") (string b)))

(defn- property-value
  # librdkafka reads strings; true/false spell themselves
  [v]
  (cond
    (boolean? v) (if v "true" "false")
    (string v)))

(defn properties
  ``The property list for a slice, as pairs in a stable order:
  computed base first, then [:properties] (which wins over the base —
  an operator who spells a property the library's way means it), with
  `extra` last — what the caller (a producer, a consumer, the bus
  backend) cannot let anyone override.

  A reserved property is an error whichever map it is in.``
  [cfg &opt base extra]
  (default base {})
  (default extra {})
  (def given (get cfg :properties {}))
  (each name reserved
    (when (or (get given name) (get base name))
      (errorf (string "kafka: property %q belongs to the event machinery "
                      "(ADR-0035) and cannot be configured — see "
                      "void/kafka/config") name)))
  (each name (keys extra)
    (when (get given name)
      (errorf (string "kafka: property %q is set by this component to %q and "
                      "[:kafka :properties] may not override it — it is the "
                      "semantics, not a tuning knob")
              name (get extra name))))
  (def out @{})
  (put out "bootstrap.servers" (brokers cfg))
  (when-let [id (get cfg :client-id)] (put out "client.id" id))
  (eachp [k v] base (put out k (property-value v)))
  (eachp [k v] given (put out k (property-value v)))
  (eachp [k v] extra (put out k (property-value v)))
  # pairs sorted by name: the order properties are applied in should
  # not depend on table iteration order between janet builds
  (sorted-by first (pairs out)))

(defn message-timeout-ms
  "The delivery-report bound, in the milliseconds librdkafka speaks."
  [cfg]
  (math/floor (* 1000 (get cfg :message-timeout (fallbacks :message-timeout)))))

(defn probe-timeout
  "The boot probe's bound, in seconds."
  [cfg]
  (get cfg :probe-timeout (fallbacks :probe-timeout)))

(defn verify?
  "Should :start prove the cluster answers before anything depends on
  it?"
  [cfg]
  (not= false (get cfg :verify)))

(defn describe
  ``The client as a handful of values for a log line or a health
  report — no secret among them (a sasl.password lives in
  [:properties] and stays there).``
  [cfg]
  {:brokers (brokers cfg)
   :client-id (get cfg :client-id)
   :verify (verify? cfg)
   :message-timeout (get cfg :message-timeout (fallbacks :message-timeout))})
