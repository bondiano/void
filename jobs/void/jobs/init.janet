### void/jobs — the background jobs plugin (SPEC.md §5.12, ADR-0012).
###
### Two interfaces and one runtime. `:void/jobs-backend` is storage —
### eight functions over records, one of which has to be atomic
### (./backend); `:void/jobs` is what an application depends on, and it
### is the layer that turns storage into a queue: policy resolution,
### the enqueue funnel, the lifecycle events (./state). Everything that
### decides *what happens* — how many attempts, how long to wait, which
### job runs next, what a timeout does — lives in the runtime and is
### the same whichever backend is underneath, which is the whole point
### of having a contract rather than three queues. What lives where:
###
###   ./job       `defjob`, the definition registry, backoff policy
###   ./record    the queued job: fields, states, transitions
###   ./backend   the :void/jobs-backend contract and its fallbacks
###   ./memory    the in-process backend: a heap-sized queue
###   ./state     the queue an application talks to — enqueue, events
###   ./worker    the executor: fibers that claim, run and settle
###   ./flow      parent-child job graphs
###   ./schedule  `defschedule`, cron, and firing once across a fleet
###
### Four components. `:jobs/memory` is the backend this plugin ships
### and the default; `:jobs/queue` is the queue over whichever
### `:void/jobs-backend` is active; `:jobs/worker` and `:jobs/scheduler`
### are off by default and are what a process turns on when it is the
### one doing the work:
###
###     (void/run! {:plugins [:void/jobs :void/jobs-redis ...]})
###     # config/prod.janet — the web process
###     {:void/jobs-backend {:impl :jobs/redis}
###      :jobs {:queues {:mail {:concurrency 2
###                             :rate-limit {:max 100 :duration 60}}}}}
###     # config/worker.janet — the process started by `void jobs work`
###     {:jobs {:worker {:enabled true :concurrency 10}
###             :scheduler {:enabled true}}}
###
### A job may also say what it needs *open* — `{:needs [:tls/lib]}` —
### and `void jobs work` starts the union of that over the queues it
### serves. `:jobs/queue` is what the **worker** needs; a delivery over
### https needs the TLS stack, which the queue does not depend on and
### which a command that named only the queue therefore leaves composed
### and unstarted (./job, and ROADMAP 6.6 for how that reads from the
### outside).
###
### Adding void/jobs-db or void/jobs-redis puts a second component on
### `:void/jobs-backend`, which is the ambiguity the kernel refuses to
### resolve on its own — the application names the one it means,
### exactly as it does with two database drivers.
###
### Applications import `void/jobs` and nothing below it:
###
###     (import void/jobs :as jobs)
###     (jobs/defjob welcome-mail {:queue :mail} [id] ...)
###     (jobs/enqueue :welcome-mail 42)
###     (jobs/enqueue-in 3600 :welcome-mail 42)
###     (jobs/flow {:job :publish :children [...]})
###     (jobs/defschedule nightly "0 3 * * *" :publish-report)

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import ./backend :as backend)
(import ./flow :as flow)
(import ./job :as job)
(import ./memory :as memory)
(import ./record :as record)
(import ./schedule :as schedule)
(import ./state :as state)
(import ./worker :as worker)

(def log-ns
  "Log namespace — spelled out, since the file-derived default would
  carry the install path."
  "void.jobs")

# -- the interfaces ------------------------------------------------------

(plugin/contribute! :void.core/interface
  {:name :void/jobs
   :doc "A job queue: the :jobs/queue component's value — a backend plus the resolved policy layers (defaults, [:jobs], per-queue, per-job). Depend on the interface rather than the key to let a test stand a queue of its own in its place."
   :methods {:backend "the :void/jobs-backend underneath"
             :queues "the per-queue configuration"
             :defaults "the policy a job gets when nothing overrides it"}})

(plugin/contribute! :void.core/interface
  {:name :void/jobs-backend
   :doc "Job persistence: {:push! :claim! :settle! :fetch :list :counts :remove! :clear!} plus the optional :reap!, :touch!, :lock!/:unlock!, :rate-take! and :release-parent! keys (see void/jobs/backend). A backend component declares :provides [:void/jobs-backend]; {:void/jobs-backend {:impl <key>}} picks between several."
   :methods {:push! "(fn [job] job-or-nil) — nil when a unique key is held"
             :claim! "(fn [opts] job-or-nil) — atomic, or the queue is not one"
             :settle! "(fn [job] job) — write a record back in its new state"
             :counts "(fn [] {queue {state n}})"}})

