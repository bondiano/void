### void/jobs/state — the queue an application talks to: policy
### resolution, enqueue, inspection and the lifecycle events.
###
### The shape is void/db's and void/cache's, because the problem is:
### one component holds the value, a dyn overrides it for a scope
### (tests, tooling, a second queue), and the module-level functions
### reach for whichever is in force. `enqueue` is the funnel — every
### queued job passes through it, which is where the policy is
### resolved, the record is built and the :enqueued event is fired.
###
### Policy resolution is the part worth reading, because it is what
### makes `defjob` a declaration rather than a set of magic numbers.
### Four layers, each overriding the one before it:
###
###   1. the framework defaults (three attempts, exponential backoff)
###   2. the [:jobs] config slice — an application's house style
###   3. [:jobs :queues :<queue>] — what this queue is for; a queue
###      named :mail may reasonably retry longer than :default
###   4. the `defjob` options — what this job needs
###   5. the enqueue call — what this *call* needs
###
### Which is five, and the miscount is the point: the queue's slice
### sits between the application's and the job's, because a job that
### declares `:max-attempts 10` means it whichever queue it lands in.
###
### Lifecycle events are fired here and in ./worker as synchronous hooks —
### `:void.jobs/event` on the core hook registry, plus any listener
### registered with `listen!`. They run on the fiber that caused them, and
### a listener that throws is logged rather than allowed to fail the job.
### This is the seam void/bus takes over in wave 3; until it exists,
### "publish job events" means "run these".

(import void/core/log :as log)
(import void/core/hooks :as hooks)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import ./backend :as backend)
(import ./job :as job)
(import ./record :as record)

(def log-ns
  "Log namespace of the queue — spelled out, since the file-derived
  default would carry the install path."
  "void.jobs")

(def queue
  ``The queue this package's functions run against: what the running
  :jobs/queue component holds, or the `:void.jobs/queue` dyn where a
  scope overrides it (tests, tooling, a second queue).``
  (system/ambient :void.jobs/queue :of "the job queue"
                  :from :void/jobs :component :jobs/queue))

(def queue-dyn
  "Dynamic binding of the queue ambient — the name a scope binds."
  (queue :dyn))

(defn active-queue
  "The queue this fiber runs against: the `queue-dyn` override, else
  the started component."
  []
  (system/active queue))

(defn active-backend
  "The `:void/jobs-backend` behind the active queue."
  []
  ((active-queue) :backend))

# -- events --------------------------------------------------------------

(def event-hook
  "The core hook every job lifecycle event is run through. Handlers
  receive {:event :completed :job <record> :at <time>}."
  :void.jobs/event)

(def events
  "Every lifecycle event the runtime fires."
  [:enqueued :started :completed :failed :dead :stalled])

(def listeners
  ``Listeners registered at runtime, by name. The extension-point way
  to hear about jobs is a `:void.core/hooks` contribution for
  `event-hook`; this table is for the code that has no manifest — a
  test, a REPL, and (wave 3) the bridge that forwards these into
  void/bus.``
  @{})

(defn listen!
  "Register a listener under `name` (re-registering replaces it)."
  [name f]
  (put listeners name f)
  f)

(defn unlisten!
  "Remove a listener by name."
  [name]
  (put listeners name nil))

(defn emit!
  ``Fire a lifecycle event: the `event-hook` handlers of the running
  boot, then every `listen!` listener. Nothing here may fail a job, so
  a handler that throws is logged at :warn and the rest still run.``
  [event r &opt extra]
  (def payload
    (merge {:event event :job r :at (os/clock :realtime)} (or extra {})))
  (when-let [hooks (get (plugin/running-boot) :hooks)]
    (each e (hooks/handlers hooks event-hook)
      (def [ok err] (protect ((e :fn) payload)))
      (unless ok
        (log/warn "job event handler failed" :ns log-ns
                  :event event :handler (e :name)
                  :err (if (string? err) err (describe err))))))
  (each name (sorted (keys listeners))
    (when-let [f (get listeners name)]
      (def [ok err] (protect (f payload)))
      (unless ok
        (log/warn "job event listener failed" :ns log-ns
                  :event event :listener name
                  :err (if (string? err) err (describe err))))))
  payload)

# -- policy resolution ---------------------------------------------------

(defn queue-config
  "The [:jobs :queues :<name>] slice, or an empty one."
  [q name]
  (or (get-in q [:queues name]) {}))

