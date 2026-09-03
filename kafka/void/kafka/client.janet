### void/kafka/client — one librdkafka handle and the pump that turns its
### events into calls.
###
### The whole integration is here, and it is short: the library parks
### its news (delivery reports, fetched messages, errors) on a queue,
### `rd_kafka_queue_poll` with timeout 0 hands it over without
### blocking, and `rd_kafka_queue_io_event_enable` writes a byte into
### our pipe when the queue goes from empty to non-empty — which is
### the fd one fiber sleeps on through void/fdwait. No callback ever
### crosses into Janet, and no Janet call ever blocks on the library.
###
### The pump cannot miss a wake-up: NULL from queue_poll means the
### queue is empty, so the next event is an empty→non-empty transition,
### which is exactly when the library writes the byte. void/fdwait is
### level-triggered on top of that.
###
### Handlers are slots on the client (`:on-dr`, `:on-fetch`, ...),
### installed by ./producer and ./consumer — the pump owns dispatch
### and the lifetime of the event object, the handler owns what the
### event means. A handler is allowed to park (a consumer's handler
### does database work); the event stays alive under it, which is what
### keeps every pointer in the message table valid until the handler
### returns.

(import void/core/log :as log)
(import void/fdwait :as fdwait)
(import ./librdkafka :as rk)

(def log-ns "void.kafka")

(def- errstr-size 512)

(defn- conf!
  ``An rd_kafka_conf_t over the property pairs, with events enabled.
  On any failure the conf is destroyed here — it is only ever owned by
  us until rd_kafka_new accepts it.``
  [properties events]
  (def conf (rk/rd_kafka_conf_new))
  (def errstr (buffer/new-filled errstr-size))
  (each [name value] properties
    (unless (= rk/CONF-OK (rk/rd_kafka_conf_set conf name value errstr errstr-size))
      (def why (rk/cstr errstr))
      (rk/rd_kafka_conf_destroy conf)
      (errorf "kafka: property %q = %q: %s" name value why)))
  # spontaneous stderr from the library's own threads off — its log
  # lines become LOG events on the queue (rd_kafka_set_log_queue in
  # `create`), which is where the pump feeds them to void/core/log
  (rk/rd_kafka_conf_set conf "log.queue" "true" errstr errstr-size)
  (rk/rd_kafka_conf_set_events conf events)
  conf)

(defn create
  ``A client: the rd_kafka_t, its event queue, the pipe and the pump.

      (create :producer properties (bor (rk/events :dr) (rk/events :error))
              {:library path})

  `kind` is :producer or :consumer. The consumer's group queue is
  redirected into the polled one (`rd_kafka_poll_set_consumer`), so
  one pump serves everything the instance has to say.``
  [kind properties events &opt opts]
  (default opts {})
  (rk/load! (get opts :library))
  (def conf (conf! properties events))
  (def errstr (buffer/new-filled errstr-size))
  (def handle (rk/rd_kafka_new (if (= kind :consumer) rk/RD-KAFKA-CONSUMER rk/RD-KAFKA-PRODUCER)
                               conf errstr errstr-size))
  (unless handle
    # rd_kafka_new did not take ownership — failing to construct is
    # the one path where the conf is still ours to free
    (rk/rd_kafka_conf_destroy conf)
    (errorf "kafka: rd_kafka_new failed: %s" (rk/cstr errstr)))
  (def queue
    (if (= kind :consumer)
      (do (rk/rd_kafka_poll_set_consumer handle)
          (rk/rd_kafka_queue_get_consumer handle))
      (rk/rd_kafka_queue_get_main handle)))
  # NULL = the main queue, which for a consumer is already forwarded
  # into the one above — either way the pump is the only reader
  (rk/rd_kafka_set_log_queue handle nil)
  (def [rfd wfd] (rk/make-pipe))
  (rk/rd_kafka_queue_io_event_enable queue wfd "1" 1)
  @{:kind kind
    :handle handle
    :queue queue
    :rfd rfd
    :wfd wfd
    :pair (fdwait/pair rfd)
    :stopped false
    :pump-done (ev/chan 1)
    :last-error nil
    # event-type keyword -> (fn [event client])
    :handlers @{}
    :stats @{:events 0 :errors 0}})

(defn on!
  "Install the handler for one event type (:dr, :fetch, ...)."
  [c type f]
  (put-in c [:handlers type] f)
  c)

(def- type-names
  (let [t @{}]
    (eachp [name code] rk/events (put t code name))
    (table/to-struct t)))

(def- lib-log-ns "void.kafka.lib")

(defn- forward-log!
  ``One of the library's own log lines, through void/core/log under
  its own namespace — so `[:log :levels {"void.kafka.lib" ...}]` turns
  the connection chatter of a broker that is allowed to be down up or
  off, without touching the plugin's logs. syslog levels: 3 and below
  is the library saying something failed.``
  [ev c]
  (when-let [line (rk/event-log ev)]
    # the kvs are spelled out per branch: log/warn is a macro whose
    # level check reads a LITERAL :ns first — a spliced list would be
    # checked against this file's namespace instead
    (cond
      (<= (line :level) 3)
      (log/warn (line :text) :ns lib-log-ns :kind (c :kind) :fac (line :fac))

      (<= (line :level) 6)
      (log/info (line :text) :ns lib-log-ns :kind (c :kind) :fac (line :fac))

      (log/debug (line :text) :ns lib-log-ns :kind (c :kind) :fac (line :fac)))))

