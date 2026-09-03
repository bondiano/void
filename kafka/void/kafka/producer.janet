### void/kafka/producer — produceva in, delivery reports out.
###
### `produce!` has two modes, and the difference between them is the
### whole reason this package exists twice over:
###
###   * confirmed (the default): the fiber parks until the broker's
###     delivery report arrives, and a report that says "failed" is an
###     error at the call site. This is what lets the bus backend say
###     `:durable true` and mean it — the outbox forwarder marks a row
###     sent only after a call like this returns.
###   * `:wait? false`: hand the message to the library and move on.
###     Errors become counters and log lines. For the application that
###     wants a firehose and says so.
###
### The correlation is a u64 token in the message's opaque slot: it
### rides out with produceva and comes back in the report's `_private`
### field, never dereferenced by anyone. Tokens are minted from a
### counter, and 2^53 messages (where a janet number would stop
### counting cleanly) is beyond this process's lifetime.

(import void/core/log :as log)
(import ./client :as client)
(import ./librdkafka :as rk)

(def log-ns "void.kafka.producer")

(defn- on-dr
  ``The delivery-report handler: one event carries a batch. A report
  someone is parked on resolves their channel; a fire-and-forget
  report becomes a counter, and a failed one a log line — at :warn,
  because the caller chose not to be told directly.``
  [p]
  (fn dr-handler [event _]
    (def n (scan-number (string (rk/rd_kafka_event_message_count event))))
    (repeat n
      (when-let [ptr (rk/rd_kafka_event_message_next event)]
        (def msg (rk/message ptr))
        (def waiter (get-in p [:waiters (msg :token)]))
        (put-in p [:waiters (msg :token)] nil)
        (if waiter
          (ev/give waiter msg)
          (if (zero? (msg :err))
            (put-in p [:stats :delivered] (inc (get-in p [:stats :delivered] 0)))
            (do
              (put-in p [:stats :failed] (inc (get-in p [:stats :failed] 0)))
              (log/warn "kafka delivery failed (fire-and-forget)" :ns log-ns
                        :topic (msg :topic) :err (rk/err-str (msg :err))))))))))

(defn make
  ``A producer over property pairs (./config's `properties`).

      (make props {:library path :timeout 30})

  `:timeout` is the delivery-report bound in seconds — it must match
  the message.timeout.ms the properties carry, and ./init derives both
  from the same config key so it cannot not.``
  [properties &opt opts]
  (default opts {})
  (def c (client/create :producer properties
                        (bor (rk/events :dr) (rk/events :error)
                             (rk/events :log)
                             (rk/events :describe-cluster-result))
                        opts))
  (def p @{:client c
           :timeout (get opts :timeout 30)
           :next-token 1
           # token -> the channel a confirmed produce! parks on
           :waiters @{}
           :stats @{:produced 0 :delivered 0 :failed 0}})
  (client/on! c :dr (on-dr p))
  (client/pump! c)
  p)

(defn- take-token! [p]
  (def t (p :next-token))
  (put p :next-token (inc t))
  t)

(defn produce!
  ``One message out:

      (produce! p {:topic "user.created" :value bytes
                   :key bytes :headers {"void-id" id}})

  Confirmed by default — returns {:partition :offset} from the
  broker's report, throws when the report says failed (delivery
  timeout included: message.timeout.ms guarantees the report comes,
  one way or the other). `:wait? false` returns nil immediately.

  A nil `:key` lets the partitioner spread; a key routes every message
  with the same bytes to the same partition, which is the only
  ordering Kafka has to offer.``
  [p msg]
  (def c (p :client))
  (def topic (string (msg :topic)))
  (def value (get msg :value ""))
  (def key (get msg :key))
  (def headers (get msg :headers {}))
  (def wait? (not= false (get msg :wait?)))
  (def token (when wait? (take-token! p)))

  # TOPIC VALUE MSGFLAGS [KEY] [OPAQUE] HEADER*
  (def n (+ 3 (if key 1 0) (if wait? 1 0) (length headers)))
  (def vus (rk/vu-buffer n))
  (var i 0)
  (rk/vu-topic! vus i topic) (++ i)
  (rk/vu-value! vus i value) (++ i)
  (rk/vu-msgflags! vus i rk/MSG-F-COPY) (++ i)
  (when key (rk/vu-key! vus i key) (++ i))
  (when wait? (rk/vu-opaque! vus i token) (++ i))
  # header names sorted: the wire order of our own headers should not
  # depend on table iteration order
  (each name (sorted (keys headers))
    (rk/vu-header! vus i name (get headers name)) (++ i))

  (def answer (when wait? (ev/chan 1)))
  (when wait? (put-in p [:waiters token] answer))
  (def err (rk/take-error! (rk/rd_kafka_produceva (c :handle) vus n)))
  (when err
    (when wait? (put-in p [:waiters token] nil))
    (errorf "kafka: produce to %q refused: %s (%s)"
            topic (err :text) (rk/err-str (err :code))))
  (put-in p [:stats :produced] (inc (get-in p [:stats :produced] 0)))

  (when wait?
    # the report is bounded by message.timeout.ms; the margin covers
    # the trip from the library's queue to this fiber. Missing the
    # deadline anyway means the pump is not running — a bug, and one
    # worth an error that says so rather than a park without end
    (def [ok report]
      (protect (ev/with-deadline (+ (p :timeout) 5) (ev/take answer))))
    (unless ok
      (put-in p [:waiters token] nil)
      (errorf "kafka: no delivery report for %q within %d s — the event pump is not serving this producer"
              topic (math/floor (+ (p :timeout) 5))))
    (if (zero? (report :err))
      {:partition (report :partition) :offset (report :offset)}
      (do
        (put-in p [:stats :failed] (inc (get-in p [:stats :failed] 0)))
        (errorf "kafka: delivery to %q failed: %s"
                topic (rk/err-str (report :err)))))))

(defn flush!
  ``Wait (parked, not blocked — rd_kafka_flush would block the loop)
  for the library to finish what it holds, up to `timeout` seconds.
  Returns what is left, which a clean shutdown wants to see as 0 and
  a deadline-hit reports truthfully.``
  [p &opt timeout]
  (default timeout 10)
  (def deadline (+ (os/clock :monotonic) timeout))
  (while (and (pos? (client/outq-len (p :client)))
              (< (os/clock :monotonic) deadline))
    (ev/sleep 0.05))
  (client/outq-len (p :client)))

(defn close!
  ``Flush, stop the pump, release the handle. The flush is best
  effort with its remainder logged: at :stop the alternative to
  losing a queued message is holding the process, and the bounded
  wait IS the policy.``
  [p &opt timeout]
  (def left (flush! p timeout))
  (when (pos? left)
    (log/warn "kafka producer closed with messages still queued" :ns log-ns
              :left left))
  # anyone still parked learns the truth rather than the timeout
  (eachp [token chan] (p :waiters)
    (ev/give chan {:err (rk/error-codes :msg-timed-out)
                   :partition -1 :offset -1 :topic nil :token token}))
  (client/stop-pump! (p :client))
  (client/destroy! (p :client))
  nil)

(defn stats
  "The counters, plus what the library still holds."
  [p]
  (merge (table/to-struct (p :stats))
         {:outq (client/outq-len (p :client))
          :waiting (length (p :waiters))}))
