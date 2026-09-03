### void/core/hooks — lifecycle hooks + in-process pub/sub.
###
### Two mechanisms, one module. Lifecycle hooks are synchronous and
### ordered: handlers are registered per hook name (:config-loaded,
### :before-start, ... or any custom keyword), sorted by :phase then
### :name and run on the caller's fiber — bootstrap wiring, not
### messaging. The event bus is the opposite: an ev-based in-process
### pub/sub for application events (:user/created ...). Every
### subscriber owns a buffered channel drained by its own fiber, so
### publish! never runs handlers inline; a slow subscriber
### back-pressures the publisher only once its buffer fills. Not
### Kafka: delivery is in-process, at-most-once, and queued events are
### dropped on unsubscribe!/close!.

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(defn- names-str [names]
  (string/join (map |(string/format "%q" $) (sorted names)) " "))

(def lifecycle-hooks
  "Hooks fired by the core lifecycle itself: :config-loaded,
  :before-start and :after-start by plugin/start!, :before-stop and
  :after-stop by plugin/shutdown!. Every handler receives the boot
  value. Any other keyword is a valid custom hook."
  [:config-loaded :before-start :after-start :before-stop :after-stop])

# -- hook registry -------------------------------------------------------

(def- allowed-handler-opts {:phase true :name true :plugin true :doc true})

(defn registry
  "Create an empty hook registry: hook name -> handler name -> entry."
  []
  @{})

(defn add!
  ``Register a synchronous handler for a hook:

      (hooks/add! reg :after-start
        (fn [boot] (print "up"))
        :phase 500 :name :banner)

  Options: :phase (int, default 1000 — lower runs earlier), :name
  (keyword, default a gensym; re-adding the same name replaces the
  handler — REPL-friendly), :plugin (source attribution for errors),
  :doc. Returns the entry.``
  [reg hook f & kvs]
  (unless (keyword? hook)
    (errorf "hook name must be a keyword, got %q" hook))
  (unless (callable? f)
    (errorf "hook %q: handler must be a function, got %q" hook f))
  (when (odd? (length kvs))
    (errorf "hook %q: expected key-value option pairs" hook))
  # nil-valued options vanish in the table constructor, so callers may
  # pass e.g. :plugin nil to mean "unattributed"
  (def opts (table ;kvs))
  (eachk k opts
    (unless (in allowed-handler-opts k)
      (errorf "hook %q: unknown option %q (allowed: %s)"
              hook k (names-str (keys allowed-handler-opts)))))
  (def name (get opts :name (keyword (gensym))))
  (unless (keyword? name)
    (errorf "hook %q: :name must be a keyword, got %q" hook name))
  (def phase (get opts :phase 1000))
  (unless (and (number? phase) (= phase (math/trunc phase)))
    (errorf "hook %q: :phase must be an integer, got %q" hook phase))
  (def entry
    (freeze {:hook hook :name name :fn f :phase phase
             :plugin (get opts :plugin) :doc (get opts :doc)}))
  (def handlers (or (get reg hook) (let [t @{}] (put reg hook t) t)))
  (put handlers name entry)
  entry)

(defn remove!
  "Remove the handler registered under `name` for `hook`; returns the
  removed entry or nil."
  [reg hook name]
  (when-let [entry (get-in reg [hook name])]
    (put (reg hook) name nil)
    entry))

(defn handlers
  "Handlers for one hook (or, without `hook`, for every hook), in
  execution order: sorted by :phase, ties broken by :name."
  [reg &opt hook]
  (def entries
    (if hook
      (values (get reg hook {}))
      (mapcat values (values reg))))
  (sorted-by (fn [e] [(e :phase) (string (e :hook)) (string (e :name))])
             entries))

(defn- fail [entry e]
  (errorf "hook %q handler %q%s failed: %s"
          (entry :hook) (entry :name)
          (if-let [p (entry :plugin)] (string/format " (plugin %q)" p) "")
          (if (string? e) e (describe e))))

(defn run!
  "Run every handler of `hook` in order on the current fiber, passing
  `args` to each. Fail-fast: the first handler error aborts the run
  with the handler and plugin named. Returns the number of handlers
  run."
  [reg hook & args]
  (var n 0)
  (each entry (handlers reg hook)
    (def [ok e] (protect ((entry :fn) ;args)))
    (unless ok (fail entry e))
    (++ n))
  n)

(defn run-protected!
  "Like `run!`, but a handler error never stops the remaining handlers
  — for teardown paths (:before-stop/:after-stop must not block a
  shutdown). Returns the tuple of error messages (empty on success)."
  [reg hook & args]
  (def errors @[])
  (each entry (handlers reg hook)
    (def [ok e] (protect ((entry :fn) ;args)))
    (unless ok
      (def [_ msg] (protect (fail entry e)))
      (array/push errors msg)))
  (tuple ;errors))