# -- config --------------------------------------------------------------

(def Backoff
  "Schema of a retry backoff policy."
  {:strategy [:optional [:enum :fixed :linear :exponential]]
   :base [:optional [:number {:min 0}]]
   :max [:optional [:number {:min 0}]]
   :jitter [:optional [:number {:min 0 :max 1}]]})

(def QueueConfig
  "Schema of one [:jobs :queues :<name>] slice — what this queue is
  for, as opposed to what one job in it needs."
  {:concurrency [:optional [:int {:min 1}]]
   :group-concurrency [:optional [:int {:min 1}]]
   :rate-limit [:optional {:max [:optional [:int {:min 1}]]
                           :duration [:optional [:number {:min 0.001}]]}]
   :priority [:optional :int]
   :max-attempts [:optional [:int {:min 1}]]
   :backoff [:optional Backoff]
   :timeout [:optional [:number {:min 0.001}]]})

(def Config
  "Schema of the [:jobs] config slice."
  {:enabled [:optional :boolean]
   :priority [:optional :int]
   :max-attempts [:optional [:int {:min 1}]]
   :backoff [:optional Backoff]
   :timeout [:optional [:number {:min 0.001}]]
   # how long a claim may go unrefreshed before a reaper decides the
   # worker holding it is gone
   :claim-ttl [:optional [:number {:min 1}]]
   :queues [:optional [:map-of :keyword QueueConfig]]
   :worker [:optional {:enabled [:optional :boolean]
                       :queues [:optional [:vector :keyword]]
                       :concurrency [:optional [:int {:min 1}]]
                       :poll-interval [:optional [:number {:min 0.001}]]
                       :shutdown-timeout [:optional [:number {:min 0}]]}]
   :scheduler [:optional {:enabled [:optional :boolean]
                          :interval [:optional [:number {:min 0.001}]]
                          :lock-ttl [:optional [:number {:min 1}]]}]
   :memory [:optional {:max-completed [:optional [:int {:min 0}]]
                       :max-dead [:optional [:int {:min 0}]]}]})

(def defaults
  ``Defaults of the [:jobs] slice. Three attempts with exponential
  backoff is the shape almost every queue wants and almost none
  states; the worker and the scheduler are off because the process
  that enqueues is usually not the process that runs — turning them on
  is one line, and a `void dev` that quietly started a worker would be
  a surprise in the wrong direction.``
  {:enabled true
   :priority 5
   :max-attempts 3
   :backoff job/default-backoff
   :claim-ttl 60
   :queues {}
   :worker worker/defaults
   :scheduler schedule/defaults
   :memory memory/defaults})

(defn- slice [cfg0]
  (def cfg (merge defaults (or cfg0 {})))
  (each k [:worker :scheduler :memory]
    (put cfg k (merge (defaults k) (get (or cfg0 {}) k {}))))
  cfg)

# -- public surface (re-exports) -----------------------------------------

(def Backend "See backend/normalize — the :void/jobs-backend contract." backend/normalize)
(def backend-capabilities "See backend/capabilities — what a backend can actually do." backend/capabilities)

(def define-job! "See job/define! — the runtime half of defjob." job/define!)
(def job-definitions "See job/defined — names of every declared job." job/defined)
(def job-of "See job/lookup — the definition behind a name." job/lookup)
(def forget-job! "See job/forget!." job/forget!)
(def job-needs! "See job/needs! — declare what a job's work needs open, after the fact." job/needs!)
(def job-needs "See job/needs — the components the definitions on these queues declare." job/needs)
(def job-handler "See job/handler — the function behind a definition, resolved now." job/handler)
(def retry-delay "See job/retry-delay — the wait before the next attempt." job/retry-delay)
(def default-backoff "See job/default-backoff." job/default-backoff)

(defmacro defjob
  ``Define a job — a function plus the policy for running it in the
  background (see void/jobs/job):

      (jobs/defjob welcome-mail
        "Send the welcome mail."
        {:queue :mail :max-attempts 5 :timeout 30 :unique :args}
        [user-id]
        (mail/send (users/find user-id) :welcome))``
  [name & more]
  (job/defjob-form name more))

