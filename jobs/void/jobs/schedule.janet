### void/jobs/schedule — repeatable jobs (SPEC.md §5.12, ADR-0012,
### ROADMAP 2.4).
###
###     (jobs/defschedule nightly-report
###       "0 3 * * *"
###       :publish-report {:args ["yesterday"] :queue :reports})
###
###     (jobs/defschedule heartbeat {:every 30} :ping)
###
### A schedule is not a job: it is a rule that enqueues one. The
### crontab spelling is spork/cron's (with its optional seconds field),
### `{:every n}` is every n seconds, and either way the scheduler
### enqueues an ordinary record that an ordinary worker runs — which is
### why a scheduled job retries, times out and lands in the dead letter
### queue exactly like a hand-enqueued one.
###
### Two things a cron in a fleet has to get right, and this is how:
###
### **Once, not once per process.** Every occurrence is a *slot* — the
### timestamp the rule names — and firing it takes a lease on
### `jobs:schedule:<name>:<slot>` through the backend's `lock!`. Whoever
### gets the lease enqueues; everyone else moves on. The lease is keyed
### by the slot rather than by the schedule, so a lease that outlives
### its holder cannot stop the *next* occurrence, only a duplicate of
### this one. On a backend with no shared lock (the in-process one),
### the lock is per process and the scheduler says so at boot: it is
### right for one process and wrong for a fleet, and that has to be a
### sentence somebody reads rather than a surprise.
###
### **Late, not repeatedly.** A process that was down for six hours
### comes back to six missed hourly slots. Firing all six is almost
### never what an hourly report wanted, so only the most recent missed
### slot fires and the rest are logged as skipped. A schedule that
### genuinely must not miss an occurrence is not a cron — it is a job
### that enqueues the next one at the end of its own run.
###
### Times are UTC by default. A schedule in local time shifts twice a
### year, runs an hour twice in the autumn and not at all in the
### spring, and every one of those is a bug someone has to be paged
### for; `{:cron "0 3 * * *" :local true}` opts into it deliberately.

(import spork/cron)
(import void/core/log :as log)
(import ./state :as state)

(def log-ns "void.jobs.schedule")

(def defaults
  "Defaults of the [:jobs :scheduler] slice."
  {:enabled false
   :interval 1
   :lock-ttl 60})

(def- allowed-opts
  {:args true :queue true :priority true :max-attempts true :backoff true
   :timeout true :group true :enabled true :on-start true})

(def registry
  "Schedules by name. Redefining a name replaces the schedule — a
  reloaded module changes when a job fires without a restart."
  @{})

# -- the rule ------------------------------------------------------------

(def- allowed-spec-keys {:every true :cron true :local true})

(defn- parse-spec [name spec]
  (when (and (dictionary? spec) (not (indexed? spec)))
    (eachk k spec
      (unless (in allowed-spec-keys k)
        # :on-start and :args belong to the options, one argument
        # further along, and a rule that quietly ignored them would be
        # a schedule that quietly never fires the way it was asked to
        (errorf "schedule %q: %q is not part of the rule (the rule takes :cron, :every and :local; everything else is an option, after the job name)"
                name k))))
  (cond
    (string? spec)
    {:kind :cron :cron (cron/parse-cron spec) :source spec :local false}

    (dictionary? spec)
    (cond
      (get spec :every)
      (let [n (spec :every)]
        (unless (and (number? n) (pos? n))
          (errorf "schedule %q: :every must be a positive number of seconds, got %q" name n))
        {:kind :every :every n :source (string/format "every %gs" n)})

      (get spec :cron)
      (let [c (spec :cron)]
        (unless (string? c)
          (errorf "schedule %q: :cron must be a crontab string, got %q" name c))
        {:kind :cron :cron (cron/parse-cron c) :source c
         :local (truthy? (get spec :local))})

      (errorf "schedule %q: expected a crontab string, {:cron ...} or {:every seconds}, got %q"
              name spec))

    (errorf "schedule %q: expected a crontab string, {:cron ...} or {:every seconds}, got %q"
            name spec)))