(defn- pick [& vs]
  (var out nil)
  (each v vs (when (and (nil? out) (not (nil? v))) (set out v)))
  out)

(defn resolve-policy
  ``The policy of one call: the enqueue overrides over the job
  definition over the queue slice over the [:jobs] slice over the
  framework defaults. Returns the fields `record/make` needs.``
  [q d args opts now]
  (def base (q :defaults))
  (def jo (get d :opts {}))
  (def qname (pick (get opts :queue) (get jo :queue) (base :queue)))
  (def qc (queue-config q qname))
  {:job (d :name)
   :args args
   :queue qname
   :priority (pick (get opts :priority) (get jo :priority)
                   (get qc :priority) (base :priority))
   :max-attempts (pick (get opts :max-attempts) (get jo :max-attempts)
                       (get qc :max-attempts) (base :max-attempts))
   :backoff (job/normalize-backoff
              (pick (get opts :backoff) (get jo :backoff)
                    (get qc :backoff) (base :backoff))
              (string/format "job %q" (d :name)))
   :timeout (pick (get opts :timeout) (get jo :timeout)
                  (get qc :timeout) (base :timeout))
   :unique-key (job/unique-key d args opts)
   :unique-until (when-let [ttl (pick (get opts :unique-ttl) (get jo :unique-ttl))]
                   (+ now ttl))
   :group (job/group-key d args opts)
   :parent (get opts :parent)
   :children-left (get opts :children-left)
   :run-at (cond
             (get opts :at) (get opts :at)
             (get opts :delay) (+ now (get opts :delay))
             now)
   :now now})

(def- allowed-enqueue-opts
  {:queue true :priority true :max-attempts true :backoff true :timeout true
   :unique true :unique-ttl true :group true :delay true :at true
   :parent true :children-left true})

(defn- check-enqueue-opts [name opts]
  (unless (dictionary? opts)
    (errorf "enqueue %q: options must be a dictionary, got %q" name opts))
  (eachk k opts
    (unless (in allowed-enqueue-opts k)
      (errorf "enqueue %q: unknown option %q (allowed: %s)"
              name k (string/join (map |(string/format "%q" $)
                                       (sorted (keys allowed-enqueue-opts)))
                                  " "))))
  (each k [:delay :at]
    (when-let [v (get opts k)]
      (unless (number? v)
        (errorf "enqueue %q: %q must be a number of seconds, got %q" name k v))))
  (when (and (get opts :delay) (get opts :at))
    (errorf "enqueue %q: :delay and :at say the same thing two ways — pass one" name)))

# -- enqueue -------------------------------------------------------------

(defn enabled?
  "False when [:jobs :enabled] is off — enqueue then runs the job
  inline instead of queueing it (see `enqueue-with`)."
  []
  (not= false (get-in (active-queue) [:config :enabled])))

(def db-tx-dyn
  ``The dynamic binding void/db opens a transaction under. Read by
  keyword rather than through an import, and that is the whole of the
  agreement between the two packages: a job queue that had to require
  the database kernel in order to ask "am I inside a transaction"
  would be a job queue that depends on it. void/db's half is
  `state/tx-dyn`, and the keyword is as much a contract as a function
  name.``
  :void.db/tx)

(defn in-db-transaction?
  ``True when this fiber is inside a `db/with-tx` scope. False when
  there is no database in the composition at all — the same answer for
  the purpose it is asked for, which is "would this enqueue be
  committing with something".``
  []
  # `db/detached` binds it to false to sever a parent's transaction
  # across an ev/go, so the question is truthiness, not presence
  (truthy? (dyn db-tx-dyn)))

