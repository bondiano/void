### void/jobs/worker — the executor: fibers that claim, run and settle
### (SPEC.md §5.12, ADR-0012).
###
### A worker is `concurrency` fibers on the ev loop, each one running
### the same three lines forever — claim a job, run it, write down what
### happened — plus two housekeeping fibers: a heartbeat that keeps the
### claims of jobs still running from looking abandoned, and a reaper
### that picks up the claims that genuinely are. Fibers, not threads:
### a job that waits on a database, an HTTP call or a redis round trip
### costs nothing while it waits, which is the whole reason `ev/` is
### the concurrency model here (ADR-0010). A job that spends its time
### in a tight numeric loop does block the others, and the answer is
### the same as everywhere else in void: another process.
###
### Four limits act on the claim, and they are deliberately different
### mechanisms because they answer different questions:
###
###   concurrency          how many jobs this worker runs at once —
###                        the number of fibers
###   per-queue concurrency how many of them may be from one queue —
###                        counted here, before the claim
###   group concurrency    how many may share a group key — counted
###                        here too, and passed to the backend as
###                        :skip-groups so that the claim skips them
###                        rather than returning one we must give back.
###                        This is what fair scheduling between tenants
###                        is: a cap, so that the tenant with ten
###                        thousand jobs cannot hold every fiber
###   rate limit           how many may *start* per window — checked
###                        after the claim, because a limiter consulted
###                        before it would spend a token on every empty
###                        poll. A job that arrives against a closed
###                        window is put back with `record/defer!`
###                        (which does not count as an attempt) and the
###                        queue is paused locally until the window
###                        opens, so the next poll does not repeat the
###                        round trip
###
### Timeouts run the handler as its own ev task with `ev/deadline` on
### it, never `ev/with-deadline` around it: that cancels the *root*
### task, and cancelling this loop mid-ev-operation is the upstream bug
### class void/http already documented (ADR-0015).
###
### Shutdown is a drain, not a kill: `stop!` closes the stop channel,
### every napping fiber wakes at once, the ones holding a job are given
### `:shutdown-timeout` seconds to finish it, and what is still running
### after that is left running — its claim goes stale and another
### worker reaps it, which is exactly the path a `kill -9` takes. A
### queue whose jobs are not safe to run twice needs them idempotent;
### no queue that survives restarts can promise otherwise.
###
### **Not spork/tasker, and this is the one place void departs from
### ADR-0012's letter.** The ADR names tasker as the executor, written
### before its source was read; tasker runs *subprocesses* — a task is
### an argv of strings handed to `os/spawn`, and its records live as
### `task.jdn` files in a directory. `defjob` is the opposite of that
### by construction: a handler is an in-process Janet function reached
### through a symbol so that redefining it in the REPL takes effect on
### the next job (ADR-0002), and it closes over the components the
### system started. There is no argv that expresses "call this function
### in this process", and tasker's on-disk records are the very thing
### `:void.jobs/backend` exists to replace — adopting it would mean
### keeping two persistence layers, one of which cannot do SKIP LOCKED.
### What the ADR actually asked for is an executor that does not block
### the loop, and on `ev/` that is a fiber. spork/cron *is* used, for
### `defschedule`, exactly as the ADR says (./schedule).

(import void/core/log :as log)
(import ./backend :as backend)
(import ./job :as job)
(import ./record :as record)
(import ./state :as state)

(def log-ns
  "Log namespace of the worker."
  "void.jobs.worker")

(def defaults
  "Defaults of the [:jobs :worker] slice."
  {:enabled false
   :concurrency 5
   :poll-interval 1
   :shutdown-timeout 20})

(defn- now [] (os/clock :realtime))

(def- deadline-error
  # the exact value `ev/deadline` cancels a task with — matched whole,
  # never as a substring: a job whose own error merely mentions a
  # deadline is a failure, not a timeout
  "deadline expired")

(defn- worker-id []
  (string "w-" (string/slice (record/new-id) 11)))

# -- construction --------------------------------------------------------