# -- event bus -----------------------------------------------------------

(defn- default-on-error [sub event err]
  (eprintf "bus subscriber %q failed on %q: %s"
           (sub :name) (event :topic)
           (if (string? err) err (describe err))))

(def- allowed-bus-opts {:buffer true :on-error true})
(def- allowed-sub-opts {:name true :buffer true})

(defn bus
  ``Create an in-process event bus.

  Options:
    :buffer    default per-subscriber channel capacity (default 32)
    :on-error  (fn [sub event err]) called when a handler throws;
               default prints to stderr — a handler error never kills
               the subscriber``
  [&opt opts]
  (default opts {})
  (eachk k opts
    (unless (in allowed-bus-opts k)
      (errorf "bus: unknown option %q (allowed: %s)"
              k (names-str (keys allowed-bus-opts)))))
  (def buffer (get opts :buffer 32))
  (unless (and (number? buffer) (pos? buffer))
    (errorf "bus: :buffer must be a positive number, got %q" buffer))
  @{:topics @{}
    :buffer buffer
    :on-error (get opts :on-error default-on-error)
    :closed false})

(defn subscribe!
  ``Subscribe a handler to a topic; the topic :* receives every event.
  The handler runs on its own fiber and receives the event struct
  {:topic :payload}. Options: :name (keyword; re-subscribing the same
  name on a topic replaces the handler), :buffer (channel capacity
  override). Returns the subscription.``
  [b topic handler &opt opts]
  (default opts {})
  (when (b :closed) (error "bus is closed"))
  (unless (keyword? topic)
    (errorf "bus topic must be a keyword, got %q" topic))
  (unless (callable? handler)
    (errorf "bus subscriber for %q must be a function, got %q" topic handler))
  (eachk k opts
    (unless (in allowed-sub-opts k)
      (errorf "bus subscribe: unknown option %q (allowed: %s)"
              k (names-str (keys allowed-sub-opts)))))
  (def name (get opts :name (keyword (gensym))))
  (unless (keyword? name)
    (errorf "bus subscribe: :name must be a keyword, got %q" name))
  (def chan (ev/chan (get opts :buffer (b :buffer))))
  (def done (ev/chan 1))
  (def sub @{:topic topic :name name :chan chan :done done})
  (when-let [prev (get-in b [:topics topic name])]
    (ev/chan-close (prev :chan)))
  (def topic-subs (or (get-in b [:topics topic])
                      (let [t @{}] (put (b :topics) topic t) t)))
  (put topic-subs name sub)
  (ev/go
    (fn bus-subscriber []
      (var running true)
      (while running
        (def event (ev/take chan))
        (if (nil? event)
          (set running false)
          (try (handler event)
            ([e] ((b :on-error) sub event e)))))
      (ev/give done true)))
  sub)

(defn unsubscribe!
  "Remove a subscription by topic and name (or a subscription value).
  Events still queued in its buffer are dropped. Returns the removed
  subscription or nil."
  [b topic &opt name]
  (def [t n] (if (dictionary? topic)
               [(topic :topic) (topic :name)]
               [topic name]))
  (when-let [sub (get-in b [:topics t n])]
    (put (get-in b [:topics t]) n nil)
    (ev/chan-close (sub :chan))
    sub))

(defn- topic-subs [b topic]
  (def subs (get-in b [:topics topic] {}))
  (seq [name :in (sorted (keys subs))] (subs name)))

(defn publish!
  "Publish an event to every subscriber of `topic` plus the :*
  wildcard subscribers. Blocks only when a subscriber's buffer is full
  (backpressure). Returns the number of subscribers the event was
  delivered to."
  [b topic payload]
  (when (b :closed) (error "bus is closed"))
  (unless (keyword? topic)
    (errorf "bus topic must be a keyword, got %q" topic))
  (def event (freeze {:topic topic :payload payload}))
  (var n 0)
  (each sub (topic-subs b topic)
    (ev/give (sub :chan) event)
    (++ n))
  (unless (= topic :*)
    (each sub (topic-subs b :*)
      (ev/give (sub :chan) event)
      (++ n)))
  n)

(defn close!
  "Close the bus: no more publishes, every subscriber channel is
  closed (dropping queued events) and each subscriber fiber is awaited
  for up to `timeout` seconds (default 5). Throws naming the
  subscribers that did not stop in time."
  [b &opt timeout]
  (default timeout 5)
  (put b :closed true)
  (def subs (mapcat |(values $) (values (b :topics))))
  (each sub subs (ev/chan-close (sub :chan)))
  (def stuck @[])
  (each sub subs
    (def [ok _] (protect (ev/with-deadline timeout (ev/take (sub :done)))))
    (unless ok (array/push stuck (sub :name))))
  (table/clear (b :topics))
  (unless (empty? stuck)
    (errorf "bus subscribers did not stop within %d s: %s"
            timeout (names-str stuck)))
  b)