(defn enqueue-with
  ``Queue a job with per-call overrides:

      (jobs/enqueue-with {:delay 60 :priority 1} :welcome-mail 42)

  Options: :queue :priority :max-attempts :backoff :timeout :unique
  :unique-ttl :group, plus :delay (seconds from now) / :at (an
  absolute time) and the two flow keys :parent / :children-left.

  Returns the stored record — or, when a unique key is already held,
  the record holding it, so that a caller can always speak about "the
  job" without asking which of the two calls won.

  With `[:jobs :enabled] false` nothing is queued: the handler runs
  inline, right here, and the record comes back :completed. That is
  the switch for a test suite (and for a small deployment that has no
  worker yet) and it is deliberately the *only* thing that flag does —
  a disabled queue that silently dropped work would be a much worse
  kind of quiet.``
  [opts name & args]
  (def q (active-queue))
  (def d (job/lookup! name))
  (check-enqueue-opts name opts)
  (job/normalize-opts (string/format "enqueue %q" name)
                      (table/to-struct
                        (table ;(mapcat |[$ (get opts $)]
                                        (filter |(in opts $)
                                                [:queue :priority :max-attempts
                                                 :backoff :timeout :unique
                                                 :unique-ttl :group])))))
  (def now (os/clock :realtime))
  (def fields (resolve-policy q d args opts now))
  (def r (record/make fields))
  # a job whose arguments cannot be stored must fail in the caller's
  # stack, not in a worker an hour later
  (record/encode-value (r :args) (string/format "the arguments of job %q" name))
  (if (enabled?)
    (do
      (def b (q :backend))
      # a job queued inside a transaction on a backend whose rows are
      # not part of it: the worker may claim the job before the commit
      # and run it against rows that are not there yet, and a rollback
      # leaves the job behind with nothing to act on. The composition
      # decides this, not the call, so it is an error at the call
      # rather than a line in a README
      (when (and (in-db-transaction?) (not (backend/transactional? b)))
        (errorf (string "jobs/enqueue %q inside (db/with-tx ...): the %q backend's "
                        "rows do not commit with your transaction — the worker can "
                        "claim the job before you commit, and a rollback leaves it "
                        "queued against data that never existed. Enqueue after the "
                        "commit, or compose void/jobs-db ({:void/jobs-backend {:impl "
                        ":jobs/db}}), whose row is written on your connection")
                name (b :name)))
      (def stored ((b :push!) r))
      (cond
        stored
        (do
          (update (q :stats) :enqueued inc)
          (log/debug "job enqueued" :ns log-ns
                     :job (r :job) :id (r :id) :queue (r :queue)
                     :priority (r :priority) :run-at (r :run-at))
          (emit! :enqueued stored)
          stored)

        # the unique key was held. Answer with the holder rather than
        # with nil: "this work is queued" is true either way, and a
        # caller that has to distinguish can compare the id it got
        (do
          (update (q :stats) :duplicates inc)
          (log/debug "job not enqueued — its unique key is held" :ns log-ns
                     :job (r :job) :unique-key (r :unique-key))
          (or (when-let [e ((b :list) {:job name :state :pending :limit 100})]
                (find |(= (r :unique-key) (get $ :unique-key)) e))
              r))))
    (do
      (record/start! r :inline now)
      (def [ok res] (protect ((job/handler d) ;args)))
      (if ok
        (record/complete! r res (os/clock :realtime))
        (record/kill! r (if (string? res) res (describe res)) (os/clock :realtime)))
      (unless ok (error res))
      r)))

(defn enqueue
  ``Queue a job by name:

      (jobs/enqueue :welcome-mail 42)

  Everything about how it runs comes from the definition and the
  config; `enqueue-with` is the same call with overrides.``
  [name & args]
  (enqueue-with {} name ;args))

(defn enqueue-tx!
  ``Queue a job **in the transaction the caller is already in**: the
  row is written on that connection, and the job becomes visible to a
  worker when — and only when — the transaction commits.

      (db/with-tx
        (def order (db/insert! Order attrs))
        (jobs/enqueue-tx! :charge-card (order :id)))

  The same call as `enqueue`, with the two things it relies on
  asserted instead of assumed: that there is a transaction, and that
  this backend's rows are part of it. Both are properties of the
  composition rather than of the moment, so each error names what to
  add — the shape `bus/publish-tx!` has for the outbox.

  `enqueue` inside a transaction is not a lesser version of this: on a
  transactional backend it does exactly the same thing, and on one
  that is not it is refused. What this call adds is the refusal on the
  *first* count — a composition where the caller thought there was a
  transaction and there was none.``
  [name & args]
  (unless (in-db-transaction?)
    (errorf (string "jobs/enqueue-tx! %q must be called inside (db/with-tx ...) — "
                    "outside one there is no transaction for the job to commit "
                    "with, which is the whole of what it buys")
            name))
  (backend/require-transaction! ((active-queue) :backend))
  (enqueue-with {} name ;args))

(defn enqueue-in
  "Queue a job to run no earlier than `delay` seconds from now."
  [delay name & args]
  (enqueue-with {:delay delay} name ;args))