(defn make
  ``Build a worker over a queue value (see state/make). Options:

    :queues              which queues to serve, most-wanted first
                         (default: every queue the config names)
    :concurrency         how many jobs at once (default 5)
    :poll-interval       seconds between polls of an empty queue
    :shutdown-timeout    how long `stop!` waits for a running job
    :id                  this worker's token; defaults to a fresh one

  Nothing starts until `start!` or `run!`.``
  [q &opt opts]
  (def o (merge defaults (or opts {})))
  (def queues (or (get o :queues) (state/queue-names q)))
  (unless (and (indexed? queues) (not (empty? queues)) (all keyword? queues))
    (errorf "worker :queues must be a non-empty tuple of queue names, got %q" queues))
  (def n (o :concurrency))
  (unless (and (number? n) (= n (math/trunc n)) (pos? n))
    (errorf "worker :concurrency must be a positive integer, got %q" n))
  @{:id (get o :id (worker-id))
    :queue q
    :queues (tuple ;queues)
    :concurrency n
    :poll-interval (o :poll-interval)
    :shutdown-timeout (o :shutdown-timeout)
    :claim-ttl (get-in q [:defaults :claim-ttl] 60)
    :running @{}
    :per-queue @{}
    :per-group @{}
    :paused @{}
    :stop-chan nil
    :stopped true
    :fibers @[]
    :stats @{:claimed 0 :completed 0 :failed 0 :dead 0
             :deferred 0 :reaped 0 :timeouts 0}})

# -- limits --------------------------------------------------------------

(defn- queue-limit [w qname]
  (get (state/queue-config (w :queue) qname) :concurrency (w :concurrency)))

(defn- group-limit [w qname]
  (get (state/queue-config (w :queue) qname) :group-concurrency))

(defn- rate-limit [w qname]
  (get (state/queue-config (w :queue) qname) :rate-limit))

(defn eligible-queues
  ``The queues this worker may claim from right now: the ones it
  serves, minus those at their concurrency cap and those paused by a
  rate limit that has not reopened.``
  [w t]
  (tuple ;(filter
            (fn [qn]
              (and (< (get-in w [:per-queue qn] 0) (queue-limit w qn))
                   (let [until (get-in w [:paused qn])]
                     (or (nil? until) (<= until t)))))
            (w :queues))))

(defn blocked-groups
  ``Group keys already running as many jobs as their queue allows —
  what the claim is told to skip. Without a :group-concurrency
  anywhere this is empty and the backend does no extra work.``
  [w]
  (def out @{})
  (eachp [g n] (w :per-group)
    (def caps (seq [qn :in (w :queues) :let [c (group-limit w qn)] :when c] c))
    (unless (empty? caps)
      (when (>= n (min ;caps)) (put out g true))))
  out)

(defn- note-start! [w r]
  (put-in w [:running (r :id)] r)
  (update (w :per-queue) (r :queue) |(inc (or $ 0)))
  (when-let [g (r :group)]
    (update (w :per-group) g |(inc (or $ 0)))))

(defn- note-end! [w r]
  (put (w :running) (r :id) nil)
  (update (w :per-queue) (r :queue) |(max 0 (dec (or $ 0))))
  (when-let [g (r :group)]
    (def n (max 0 (dec (get-in w [:per-group g] 0))))
    (if (zero? n)
      (put (w :per-group) g nil)
      (put (w :per-group) g n))))

# -- settling ------------------------------------------------------------

(defn- err-str [e]
  # what the record keeps and the dashboard shows. log/message-of is
  # what reads a structured throw's own message: a job that failed
  # against `{:status 404 :message "..."}` used to record the struct's
  # address, which is a failure nobody can act on
  (log/message-of e 500))

(defn- kill-parents!
  ``A dead child kills the flow it belongs to. The alternative — a
  parent that waits for a child that will never finish — is a queue
  that quietly stops, and a queue that stops quietly is worse than one
  that fails loudly. Walks up: a flow three deep dies three deep.``
  [b child t]
  (var pid (get child :parent))
  (var guard 0)
  (while (and pid (< guard 64))
    (++ guard)
    (def parent ((b :fetch) pid))
    (if (and parent (record/live? parent))
      (do
        # the token the stored parent carries right now, taken before
        # kill! clears it — the fence the settle is made under
        (def held (parent :token))
        (record/kill! parent
                      (string/format "child job %s (%s) died" (child :id) (child :job))
                      t)
        (if (nil? ((b :settle!) parent held))
          # a worker claimed the parent while we were killing it: its
          # own run owns the rest of the chain now
          (set pid nil)
          (do
            (state/emit! :dead parent)
            (set pid (get parent :parent)))))
      (set pid nil))))