(def make-record "See record/make — a pending record from resolved policy." record/make)
(def record-states "See record/states." record/states)
(def record-live-states "See record/live-states — the states that still owe work." record/live-states)
(def record-fields "See record/fields — every field of a record, in a stable order." record/fields)
(def record-summary "See record/summary — one line for a listing." record/summary)
(def record-age "See record/ago — the age of a record as one column: \"42s\", \"3h\"." record/ago)

(def memory-backend "See memory/store — the in-process backend." memory/store)
(def make-memory "See memory/make — the table behind one." memory/make)

(def queue-dyn "See state/queue-dyn — the queue override." state/queue-dyn)
(def active-queue "See state/active-queue." state/active-queue)
(def active-backend "See state/active-backend." state/active-backend)
(def make-queue "See state/make — a queue value without a bootstrap." state/make)
(def queue-names "See state/queue-names." state/queue-names)
(def queue-config "See state/queue-config — one queue's slice." state/queue-config)
(def resolve-policy "See state/resolve-policy — the five layers, resolved." state/resolve-policy)

(def enqueue "See state/enqueue — queue a job by name." state/enqueue)
(def enqueue-with "See state/enqueue-with — queue with per-call overrides." state/enqueue-with)
(def enqueue-in "See state/enqueue-in — queue with a delay." state/enqueue-in)
(def enqueue-at "See state/enqueue-at — queue for an absolute time." state/enqueue-at)
(def perform "See state/perform — run a job here and now, no queue." state/perform)

(def current-job "See state/current-job — the record this handler runs under." state/current-job)
(def attempt "See state/attempt — which attempt this is." state/attempt)
(def last-attempt? "See state/last-attempt? — is a failure now final?" state/last-attempt?)
(def children "See state/children — what this job's children returned." state/children)

(def fetch "See state/fetch — the record with this id." state/fetch)
(def list-jobs "See state/list-jobs — records matching {:queue :state :job}." state/list-jobs)
(def counts "See state/counts — records per queue per state." state/counts)
(def remove-job! "See state/remove-job!." state/remove-job!)
(def clear! "See state/clear! — drop records by queue and state." state/clear!)
(def retry! "See state/retry! — put a dead record back in the queue." state/retry!)
(def stats "See state/stats." state/stats)

(def event-hook "See state/event-hook — the hook lifecycle events run through." state/event-hook)
(def events "See state/events — every event the runtime fires." state/events)
(def listen! "See state/listen! — hear about job events without a manifest." state/listen!)
(def unlisten! "See state/unlisten!." state/unlisten!)
(def emit! "See state/emit!." state/emit!)

(def make-worker "See worker/make — a worker over a queue." worker/make)
(def start-worker! "See worker/start!." worker/start!)
(def stop-worker! "See worker/stop! — drain, then give up on what is left." worker/stop!)
(def run-worker! "See worker/run! — start and block, as `void jobs work` does." worker/run!)
(def worker-stats "See worker/stats." worker/stats)
(def reap! "See worker/reap-once! — take over abandoned claims now." worker/reap-once!)
(def drain! "See worker/drain! — run everything runnable now, on this fiber." worker/drain!)

(def flow "See flow/flow — enqueue a parent-child job graph." flow/flow)
(def pending-children "See flow/pending-children." flow/pending-children)

(def define-schedule! "See schedule/define! — the runtime half of defschedule." schedule/define!)
(def schedules "See schedule/defined — names of every declared schedule." schedule/defined)
(def schedule-of "See schedule/registry." schedule/registry)
(def forget-schedule! "See schedule/forget!." schedule/forget!)
(def schedule-status "See schedule/status — every schedule with its next firing." schedule/status)
(def next-fire "See schedule/next-fire." schedule/next-fire)
(def fire-schedule! "See schedule/fire! — enqueue one slot by hand." schedule/fire!)

(defmacro defschedule
  ``Declare a repeatable job (see void/jobs/schedule):

      (jobs/defschedule nightly-report
        "0 3 * * *"
        :publish-report {:args ["yesterday"] :queue :reports})``
  [name spec job-name & opts]
  (schedule/defschedule-form name spec job-name opts))

# -- the in-process backend component ------------------------------------

(def memory-component
  (system/component :jobs/memory
    :doc "The in-process job backend: a table of records in this
    process's heap, with real retries, real delays and real flows, and
    nothing left after a restart. The default backend, and the one an
    application starts with — swapping it for the database or redis is
    a config line once void/jobs-db or void/jobs-redis is in the
    composition."
    :provides [:void/jobs-backend]
    :config {:key :jobs :schema Config}
    :start
    (fn start [_ cfg0]
      (def cfg (slice cfg0))
      (def m (memory/make (cfg :memory)))
      (log/info "jobs memory backend ready" :ns log-ns
                :max-completed (get-in cfg [:memory :max-completed])
                :max-dead (get-in cfg [:memory :max-dead]))
      (memory/store m))
    :stop
    (fn stop [b] ((b :close)))
    :health
    (fn health [b] (merge {:status :up} ((b :stats))))))

