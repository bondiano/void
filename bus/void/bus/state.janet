### void/bus/state — the broker an application talks to: publish, the
### outbox, the consumers and the numbers (SPEC.md §5.22, ADR-0012).
###
### The shape is void/db's and void/jobs's, because the problem is:
### one component holds the value, a dyn overrides it for a scope
### (tests, tooling, a second bus), and the module-level functions
### reach for whichever is in force.
###
### `publish` is the funnel. Every message passes through it, which is
### where the id is minted, the correlation is inherited, the trace
### context is written into the meta and the codec turns the payload
### into whatever the backend stores. There is exactly one other way
### in — `publish-tx!` — and it does not reach the backend at all.
###
### **`publish-tx!` writes to a table, not to a transport.** The whole
### content of the transactional outbox is that "the row changed" and
### "the event was announced" become one fact rather than two: the
### insert is in the caller's transaction, so a rollback takes the
### message with it and a commit cannot lose it. A forwarder component
### (void/bus-db) reads the outbox and publishes, and the window it
### leaves — published, then died before marking the row — is a
### *duplicate*, which is the direction to fail in and which the dedup
### middleware handles. Publishing straight from inside a transaction
### is the thing this exists to replace, and ADR-0012 makes it a
### convention: an event about money goes through the outbox.
###
### **How the trace reaches obs from here.** It does not: void/bus has
### no edge to void/obs and contributes to none of its extension
### points, because a contribution to a point no active plugin owns is
### a boot error and every application that runs a bus without obs
### would stop booting. So the broker resolves obs's *public*
### functions with `require` when it starts, gets nil when that
### package is not on this process's module path, and the tracing
### middleware is simply not in the chain — the seam void/obs itself
### uses to instrument void/db without importing it.

(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import ./backend :as backend)
(import ./codec :as codec)
(import ./message :as message)
(import ./middleware :as middleware)
(import ./router :as router)

(def log-ns "void.bus")

(var current-boot
  ``The boot this bus was bootstrapped in, captured at :config-loaded.
  `plugin/current-boot` is not enough on its own: a test bootstrap is
  *untracked* on purpose (void/test), so a component that read the
  global would see the previous boot's extensions or none at all —
  which is how a suite ends up testing a composition it did not
  build. void/redis captures the same way, for the same reason.``
  nil)

(defn boot
  "The boot value in force: the captured one, else the tracked global."
  []
  (or current-boot plugin/current-boot))

(defn config-slice
  "One slice of the resolved configuration, or {}."
  [key]
  (or (get-in (boot) [:config :values key]) {}))

(defn extension
  "The reduced value of an extension point, or nil when this process
  was not bootstrapped at all (a REPL, a unit test)."
  [name]
  (get-in (boot) [:extensions name :resolved]))

(def broker-dyn
  "Dynamic binding: broker override — bind it to run a scope against a
  bus other than the started :bus/broker component."
  :void.bus/broker)

(var current-broker
  "The value of the running :bus/broker component (set by its :start).
  One per process, like plugin/current-boot."
  nil)

(defn active
  "The broker this fiber runs against: the `broker-dyn` override, else
  the started component."
  []
  (or (dyn broker-dyn)
      current-broker
      (error "void/bus is not started — no :bus/broker component (or bind the broker-dyn dynamic)")))

(defn active-backend
  "The backend behind the active broker."
  []
  ((active) :backend))

# -- the obs seam --------------------------------------------------------

(defn- module-fn
  "The public binding `name` of module `path`, or nil when that
  package is not on this process's module path."
  [path name]
  (def [ok env] (protect (require path)))
  (when ok (get-in env [name :value])))