(defn- claim-lost! [w r what]
  # the settle was fenced off: a reaper re-tokened the claim while
  # this worker held it, and the run under the new token is the one
  # that counts — writing ours over it would be last-writer-wins on a
  # record somebody else owns
  (log/warn "job finished but its claim was gone — a reaper gave it to another worker"
            :ns log-ns :job (r :job) :id (r :id) :queue (r :queue) :outcome what)
  r)

(defn- settle-completed! [w r result t]
  (def b (get-in w [:queue :backend]))
  (record/complete! r result t)
  (if (nil? ((b :settle!) r (w :id)))
    (claim-lost! w r :completed)
    (do
      (update (w :stats) :completed inc)
      (state/emit! :completed r)
      (when (and (r :parent) (backend/supports-flows? b))
        (when-let [parent ((b :release-parent!) r)]
          (log/debug "flow parent released" :ns log-ns
                     :parent (parent :id) :job (parent :job))
          (state/emit! :enqueued parent)))
      r)))

(defn- settle-failed! [w r err t]
  (def b (get-in w [:queue :backend]))
  (def msg (err-str err))
  (if (< (get r :attempt 0) (get r :max-attempts 3))
    (let [wait (job/retry-delay (get r :backoff) (get r :attempt 0))]
      (record/retry! r msg (+ t wait) t)
      (if (nil? ((b :settle!) r (w :id)))
        (claim-lost! w r :failed)
        (do
          (update (w :stats) :failed inc)
          (log/warn "job failed — retrying" :ns log-ns
                    :job (r :job) :id (r :id) :queue (r :queue)
                    :attempt (r :attempt) :of (r :max-attempts)
                    :retry-in (math/round wait) :err msg)
          (state/emit! :failed r {:retry-in wait})
          r)))
    (do
      (record/kill! r msg t)
      (if (nil? ((b :settle!) r (w :id)))
        (claim-lost! w r :dead)
        (do
          (update (w :stats) :dead inc)
          (log/error "job died" :ns log-ns
                     :job (r :job) :id (r :id) :queue (r :queue)
                     :attempts (r :attempt) :err msg)
          (state/emit! :dead r)
          (kill-parents! b r t)
          r)))))

# -- running one job -----------------------------------------------------

(defn- call-handler
  ``Run the handler, under its own deadline when the job has a
  :timeout. The deadline is put on a child task rather than on this
  fiber: `ev/with-deadline` cancels the root task, and this fiber is a
  loop that must survive its jobs (ADR-0015, void/http/server).``
  [d r]
  (def args (r :args))
  (def timeout (get r :timeout))
  (if (nil? timeout)
    (with-dyns [state/current-job-dyn r] ((job/handler d) ;args))
    (do
      (def sup (ev/chan 1))
      (def task (ev/go (fn job-task []
                         (with-dyns [state/current-job-dyn r]
                           ((job/handler d) ;args)))
                       nil sup))
      (ev/deadline timeout task task)
      (def [sig fib] (ev/take sup))
      (def value (fiber/last-value fib))
      (cond
        (= :ok sig) value
        (= deadline-error value)
        (errorf "timed out after %.3g s" timeout)
        (error value)))))

(defn run-one!
  ``Run one claimed record to its conclusion and settle it. Never
  throws: a job's failure is the queue's data, not the worker's
  error.``
  [w r]
  (note-start! w r)
  (state/emit! :started r)
  (log/debug "job started" :ns log-ns
             :job (r :job) :id (r :id) :queue (r :queue)
             :attempt (r :attempt))
  (def t0 (os/clock :monotonic))
  (def [ok res]
    (protect
      (let [d (job/lookup! (r :job))]
        (call-handler d r))))
  (def us (math/round (* 1_000_000 (- (os/clock :monotonic) t0))))
  (def t (now))
  (def [sok serr]
    (protect
      (if ok
        (do (log/debug "job completed" :ns log-ns
                       :job (r :job) :id (r :id) :us us)
            (settle-completed! w r res t))
        (do (when (and (string? res) (string/find "timed out" res))
              (update (w :stats) :timeouts inc))
            (settle-failed! w r res t)))))
  (unless sok
    # the backend went away while we were settling. The record stays
    # :running, its claim goes stale, and a reaper picks it up — which
    # is the same path a killed worker takes, and the reason that path
    # exists
    (log/error "could not settle a finished job" :ns log-ns
               :job (r :job) :id (r :id) :err (err-str serr)))
  (note-end! w r)
  r)