(defn define!
  ``Register a schedule (the runtime half of `defschedule`):

      (schedule/define! :nightly "0 3 * * *" :publish-report
                        {:args ["yesterday"] :queue :reports})

  Options: :args (the job's arguments), :enabled, :on-start (fire once
  as soon as the scheduler starts, as well as on the schedule), and
  the enqueue keys :queue :priority :max-attempts :backoff :timeout
  :group.``
  [name spec job-name &opt opts0]
  (unless (keyword? name)
    (errorf "schedule name must be a keyword, got %q" name))
  (unless (keyword? job-name)
    (errorf "schedule %q: the job must be named by keyword, got %q" name job-name))
  (def opts (or opts0 {}))
  (eachk k opts
    (unless (in allowed-opts k)
      (errorf "schedule %q: unknown option %q (allowed: %s)"
              name k (string/join (map |(string/format "%q" $)
                                       (sorted (keys allowed-opts))) " "))))
  (def args (get opts :args []))
  (unless (indexed? args)
    (errorf "schedule %q: :args must be a tuple, got %q" name args))
  (def rule (parse-spec name spec))
  (def s
    (table/to-struct
      (merge @{:name name
               :job job-name
               :args (tuple ;args)
               :enabled (not= false (get opts :enabled))
               :on-start (truthy? (get opts :on-start))
               :enqueue (table/to-struct
                          (table ;(mapcat |[$ (get opts $)]
                                          (filter |(in opts $)
                                                  [:queue :priority :max-attempts
                                                   :backoff :timeout :group]))))}
             rule)))
  (put registry name s)
  s)

(defn defschedule-form
  "The expansion of `defschedule`, as a function — so that the macro
  can exist both here and on `void/jobs` without being written twice."
  [name spec job-name opts]
  ~(def ,name (,define! ,(keyword name) ,spec ,job-name ,;opts)))

(defmacro defschedule
  ``Declare a repeatable job:

      (jobs/defschedule nightly-report
        "0 3 * * *"
        :publish-report {:args ["yesterday"] :queue :reports})

  The name of the schedule is the name of the binding as a keyword;
  the binding itself is the schedule, which is what `void jobs
  schedules` prints and what a test fires by hand.``
  [name spec job-name & opts]
  (defschedule-form name spec job-name opts))

(defn forget!
  "Drop a schedule — for tests, and for a REPL that renamed one."
  [name]
  (put registry name nil))

(defn defined
  "Names of every registered schedule."
  []
  (sorted (keys registry)))

# -- slots ---------------------------------------------------------------

(defn next-slot
  ``The first occurrence strictly after `after`. For :every rules that
  is the next multiple of the interval; for cron rules it is what
  spork/cron computes, at second resolution.``
  [s after]
  (case (s :kind)
    :every (* (s :every) (inc (math/floor (/ after (s :every)))))
    (cron/next-timestamp (s :cron) (math/floor after) (s :local))))

(defn due-slot
  ``The most recent occurrence in (after, now], with how many earlier
  ones were skipped: [slot skipped], or nil when none is due. A
  scheduler that has been asleep fires once and says how much it
  missed — see the module docstring for why that is the right shape.``
  [s after now]
  (var slot nil)
  (var skipped 0)
  (var probe after)
  (var guard 0)
  (while (< guard 10_000)
    (++ guard)
    (def n (next-slot s probe))
    (if (<= n now)
      (do
        (when slot (++ skipped))
        (set slot n)
        (set probe n))
      (break)))
  (when slot [slot skipped]))