# -- the queue component -------------------------------------------------

(def queue-component
  (system/component :jobs/queue
    :doc "The queue over the active :void/jobs-backend: the policy
    layers a job is resolved through, the enqueue funnel, and the
    lifecycle events. This is what an application depends on; running
    the jobs is the worker's business, and a process may perfectly
    well enqueue without ever starting one."
    :deps [:void/jobs-backend]
    :provides [:void/jobs]
    :config {:key :jobs :schema Config}
    :start
    (fn start [deps cfg0]
      (def cfg (slice cfg0))
      (def b (deps :void/jobs-backend))
      (def q (state/make b cfg))
      (set state/current-queue q)
      (def caps (backend/capabilities (q :backend)))
      (log/info "jobs queue ready" :ns log-ns
                :backend (caps :name) :shared (caps :shared)
                :queues (state/queue-names q)
                :jobs (job/defined)
                :max-attempts (get-in q [:defaults :max-attempts])
                :enabled (not= false (cfg :enabled)))
      (unless (not= false (cfg :enabled))
        (log/warn "[:jobs :enabled] is false — enqueued jobs run inline, on the caller's fiber"
                  :ns log-ns))
      q)
    :stop
    (fn stop [_]
      (set state/current-queue nil))
    :health
    (fn health [q]
      (merge {:status :up}
             {:backend (get-in q [:backend :name])
              :counts (with-dyns [state/queue-dyn q] (state/counts))}))))

# -- the worker component ------------------------------------------------

(def worker-component
  (system/component :jobs/worker
    :doc "The executor: `[:jobs :worker :concurrency]` fibers claiming
    and running jobs, plus the heartbeat that keeps their claims fresh
    and the reaper that picks up the claims of workers that died. Off
    by default — a process starts one by saying so, and `void jobs
    work` is the same worker in the foreground."
    :deps [:void/jobs]
    :config {:key :jobs :schema Config}
    :start
    (fn start [deps cfg0]
      (def cfg (slice cfg0))
      (def wcfg (cfg :worker))
      (def q (deps :void/jobs))
      (if (get wcfg :enabled)
        (worker/start! (worker/make q wcfg))
        (do
          (log/debug "jobs worker not started ([:jobs :worker :enabled] is false)"
                     :ns log-ns)
          @{:stopped true :disabled true :running @{}})))
    :stop
    (fn stop [w]
      (unless (get w :disabled)
        (worker/stop! w)))
    :health
    (fn health [w]
      (if (get w :disabled)
        {:status :up :worker :disabled}
        (merge {:status :up} (worker/stats w))))))

# -- the scheduler component ---------------------------------------------

(def scheduler-component
  (system/component :jobs/scheduler
    :doc "Repeatable jobs: a ticker that fires every `defschedule`
    whose slot has arrived, taking a lease on the slot so that a fleet
    of processes enqueues it once. Off by default, and meant to be on
    in exactly the processes that should be firing schedules."
    :deps [:void/jobs]
    :config {:key :jobs :schema Config}
    :start
    (fn start [deps cfg0]
      (def cfg (slice cfg0))
      (def scfg (cfg :scheduler))
      (def q (deps :void/jobs))
      (if (get scfg :enabled)
        (schedule/start! (schedule/make q scfg))
        (do
          (log/debug "jobs scheduler not started ([:jobs :scheduler :enabled] is false)"
                     :ns log-ns)
          @{:stopped true :disabled true})))
    :stop
    (fn stop [sc]
      (unless (get sc :disabled)
        (schedule/stop! sc)))
    :health
    (fn health [sc]
      (if (get sc :disabled)
        {:status :up :scheduler :disabled}
        {:status :up :schedules (length schedule/registry) :fired (sc :fired)}))))