# -- the loops -----------------------------------------------------------

(defn- wait-or-stop
  ``Sleep for `seconds`, or until the worker is told to stop —
  whichever comes first. The take runs in a child task so the deadline
  never touches this fiber's root task.``
  [w seconds]
  (def ch (w :stop-chan))
  (if (or (w :stopped) (nil? ch))
    nil
    (do
      (def sup (ev/chan 1))
      (def task (ev/go (fn stop-waiter [] (ev/take ch)) nil sup))
      (ev/deadline seconds task task)
      (ev/take sup)
      nil)))

(defn- pause-queue! [w qname until]
  (put-in w [:paused qname] until)
  (log/debug "queue paused by its rate limit" :ns log-ns
             :queue qname :for (math/round (- until (now)))))

(defn claim-one
  ``Claim one runnable record for this worker, honouring the
  concurrency caps and the rate limits. Returns the record, or nil
  when there is nothing to do right now.``
  [w]
  (def b (get-in w [:queue :backend]))
  (def t (now))
  (def qs (eligible-queues w t))
  (when (empty? qs) (break nil))
  (def r ((b :claim!) {:queues qs :now t :token (w :id)
                       :skip-groups (blocked-groups w)}))
  (when r
    (update (w :stats) :claimed inc)
    (def rl (rate-limit w (r :queue)))
    (def wait
      (if rl
        ((b :rate-take!) (r :queue) (get rl :max) (get rl :duration) t)
        0))
    (if (pos? wait)
      (do
        (record/defer! r (+ t wait))
        ((b :settle!) r (w :id))
        (update (w :stats) :deferred inc)
        (pause-queue! w (r :queue) (+ t wait))
        nil)
      r)))

(defn- runner [w]
  (while (not (w :stopped))
    (def r (claim-one w))
    (if r
      (run-one! w r)
      (wait-or-stop w (w :poll-interval)))))

(defn- heartbeat [w]
  (def b (get-in w [:queue :backend]))
  (def every (max 1 (/ (w :claim-ttl) 3)))
  (while (not (w :stopped))
    (wait-or-stop w every)
    (unless (w :stopped)
      (def ids (keys (w :running)))
      (unless (empty? ids)
        # under this worker's token: a claim a reaper already took away
        # must not be kept alive by its old holder's heartbeat
        (def [ok e] (protect ((b :touch!) ids (now) (w :id))))
        (unless ok
          (log/warn "could not refresh the claims of running jobs" :ns log-ns
                    :err (err-str e)))))))

(defn reap-once!
  ``Take over the claims of workers that stopped answering and put
  their jobs through the ordinary failure path — a retry when they
  have attempts left, the dead letter queue when they do not. Returns
  how many were reaped.``
  [w]
  (def b (get-in w [:queue :backend]))
  (unless (backend/supports-reaping? b) (break 0))
  (def t (now))
  (def stalled
    ((b :reap!) {:now t :ttl (w :claim-ttl) :token (w :id) :limit 100}))
  (each r stalled
    (update (w :stats) :reaped inc)
    (log/warn "job stalled — the worker holding it stopped answering" :ns log-ns
              :job (r :job) :id (r :id) :queue (r :queue) :attempt (r :attempt))
    (state/emit! :stalled r)
    (settle-failed! w r "stalled: the worker holding this job stopped answering" t))
  (length stalled))

(defn- reaper [w]
  (def b (get-in w [:queue :backend]))
  (unless (backend/supports-reaping? b) (break))
  (def every (max 1 (/ (w :claim-ttl) 2)))
  (while (not (w :stopped))
    (wait-or-stop w every)
    (unless (w :stopped)
      (def [ok e] (protect (reap-once! w)))
      (unless ok
        (log/warn "reaping stalled jobs failed" :ns log-ns :err (err-str e))))))

# -- lifecycle -----------------------------------------------------------