(defn next-fire
  "When this schedule fires next, as a timestamp — what `void jobs
  schedules` prints."
  [s &opt from]
  (next-slot s (or from (os/clock :realtime))))

# -- firing --------------------------------------------------------------

(defn- lock-name [s slot]
  (string "jobs:schedule:" (s :name) ":" (math/floor slot)))

(defn fire!
  ``Enqueue this schedule's job for `slot`, if the lease on that slot
  can be taken. Returns the record, or nil when somebody else got
  there first (or the backend refused the lease). The slot is passed
  rather than computed so that a test can fire one by hand.``
  [s slot &opt opts]
  (def o (or opts {}))
  (def b (state/active-backend))
  (def token (get o :token "scheduler"))
  (def ttl (get o :lock-ttl (defaults :lock-ttl)))
  (def got ((b :lock!) (lock-name s slot) ttl token (os/clock :realtime)))
  (if got
    (let [r (state/enqueue-with (s :enqueue) (s :job) ;(s :args))]
      (log/info "schedule fired" :ns log-ns
                :schedule (s :name) :job (s :job) :id (r :id)
                :slot (math/floor slot))
      r)
    (do
      (log/debug "schedule slot was taken by another process" :ns log-ns
                 :schedule (s :name) :slot (math/floor slot))
      nil)))

(defn tick!
  ``One pass of the scheduler: fire every schedule whose slot has
  arrived since the last pass. `cursors` is the table the caller keeps
  between passes (name -> the last slot it saw); the first pass over a
  schedule only records where the clock is, so that starting a process
  at 03:05 does not fire the 03:00 report — except for a schedule
  declared `:on-start`, which fires once right there.

  Returns the records it enqueued.``
  [cursors &opt opts]
  (def o (or opts {}))
  (def now (get o :now (os/clock :realtime)))
  (def out @[])
  (each name (sorted (keys registry))
    (def s (get registry name))
    (when (s :enabled)
      (def seen (get cursors name))
      (cond
        (nil? seen)
        (do
          (put cursors name now)
          (when (s :on-start)
            (when-let [r (fire! s now o)] (array/push out r))))

        (when-let [[slot skipped] (due-slot s seen now)]
          (put cursors name slot)
          (when (pos? skipped)
            (log/warn "schedule fell behind — only the most recent occurrence fires"
                      :ns log-ns :schedule name :skipped skipped))
          (when-let [r (fire! s slot o)] (array/push out r))))))
  (tuple ;out))

# -- the loop ------------------------------------------------------------

(defn make
  "Build a scheduler value over the active queue. Nothing runs until
  `start!`."
  [q &opt opts]
  (def o (merge defaults (or opts {})))
  @{:queue q
    :interval (o :interval)
    :lock-ttl (o :lock-ttl)
    :token (string "sched-" (string/slice (string (math/floor (* 1000 (os/clock :realtime)))) -7))
    :cursors @{}
    :stopped true
    :stop-chan nil
    :fired 0})

(defn- wait-or-stop [sc seconds]
  (def ch (sc :stop-chan))
  (if (or (sc :stopped) (nil? ch))
    nil
    (do
      (def sup (ev/chan 1))
      (def task (ev/go (fn stop-waiter [] (ev/take ch)) nil sup))
      (ev/deadline seconds task task)
      (ev/take sup)
      nil)))

(defn start!
  "Start the scheduler fiber."
  [sc]
  (unless (sc :stopped) (break sc))
  (put sc :stopped false)
  (put sc :stop-chan (ev/chan 1))
  (def q (sc :queue))
  (def shared (get-in q [:backend :shared-locks?]))
  (log/info "jobs scheduler started" :ns log-ns
            :schedules (defined) :interval (sc :interval)
            :locks (if shared :shared :process))
  (unless shared
    (log/warn "this backend has no shared lock: a schedule fires once per process, which is right for one process and duplicated across a fleet"
              :ns log-ns :backend (get-in q [:backend :name])))
  (ev/go
    (fn scheduler-fiber []
      (with-dyns [state/queue-dyn q]
        (while (not (sc :stopped))
          (def [ok e]
            (protect
              (do
                (def fired (tick! (sc :cursors)
                                  {:token (sc :token) :lock-ttl (sc :lock-ttl)}))
                (put sc :fired (+ (sc :fired) (length fired))))))
          (unless ok
            (log/error "scheduler pass failed" :ns log-ns
                       :err (if (string? e) e (describe e))))
          (wait-or-stop sc (sc :interval))))))
  sc)

(defn stop!
  "Stop the scheduler fiber."
  [sc]
  (when (sc :stopped) (break sc))
  (put sc :stopped true)
  (when-let [ch (sc :stop-chan)] (ev/chan-close ch))
  (put sc :stop-chan nil)
  (log/info "jobs scheduler stopped" :ns log-ns :fired (sc :fired))
  sc)

(defn status
  ``Every schedule with when it fires next — what `void jobs
  schedules` prints.``
  [&opt from]
  (def t (or from (os/clock :realtime)))
  (seq [name :in (defined) :let [s (get registry name)]]
    {:name name :job (s :job) :spec (s :source)
     :enabled (s :enabled)
     :next (next-fire s t)
     :in (- (next-fire s t) t)}))