(plugin/contribute! :void.core/store
  {:name :void.jobs/backend
   :what "the job queue"
   :needs [:jobs/queue]
   :doc "Where enqueued jobs live — the vocabulary was already there (backend/capabilities :shared), only the caller was missing"
   :ask (fn ask-jobs [boot]
          (when-let [q (get-in boot [:system :instances :jobs/queue])]
            (def b (q :backend))
            {:store (get b :name :anonymous)
             :shared? (truthy? (get b :shared?))
             # two failures, and the second is the quiet one: a
             # schedule is a lock, and a per-process backend has no
             # lock to take
             :replacement "compose void/jobs-db ({:void/jobs-backend {:impl :jobs/db}}) or void/jobs-redis — otherwise a job enqueued on one replica never reaches another replica's worker, and every defschedule fires once per replica"}))})

# -- CLI -----------------------------------------------------------------

(defn- with-queue [q f]
  (with-dyns [state/queue-dyn q] (f)))

(defn- flags
  "Parse --key VALUE pairs into a table, with `parse` deciding the
  value type per flag. Anything unknown is an error naming what is."
  [command args spec]
  (def out @{})
  (var i 0)
  (while (< i (length args))
    (def a (args i))
    (def key (get spec a))
    (unless key
      (errorf "%s: unknown flag %q (known: %s)"
              command a (string/join (sorted (keys spec)) " ")))
    (unless (< (inc i) (length args))
      (errorf "%s: %s needs a value" command a))
    (put out (key 0) ((key 1) (args (inc i))))
    (+= i 2))
  out)

(def- as-keyword |(keyword $))
(def- as-number |(or (scan-number $) (errorf "expected a number, got %q" $)))
(def- as-string |$)
(def- as-keywords |(tuple ;(map keyword (string/split "," $))))

(plugin/contribute! :void.core/cli
  {:name :jobs/stats
   :read-only? true
   :doc "Show what the queue is holding: void jobs stats"
   :needs [:jobs/queue]
   :fn (fn cli-stats [q & args]
         (unless (empty? args)
           (errorf "void jobs stats takes no arguments (got %q)" (string/join args " ")))
         (def s (with-queue q state/stats))
         (def caps (s :backend))
         (printf "backend     %q%s" (caps :name)
                 (if (caps :shared) " (shared)" " (this process only)"))
         (printf "flows       %s" (if (caps :flows) "yes" "no"))
         (printf "rate limit  %q" (caps :rate-limit))
         (printf "locks       %q" (caps :locks))
         (printf "enqueued    %d (%d duplicates)" (s :enqueued) (s :duplicates))
         (print)
         (def counts (with-queue q state/counts))
         (if (empty? counts)
           (print "the queue is empty")
           (do
             (printf "%-14s %8s %8s %8s %9s %6s" "queue" "pending" "running" "waiting" "completed" "dead")
             (each qn (sorted (keys counts))
               (def c (counts qn))
               (printf "%-14s %8d %8d %8d %9d %6d"
                       qn (get c :pending 0) (get c :running 0) (get c :waiting 0)
                       (get c :completed 0) (get c :dead 0))))))})

(plugin/contribute! :void.core/cli
  {:name :jobs/list
   :read-only? true
   :doc "List records: void jobs list [--queue Q] [--state S] [--job J] [--limit N]"
   :needs [:jobs/queue]
   :fn (fn cli-list [q & args]
         (def o (flags "void jobs list" args
                       {"--queue" [:queue as-keyword]
                        "--state" [:state as-keyword]
                        "--job" [:job as-keyword]
                        "--limit" [:limit as-number]}))
         (def rows (with-queue q (fn [] (state/list-jobs o))))
         (if (empty? rows)
           (print "no jobs match")
           (do
             (def now (os/clock :realtime))
             (each r rows (print (record/summary r now))))))})

(plugin/contribute! :void.core/cli
  {:name :jobs/show
   :read-only? true
   :doc "Everything about one record: void jobs show ID"
   :needs [:jobs/queue]
   :fn (fn cli-show [q & args]
         (unless (= 1 (length args))
           (error "usage: void jobs show ID"))
         (def r (with-queue q (fn [] (state/fetch (first args)))))
         (unless r
           (errorf "no job with id %q" (first args)))
         (each k record/fields
           (def v (get r k))
           (unless (nil? v)
             (printf "%-14s %q" k v)))
         (each f (get r :failures [])
           (printf "failure %d    %s" (f :attempt) (f :error))))})