(defn resolve-tracer
  ``The three things bus needs from void/obs, resolved the public way,
  or nil when obs is not in this process. Never an error: "trace the
  messages if there is a tracer" is the whole point of an optional
  seam, and a bus that refused to start without obs would be an
  anti-feature.

  **Two conditions, not one.** obs has to be on the module path *and*
  in the composition. The module path alone is not enough: `with-span`
  builds a span whether or not obs was started, so a process that
  merely has the package installed would pay for a span table and two
  ids per message that nothing exports. Composing obs is the decision
  to observe, and it is the one this reads.``
  []
  (unless (index-of :void/obs (get (boot) :active []))
    (break nil))
  (def with-span* (module-fn "void/obs/init" 'with-span*))
  (def parse (module-fn "void/obs/init" 'parse-traceparent))
  (def traceparent (module-fn "void/obs/init" 'traceparent))
  (def current (module-fn "void/obs/init" 'current-span))
  (when (and with-span* parse traceparent current)
    {:with-span (fn with-span [name opts f] (with-span* name opts f))
     :parse (fn parse-remote [header] (when header (parse header)))
     :traceparent (fn outgoing [] (when-let [span (current)] (traceparent span)))}))

# -- the broker ----------------------------------------------------------

(defn make
  ``A broker value over a normalized backend and codec. Kept separate
  from the component so a test can stand one up without a bootstrap
  (`bus/make-broker`), the way `jobs/make-queue` can.``
  [b c cfg &opt contribs tracer]
  (codec/check-compatible! c b)
  @{:backend b
    :codec c
    :config cfg
    :group (get cfg :group :default)
    :middleware (tuple ;(or contribs []))
    :tracer tracer
    # group -> {:sub :compiled :defs}
    :consumers @{}
    # an override slot for a test that wants its own writer. The
    # ordinary writer is the backend's own (`outbox-writer` below) —
    # the outbox is a property of the transport, not something
    # installed onto the broker, so `void bus stats` reports it the
    # same whether the process came up through `void/run!` or through
    # a CLI subset boot that runs no :after-start hooks
    :outbox nil
    :stats @{:published 0 :delivered 0 :outboxed 0}})

(defn outbox-writer
  ``The transactional-outbox writer in force: the broker's override,
  else the active backend's own. nil when this composition has no
  outbox at all, which is what makes `publish-tx!` an error naming the
  plugin to add.``
  [&opt br]
  (default br (active))
  (or (br :outbox) (get-in br [:backend :outbox-write!])))

(defn- bump! [br key]
  (put-in br [:stats key] (inc (get-in br [:stats key] 0))))

(defn envelope
  ``A message through the codec: what the backend stores. The id, the
  topic and the meta stay readable — a correlation id that can only be
  found by decoding the payload is one no operator will ever put in a
  WHERE clause — and only the payload and the meta *body* are encoded.``
  [br msg]
  (def c (br :codec))
  @{:id (msg :id)
    :topic (msg :topic)
    :body (codec/encode-body c (msg :payload))
    :meta-body (codec/encode-meta c (msg :meta))
    :meta (msg :meta)
    :message msg})

(defn hydrate
  ``The message inside an envelope the backend handed back. An
  in-heap backend gives the live message straight back; a backend that
  stored bytes gets them decoded here, which is the one place the
  round trip happens and therefore the one place it can be symmetric
  (./codec).``
  [br env]
  (def c (br :codec))
  (def base
    (if-let [msg (get env :message)]
      # the in-heap path: still through the codec, so that a handler
      # sees the same shape under :memory as under :db
      @{:id (msg :id) :topic (msg :topic)
        :payload (codec/decode-body c (codec/encode-body c (msg :payload)))
        :meta (merge @{} (msg :meta))}
      @{:id (env :id)
        :topic (env :topic)
        :payload (codec/decode-body c (env :body))
        :meta (codec/decode-meta c (env :meta-body))}))
  (when-let [r (get env :redelivery)]
    (put-in base [:meta :redelivery] r))
  base)

# -- publishing ----------------------------------------------------------

(defn publish
  ``Publish a message and return it:

      (bus/publish :user/created {:id 42 :email addr})
      (bus/publish :user/created payload {:correlation-id id})

  Options are `message/make`'s. The message reaches the backend
  encoded; what happens to it after that is the backend's declared
  guarantee, and `bus/capabilities` prints it.``
  [topic payload &opt opts]
  (def br (active))
  (def msg (message/make topic payload opts))
  (when-let [tracer (br :tracer)]
    (when-let [tp ((tracer :traceparent))]
      (put-in msg [:meta :traceparent] tp)))
  ((get-in br [:backend :publish!]) (envelope br msg))
  (bump! br :published)
  (log/debug "message published" :ns log-ns
             :topic topic :id (msg :id)
             :correlation-id (message/correlation-id msg))
  msg)

(defn publish-tx!
  ``Publish through the transactional outbox: the message is written
  into the outbox table **in the transaction this call is already
  inside**, and a forwarder publishes it after the commit.

      (db/with-tx
        (db/update! Account id {:balance new})
        (bus/publish-tx! :account/debited {:id id :amount amt}))

  A rollback takes the message with it; a commit cannot lose it. This
  is the only sanctioned way to announce what a transaction wrote
  (ADR-0012) — publishing straight from inside a transaction
  announces a state that may never exist.

  Needs `void/bus-db` in the composition (it is what installs the
  writer) and a transaction around the call; both are errors that name
  what is missing rather than a message that quietly went out
  un-transactionally.``
  [topic payload &opt opts]
  (def br (active))
  (def write (outbox-writer br))
  (unless write
    (error "bus/publish-tx! needs the transactional outbox: add :void/bus-db to the composition (it owns the outbox table and the forwarder that drains it)"))
  (def msg (message/make topic payload opts))
  (when-let [tracer (br :tracer)]
    (when-let [tp ((tracer :traceparent))]
      (put-in msg [:meta :traceparent] tp)))
  (write (envelope br msg))
  (bump! br :outboxed)
  (log/debug "message written to the outbox" :ns log-ns
             :topic topic :id (msg :id)
             :correlation-id (message/correlation-id msg))
  msg)

# -- consuming -----------------------------------------------------------

(defn- built-in-middleware
  ``The chain every handler gets unless the [:bus] slice says
  otherwise. `retry` is the one whose default is *derived*: under an
  at-most-once backend nobody else will re-run the handler, so
  retrying here is the only retry there is; under an at-least-once
  backend the transport will hand the message over again, and doing
  both turns three attempts into nine.``
  [br]
  (def cfg (br :config))
  (def b (br :backend))
  (def retry-cfg (get cfg :retry {}))
  (def retry-on?
    (if (nil? (get retry-cfg :enabled))
      (not (backend/at-least-once? b))
      (truthy? (get retry-cfg :enabled))))
  (def out @[(middleware/panic-guard)
             (middleware/correlation)])
  (when-let [tracer (br :tracer)]
    (array/push out (middleware/tracing tracer)))
  (when (get-in cfg [:poison :enabled] true)
    (array/push out
                (middleware/poison (get cfg :poison {})
                                   (fn publish-poison [topic payload opts]
                                     (with-dyns [broker-dyn br]
                                       (publish topic payload opts))))))
  (when retry-on?
    (array/push out (middleware/retry retry-cfg)))
  (array/push out (middleware/validate))
  (when (get-in cfg [:dedup :enabled] true)
    (array/push out (middleware/dedup (get cfg :dedup {}))))
  (when (pos? (get-in cfg [:throttle :max] 0))
    (array/push out (middleware/throttle (get cfg :throttle {}))))
  (tuple ;(map middleware/normalize out)))

(defn chain-for
  "Every middleware contribution in force: the built-ins, then what
  plugins contributed to `:void.bus/middleware`."
  [br]
  [;(built-in-middleware br) ;(br :middleware)])

(defn start-consumers!
  ``Start one consumer per group the declared handlers ask for. A
  process with no `defhandler` in it starts none — which is the
  ordinary case for a web process whose consumers live in a worker,
  and the reason this is not an error.``
  [br]
  (def contribs (chain-for br))
  (def default-group (br :group))
  (def started @[])
  (each group (router/groups default-group)
    (def defs (router/for-group group default-group))
    (def compiled (router/compile-group defs contribs))
    (def wanted (router/topics defs))
    (def exact (router/exact-topics defs))
    (def sub
      ((get-in br [:backend :consume!])
        {:group group
         :topics wanted
         :exact-topics exact
         :match? (fn matches-group [topic]
                   (some |(message/matches? $ topic) wanted))}
        (fn deliver [env]
          (def msg (hydrate br env))
          (bump! br :delivered)
          (with-dyns [broker-dyn br]
            (router/dispatch compiled msg)))))
    (put-in br [:consumers group] @{:sub sub :compiled compiled :defs defs})
    (array/push started group)
    (log/info "bus consumer started" :ns log-ns
              :group group
              :handlers (map |($ :name) defs)
              :topics wanted))
  (tuple ;started))

(defn stop-consumers!
  "Stop every consumer this broker started, in name order."
  [br]
  (each group (sorted (keys (br :consumers)))
    (when-let [c (get-in br [:consumers group])]
      (protect ((get-in br [:backend :stop!]) (c :sub)))
      (put-in br [:consumers group] nil)))
  nil)

# -- inspection ----------------------------------------------------------

(defn capabilities
  "What the active backend promises, as data."
  []
  (backend/capabilities (active-backend)))

(defn stats
  "Everything `void bus stats` prints."
  []
  (def br (active))
  (merge (table/to-struct (br :stats))
         {:backend (backend/capabilities (br :backend))
          :codec (get-in br [:codec :name])
          :group (br :group)
          :consumers (sorted (keys (br :consumers)))
          :handlers (router/defined)
          :outbox (truthy? (outbox-writer br))
          :tracing (truthy? (br :tracer))
          :backend-stats ((get-in br [:backend :stats]))}))