(defn- dispatch! [c ev]
  (def type (get type-names (rk/rd_kafka_event_type ev)))
  (put-in c [:stats :events] (inc (get-in c [:stats :events] 0)))
  (when (= type :log)
    (forward-log! ev c))
  (when (= type :error)
    (def info {:code (rk/rd_kafka_event_error ev)
               :text (rk/cstr (rk/rd_kafka_event_error_string ev))})
    (put c :last-error info)
    (put-in c [:stats :errors] (inc (get-in c [:stats :errors] 0)))
    # the library retries on its own; this is news, not a failure of
    # anything the application asked for — those fail at their own
    # call sites (a delivery report, a poll error on a message)
    (log/warn "kafka client error event" :ns log-ns
              :kind (c :kind) :code (info :code) :err (info :text)))
  (when-let [f (get-in c [:handlers type])]
    (f ev c)))

(defn pump!
  ``Start the pump fiber: drain the queue, park on the pipe, repeat
  until the client is stopped. Every librdkafka call the client ever
  makes after `create` happens on the loop thread — the library's own
  threads write the queue from their side and never see Janet.``
  [c]
  (ev/go
    (fn kafka-pump []
      (while (not (c :stopped))
        (def ev (rk/rd_kafka_queue_poll (c :queue) 0))
        (if ev
          (do
            # dispatch may park (a consumer handler); the event lives
            # until it returns, which is what keeps the message's
            # pointers valid
            (def [ok err] (protect (dispatch! c ev)))
            (rk/rd_kafka_event_destroy ev)
            (unless ok
              (log/error "kafka event handler failed" :ns log-ns
                         :kind (c :kind)
                         :err (if (string? err) err (describe err)))))
          (do
            (def outcome (fdwait/await (c :pair) :read))
            (if (fdwait/ready? outcome)
              (rk/drain-pipe! (c :rfd))
              # :closed — stop! released the pair under us, which is
              # the shutdown signal; :err/:hup cannot mean anything
              # else on our own pipe
              (put c :stopped true)))))
      (ev/give (c :pump-done) true)))
  c)

(defn stop-pump!
  ``Stop the pump and wait for it. The flag alone is not enough: a
  pump parked on the pipe stays parked until a byte arrives, and a
  pump that read the flag as false a microsecond ago is about to park.
  So stop rings the doorbell itself — a spurious wake-up costs one
  empty poll, a missed one costs the fiber.``
  [c]
  (put c :stopped true)
  (rk/wake-byte! (c :wfd))
  (def [ok _] (protect (ev/with-deadline 10 (ev/take (c :pump-done)))))
  (unless ok
    (log/warn "kafka pump did not stop within 10 s" :ns log-ns :kind (c :kind)))
  (fdwait/release! (c :pair))
  nil)

(defn destroy!
  ``Release everything after the pump is down. `rd_kafka_destroy`
  joins the library's threads — the one deliberately blocking call
, made at :stop where a bounded block is the shutdown
  bargain.``
  [c]
  (rk/rd_kafka_queue_destroy (c :queue))
  (rk/rd_kafka_destroy (c :handle))
  (rk/close-fd! (c :rfd))
  (rk/close-fd! (c :wfd))
  nil)

(defn outq-len
  "Messages and requests the library still holds — what a producer's
  flush watches."
  [c]
  (rk/rd_kafka_outq_len (c :handle)))

# -- the boot probe ------------------------------------------------------

(defn probe!
  ``Prove the cluster answers: DescribeCluster through the same event
  API, parked on the pump, bounded by `timeout` seconds. The
  keeper-connection bargain (every db driver holds one from :start)
  for a client that has no "connect" moment — rd_kafka_new does not
  touch the network and cannot fail for an unreachable broker.

  Returns :ok, or :skipped on a librdkafka older than 2.3 (the admin
  call is not there; the miss is logged, not invented around).
  Throws, naming the brokers, when the cluster does not answer in
  time — which at :start is a boot error, the point.``
  [c brokers timeout]
  (unless rk/rd_kafka_DescribeCluster
    (log/info "kafka boot probe skipped — librdkafka has no DescribeCluster (needs >= 2.3)"
              :ns log-ns :library (rk/version))
    (break :skipped))
  (def answer (ev/chan 1))
  (on! c :describe-cluster-result
       (fn [ev _]
         (def code (rk/rd_kafka_event_error ev))
         (ev/give answer
                  (if (zero? code)
                    {:ok true}
                    {:ok false :code code
                     :text (rk/cstr (rk/rd_kafka_event_error_string ev))}))))
  (defer (put-in c [:handlers :describe-cluster-result] nil)
    (def errstr (buffer/new-filled errstr-size))
    (def opts (rk/rd_kafka_AdminOptions_new (c :handle) rk/ADMIN-OP-DESCRIBECLUSTER))
    (defer (rk/rd_kafka_AdminOptions_destroy opts)
      (rk/rd_kafka_AdminOptions_set_request_timeout
        opts (math/floor (* 1000 timeout)) errstr errstr-size)
      (rk/rd_kafka_DescribeCluster (c :handle) opts (c :queue)))
    (def [ok res] (protect (ev/with-deadline (+ timeout 1) (ev/take answer))))
    (cond
      (not ok)
      (errorf "kafka: no answer from %q within %d s — is the cluster reachable?"
              brokers (math/floor timeout))

      (res :ok) :ok

      (errorf "kafka: cluster %q did not answer the boot probe: %s (%s)"
              brokers (res :text) (rk/err-str (res :code))))))
