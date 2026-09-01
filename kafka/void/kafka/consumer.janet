### void/kafka/consumer — a balanced group member whose offset moves
### only behind the handler (ADR-0035, SPEC.md §5.11).
###
### At-least-once is two properties and one rule:
###
###   enable.auto.commit = true          the library commits in the
###                                      background...
###   enable.auto.offset.store = false   ...but only what we STORED,
###
### and we store a message's offset after `deliver` returned. A
### handler that threw stores nothing: the crash-shaped failure
### (process dies before commit) redelivers from the broker, and the
### in-session failure is the caller's to retry — the message is
### already in its hands, and this module will not pretend a skipped
### offset is a redelivery. Both settings are forced (./config's
### `extra`): they are the semantics, not tuning.
###
### Rebalancing is deliberately librdkafka's: with no REBALANCE event
### enabled the library assigns partitions itself, and this module has
### no opinion a group protocol would want to hear. The price is
### named in ADR-0035 — between revoke and assign a group can see a
### handful of duplicates, which is what at-least-once already means.
###
### Closing is the asynchronous half (`rd_kafka_consumer_close_queue`)
### where the library has it: leaving the group is a protocol exchange,
### its events land on the same queue the pump already serves, and the
### fiber parks until `rd_kafka_consumer_closed` — nothing blocks. An
### older library falls back to the blocking close, at :stop, bounded
### by the library's own timeouts, and says so in the log.

(import void/core/log :as log)
(import ./client :as client)
(import ./librdkafka :as rk)

(def log-ns "void.kafka.consumer")

(defn- on-fetch
  ``One fetch event = one message (librdkafka's contract for FETCH).
  The event stays alive while `deliver` runs — every pointer in the
  message table is valid exactly that long, which is also why the
  offset can be stored through the message's own rkt afterwards.``
  [co]
  (fn fetch-handler [event _]
    (when-let [ptr (rk/rd_kafka_event_message_next event)]
      (def msg (rk/message ptr))
      (if (not (zero? (msg :err)))
        # a per-message error from the broker (auth, unknown topic
        # while it is being created, ...) — news, not a message; the
        # library keeps fetching
        (do
          (put-in co [:stats :errors] (inc (get-in co [:stats :errors] 0)))
          (log/warn "kafka fetch error" :ns log-ns
                    :group (co :group) :topic (msg :topic)
                    :err (rk/err-str (msg :err))))
        (do
          (put-in co [:stats :received] (inc (get-in co [:stats :received] 0)))
          ((co :deliver) (merge msg {:headers (rk/message-headers ptr)}))
          # only reached when deliver returned: the offset moves
          # behind the handler, which is the whole at-least-once
          (rk/rd_kafka_offset_store (msg :rkt) (msg :partition) (msg :offset))
          (put-in co [:stats :delivered] (inc (get-in co [:stats :delivered] 0))))))))

(defn make
  ``A consumer over property pairs, subscribed to `topics` (exact
  names, or one "^regex" — Kafka's own spelling), delivering each
  message to `deliver`:

      (make props ["user.created"] {:group "audit"}
            (fn [msg] ...))

  `msg` is {:topic :partition :offset :value :key :headers}. Returning
  stores the offset; throwing does not, and the throw travels to the
  pump's log — a caller with retry semantics of its own (the bus
  backend) wraps `deliver` and never throws out of it.``
  [properties topics opts deliver]
  (def group (get opts :group "default"))
  (def c (client/create :consumer properties
                        (bor (rk/events :fetch) (rk/events :error)
                             (rk/events :log))
                        opts))
  (def co @{:client c
            :group group
            :topics topics
            :deliver deliver
            :closed false
            :stats @{:received 0 :delivered 0 :errors 0}})
  (client/on! c :fetch (on-fetch co))
  (client/pump! c)
  (def list (rk/rd_kafka_topic_partition_list_new (length topics)))
  (each t topics
    (rk/rd_kafka_topic_partition_list_add list (string t) rk/PARTITION-UA))
  (def err (rk/rd_kafka_subscribe (c :handle) list))
  (rk/rd_kafka_topic_partition_list_destroy list)
  (unless (zero? err)
    (client/stop-pump! c)
    (client/destroy! c)
    (errorf "kafka: subscribe %q as group %q failed: %s"
            topics group (rk/err-str err)))
  (log/info "kafka consumer subscribed" :ns log-ns
            :group group :topics topics)
  co)

(defn close!
  ``Leave the group, stop the pump, release the handle. The leave is
  the polite half of at-least-once: a consumer that says goodbye hands
  its partitions over now, one that vanishes makes the group wait out
  the session timeout.``
  [co &opt timeout]
  (default timeout 10)
  (when (co :closed) (break nil))
  (put co :closed true)
  (def c (co :client))
  (if (and rk/rd_kafka_consumer_close_queue rk/rd_kafka_consumer_closed)
    (do
      (rk/take-error! (rk/rd_kafka_consumer_close_queue (c :handle) (c :queue)))
      # the leave-group exchange arrives as events on the queue the
      # pump is already serving; this fiber only watches for the end
      (def deadline (+ (os/clock :monotonic) timeout))
      (while (and (zero? (rk/rd_kafka_consumer_closed (c :handle)))
                  (< (os/clock :monotonic) deadline))
        (ev/sleep 0.05))
      (when (zero? (rk/rd_kafka_consumer_closed (c :handle)))
        (log/warn "kafka consumer did not close within its deadline" :ns log-ns
                  :group (co :group) :timeout timeout)))
    (do
      # librdkafka < 1.9: the blocking close, at :stop, said out loud
      (log/info "kafka consumer closing the blocking way — librdkafka has no consumer_close_queue"
                :ns log-ns :group (co :group))
      (rk/rd_kafka_consumer_close (c :handle))))
  (client/stop-pump! c)
  (client/destroy! c)
  nil)

(defn stats
  "The counters."
  [co]
  (table/to-struct (co :stats)))