(defn start!
  ``Start the worker's fibers and return immediately. The queue value
  the worker was built over is bound into every fiber, so a worker
  started against a test queue keeps running against it.``
  [w]
  (when (not (w :stopped)) (break w))
  (put w :stopped false)
  (put w :stop-chan (ev/chan 1))
  (def sup (ev/chan (+ 4 (w :concurrency))))
  (put w :sup sup)
  (array/clear (w :fibers))
  (def q (w :queue))
  (defn spawn [f name]
    (array/push (w :fibers)
                (ev/go (fn worker-fiber []
                         (with-dyns [state/queue-dyn q]
                           (f w)))
                       nil sup)))
  (for i 0 (w :concurrency) (spawn runner :runner))
  (when (backend/supports-heartbeat? (get-in w [:queue :backend]))
    (spawn heartbeat :heartbeat))
  (spawn reaper :reaper)
  (def caps (backend/capabilities (get-in w [:queue :backend])))
  (log/info "jobs worker started" :ns log-ns
            :id (w :id) :queues (w :queues) :concurrency (w :concurrency)
            :backend (caps :name) :shared (caps :shared)
            :claim-ttl (w :claim-ttl))
  (unless (caps :heartbeat)
    (log/warn "this backend cannot refresh a claim: [:jobs :claim-ttl] must exceed the slowest job, or a slow job is reaped while it runs"
              :ns log-ns :backend (caps :name) :claim-ttl (w :claim-ttl)))
  w)

(defn stop!
  ``Stop claiming and wait for the jobs in flight, for up to
  `timeout` seconds (default :shutdown-timeout). Returns the number of
  jobs still running when it gave up — zero on a clean drain.``
  [w &opt timeout]
  (when (w :stopped) (break 0))
  (def limit (or timeout (w :shutdown-timeout)))
  (put w :stopped true)
  (when-let [ch (w :stop-chan)] (ev/chan-close ch))
  (def sup (w :sup))
  (def deadline (+ (os/clock :monotonic) limit))
  (var left (length (w :fibers)))
  (while (and (pos? left) (< (os/clock :monotonic) deadline))
    (def sup2 (ev/chan 1))
    (def task (ev/go (fn waiter [] (ev/take sup)) nil sup2))
    (ev/deadline (max 0.01 (- deadline (os/clock :monotonic))) task task)
    (def [sig _] (ev/take sup2))
    # :ok is the waiter handing over one fiber's exit — count it
    # drained, whatever the fiber's last value was (a runner's is nil).
    # :error is the deadline cancelling the waiter: time is up
    (if (= :ok sig) (-- left) (break)))
  (def stuck (length (w :running)))
  (put w :stop-chan nil)
  (array/clear (w :fibers))
  (if (pos? stuck)
    (log/warn "jobs worker stopped with jobs still running — their claims will be reaped"
              :ns log-ns :id (w :id) :running stuck)
    (log/info "jobs worker stopped" :ns log-ns :id (w :id)
              :completed (get-in w [:stats :completed])
              :failed (get-in w [:stats :failed])
              :dead (get-in w [:stats :dead])))
  stuck)

(defn run!
  ``Start a worker and block until it is stopped — what `void jobs
  work` runs. Returns the worker.``
  [w]
  (start! w)
  (while (not (w :stopped))
    (ev/sleep 0.2))
  w)

# -- the test path -------------------------------------------------------

(defn drain!
  ``Run every job that is runnable *now*, on this fiber, until there
  is nothing left — the shape a test wants:

      (jobs/enqueue :welcome-mail 42)
      (jobs/drain!)

  A job whose :run-at is in the future is not runnable and is left
  alone (bind `:now` forward, or use `:passes` with a sleep between
  them, when that is the point of the test). A queue whose rate limit
  has closed ends the drain rather than sleeping through the window,
  and the job it deferred stays queued. Returns how many ran.``
  [&opt opts]
  (def o (or opts {}))
  (def q (or (get o :queue) (state/active-queue)))
  (def w (make q (merge {:concurrency 1 :id "drain"}
                        (if-let [qs (get o :queues)] {:queues qs} {}))))
  (def limit (get o :limit 10_000))
  (var n 0)
  (var running true)
  (while (and running (< n limit))
    (def r (with-dyns [state/queue-dyn q] (claim-one w)))
    (if r
      (do (with-dyns [state/queue-dyn q] (run-one! w r)) (++ n))
      (set running false)))
  n)

(defn stats
  "What this worker has done: claims, completions, failures, deaths,
  rate-limit deferrals, timeouts and reaps, plus what is in flight."
  [w]
  (merge {:id (w :id)
          :queues (w :queues)
          :concurrency (w :concurrency)
          :running (length (w :running))
          :paused (tuple ;(sorted (keys (w :paused))))}
         (table/to-struct (w :stats))))