(defn enqueue-at
  "Queue a job to run no earlier than the absolute time `at` (seconds
  since the epoch, as `os/clock :realtime` counts them)."
  [at name & args]
  (enqueue-with {:at at} name ;args))

(defn perform
  ``Run a job right now, on this fiber, with no queue involved at all
  — what a test does when it is testing the work rather than the
  queueing of it. Errors propagate; nothing is retried.``
  [name & args]
  ((job/handler (job/lookup! name)) ;args))

# -- what a running handler can see --------------------------------------

(def current-job-dyn
  ``Dynamic binding: the record a handler is running under. The worker
  binds it around every run, so a handler can read its own id, its
  attempt number and — for a flow parent — what its children
  returned. Outside a worker it is nil, which is what makes
  `(jobs/current-job)` a safe thing to call from a function that is
  also called directly.``
  :void.jobs/current)

(defn current-job
  "The record this handler is running under, or nil outside a worker."
  []
  (dyn current-job-dyn))

(defn attempt
  "Which attempt this is, 1-based — 0 outside a worker. The number a
  handler consults when the last attempt should do something
  different (give up quietly, or alert)."
  []
  (get (current-job) :attempt 0))

(defn last-attempt?
  "True when a failure now sends this job to the dead letter queue."
  []
  (def r (current-job))
  (and r (>= (get r :attempt 0) (get r :max-attempts 0))))

(defn children
  ``What this job's children returned: [{:id :job :result} ...], in
  the order they finished. Empty outside a flow (see void/jobs/flow).``
  []
  (or (get (current-job) :children) []))

# -- inspection ----------------------------------------------------------

(defn fetch
  "The record with this id, or nil."
  [id]
  (((active-backend) :fetch) id))

(defn list-jobs
  ``Records matching {:queue :state :job :limit} — the reader behind
  `void jobs list`. The limit defaults to 50 because a queue is
  routinely large enough that "show me the jobs" without one is a way
  to lock up a terminal.``
  [&opt opts]
  (((active-backend) :list) (or opts {})))

(defn counts
  "Records per queue per state: {:default {:pending 12 :running 2}}."
  [&opt opts]
  (((active-backend) :counts) (or opts {})))

(defn remove-job!
  "Drop a record whatever state it is in. True when there was one."
  [id]
  (((active-backend) :remove!) id))

(defn clear!
  "Drop records matching {:queue :state} — everything when neither is
  given. Returns how many went."
  [&opt opts]
  (((active-backend) :clear!) (or opts {})))

(defn retry!
  ``Put a dead (or merely failed) record back at the front of the
  queue with its attempts reset — `void jobs retry`. Returns the
  revived record, or nil when there is no such id.``
  [id]
  (def b (active-backend))
  (when-let [r ((b :fetch) id)]
    (record/revive! r (os/clock :realtime))
    ((b :settle!) r)))

(defn stats
  "What this queue has been doing, plus whatever the backend counts."
  []
  (def q (active-queue))
  (merge {:queues (tuple ;(sorted (keys (get q :queues {}))))
          :backend (backend/capabilities (q :backend))}
         (table/to-struct (q :stats))
         (((q :backend) :stats))))

# -- the queue value -----------------------------------------------------

(def framework-defaults
  ``The bottom layer of policy resolution — what a job gets when
  neither it, nor its queue, nor the application says otherwise.``
  {:queue :default
   :priority 5
   :max-attempts 3
   :backoff job/default-backoff
   :timeout nil
   :claim-ttl 60})

(defn make
  ``Build a queue value over a backend — the component's instance, and
  what a test builds directly when it wants one without a bootstrap.``
  [b cfg0]
  (def cfg (or cfg0 {}))
  (def b* (backend/normalize b))
  @{:backend b*
    :config cfg
    :queues (or (get cfg :queues) {})
    :defaults (merge framework-defaults
                     (table/to-struct
                       (table ;(mapcat |[$ (get cfg $)]
                                       (filter |(not (nil? (get cfg $)))
                                               [:priority :max-attempts :backoff
                                                :timeout :claim-ttl])))))
    :stats @{:enqueued 0 :duplicates 0}})

(defn queue-names
  "Every queue the config knows about, plus the default one — what a
  worker with no :queues of its own serves."
  [q]
  (def names (array ;(sorted (keys (get q :queues {})))))
  (def d (get-in q [:defaults :queue]))
  (unless (index-of d names) (array/insert names 0 d))
  (tuple ;names))