(plugin/contribute! :void.core/cli
  {:name :jobs/retry
   :read-only? false
   :doc "Put a record back in the queue: void jobs retry ID | void jobs retry --state dead"
   :needs [:jobs/queue]
   :fn (fn cli-retry [q & args]
         (if (and (= 2 (length args)) (= "--state" (first args)))
           (let [st (keyword (args 1))
                 rows (with-queue q (fn [] (state/list-jobs {:state st :limit 10_000})))]
             (var n 0)
             (each r rows
               (when (with-queue q (fn [] (state/retry! (r :id)))) (++ n)))
             (printf "requeued %d %s" n (if (= 1 n) "job" "jobs")))
           (do
             (unless (= 1 (length args))
               (error "usage: void jobs retry ID | void jobs retry --state dead"))
             (if-let [r (with-queue q (fn [] (state/retry! (first args))))]
               (printf "requeued %s (%s)" (r :id) (r :job))
               (errorf "no job with id %q" (first args))))))})

(plugin/contribute! :void.core/cli
  {:name :jobs/remove
   :read-only? false
   :doc "Drop one record: void jobs remove ID"
   :needs [:jobs/queue]
   :fn (fn cli-remove [q & args]
         (unless (= 1 (length args))
           (error "usage: void jobs remove ID"))
         (if (with-queue q (fn [] (state/remove-job! (first args))))
           (printf "removed %s" (first args))
           (printf "no job with id %q" (first args))))})

(plugin/contribute! :void.core/cli
  {:name :jobs/clear
   :read-only? false
   :doc "Drop records: void jobs clear [--queue Q] [--state S]"
   :needs [:jobs/queue]
   :fn (fn cli-clear [q & args]
         (def o (flags "void jobs clear" args
                       {"--queue" [:queue as-keyword]
                        "--state" [:state as-keyword]}))
         (def n (with-queue q (fn [] (state/clear! o))))
         (printf "dropped %d %s" n (if (= 1 n) "record" "records")))})

(plugin/contribute! :void.core/cli
  {:name :jobs/work
   :read-only? false
   :doc "Run a worker in the foreground: void jobs work [--queues a,b] [--concurrency N]"
   :needs [:jobs/queue]
   :fn (fn cli-work [q & args]
         (def o (flags "void jobs work" args
                       {"--queues" [:queues as-keywords]
                        "--concurrency" [:concurrency as-number]
                        "--poll-interval" [:poll-interval as-number]}))
         (def cfg (slice (get-in plugin/current-boot [:config :values :jobs])))
         (def w (worker/make q (merge (cfg :worker) o)))
         # `:needs [:jobs/queue]` above is true of the worker and not of
         # the **work**: a job that posts to an https API needs
         # `:tls/lib`, which the queue does not depend on and which
         # would therefore sit composed and unstarted in this very
         # process (job/needs, and examples/hub for how that reads from
         # the outside — five attempts and a message about libssl).
         # What the jobs on these queues declare is started here, and
         # `run-command`'s stop takes it down with everything else
         (def extra (job/needs (w :queues) (get-in q [:defaults :queue])))
         (unless (empty? extra)
           (system/start (get plugin/current-boot :system) extra)
           (log/info "started what the work needs" :ns log-ns
                     :queues (w :queues) :needs extra))
         (printf "working %s at concurrency %d — ^C to stop"
                 (string/join (map string (w :queues)) ", ") (w :concurrency))
         (unless (empty? extra)
           (printf "  open for the work: %s"
                   (string/join (map string extra) ", ")))
         (with-queue q (fn [] (worker/run! w))))})

(plugin/contribute! :void.core/cli
  {:name :jobs/schedules
   :read-only? true
   :doc "Every declared schedule and when it fires next: void jobs schedules"
   :fn (fn cli-schedules [& args]
         (unless (empty? args)
           (errorf "void jobs schedules takes no arguments (got %q)" (string/join args " ")))
         (def rows (schedule/status))
         (if (empty? rows)
           (print "no schedules are declared in this process")
           (each s rows
             (printf "%-20s %-18s %-22s in %ds%s"
                     (s :name) (s :spec) (s :job)
                     (math/round (s :in))
                     (if (s :enabled) "" "  (disabled)")))))})

# -- manifest ------------------------------------------------------------

(plugin/defplugin void/jobs
  :doc "Background jobs: the :void/jobs-backend contract, an in-process backend, defjob with retries/backoff/priorities/delays/uniqueness, flows, per-queue rate limiting and concurrency, a dead letter queue, and cron schedules that fire once across a fleet."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :jobs
  :config-schema Config
  :config-defaults defaults
  :components [memory-component queue-component worker-component scheduler-component])
