### void/http/prefork — multi-core via preforked worker processes
### (ADR-0010, ROADMAP 1.1).
###
### N worker processes × SO_REUSEPORT: janet's net/listen already sets
### SO_REUSEPORT (and SO_REUSEADDR) on platforms that have it, so every
### worker binds the same host:port and the kernel spreads accepts —
### no shared state between workers, GC pauses isolated per process
### (the unicorn/gunicorn model). The master process re-execs its own
### command line (`(dyn :executable)` + `(dyn :args)`) with
### VOID_HTTP_WORKER=<i> in the environment; a worker process boots the
### same application, sees `worker?` and actually listens. The master
### only supervises: a worker that dies is respawned after :backoff
### seconds, stop sends SIGTERM (each worker's void/run! drains
### gracefully) and escalates to SIGKILL at the deadline.
###
### ADR-0010 honesty: with workers > 1 nothing in-process is shared —
### memory sessions, caches and rate limits must live in an external
### store; void/http/init refuses memory sessions in prefork mode.

(def worker-env
  "Environment variable marking a worker process (value: worker index)."
  "VOID_HTTP_WORKER")

(defn worker?
  "Is this process a prefork worker?"
  []
  (not (nil? (os/getenv worker-env))))

(defn worker-index
  "This worker's index, nil in the master."
  []
  (when-let [v (os/getenv worker-env)]
    (scan-number v)))

(defn- detected-cpus []
  (def [ok out]
    (protect
      (with [p (os/spawn ["sysctl" "-n" "hw.ncpu"] :px {:out :pipe})]
        (def s (ev/read (p :out) :all))
        (os/proc-wait p)
        (scan-number (string/trim (string s))))))
  (if ok out nil))

(defn worker-count
  ":workers config to a number: :auto means one per CPU (os/cpu-count,
  falling back to sysctl, falling back to 1)."
  [workers]
  (cond
    (= :auto workers) (or (os/cpu-count) (detected-cpus) 1)
    (and (int? workers) (pos? workers)) workers
    (errorf ":workers must be a positive integer or :auto, got %q" workers)))

(defn- spawn-worker [cmd base-env i]
  (os/spawn cmd :ep (merge base-env {worker-env (string i)})))

(defn start
  ``Start the prefork master: spawn and supervise :workers processes.

  Options:
    :workers  positive int or :auto (required)
    :cmd      worker command line; defaults to this process's own
              (janet executable + args) — override for tests or exotic
              entrypoints
    :env      extra environment entries for workers
    :backoff  seconds between a worker death and its respawn
              (default 1)
    :on-exit  (fn [i status]) called when a worker exits unexpectedly
              (default logs to stderr)

  Returns the master instance: :procs (index -> process), :workers,
  :stopping. Not for worker processes — callers branch on worker?.``
  [opts]
  (def n (worker-count (or (opts :workers) (error "prefork/start requires :workers"))))
  (def cmd (or (opts :cmd)
               [(dyn :executable) ;(or (dyn :args) [])]))
  (def base-env (merge (os/environ) (get opts :env {})))
  (def backoff (get opts :backoff 1))
  (def on-exit (get opts :on-exit
                    (fn [i status]
                      (eprintf "http worker %d exited with %q — respawning" i status))))
  (def inst @{:procs @{} :workers n :stopping false :cmd cmd})
  (defn supervise [i]
    (fn supervisor []
      (while (not (inst :stopping))
        (def p (get-in inst [:procs i]))
        (unless p (break))
        (def status (os/proc-wait p))
        (put-in inst [:procs i] nil)
        (when (not (inst :stopping))
          (on-exit i status)
          (ev/sleep backoff)
          (unless (inst :stopping)
            (put-in inst [:procs i] (spawn-worker cmd base-env i)))))))
  (for i 0 n
    (put-in inst [:procs i] (spawn-worker cmd base-env i))
    (ev/go (supervise i)))
  inst)

(defn alive
  "Indexes of currently running workers."
  [inst]
  (sorted (keys (inst :procs))))

(defn stop
  ``Stop the master: SIGTERM every worker (its own void/run! handles
  the graceful drain), wait up to `timeout` seconds (default 15), then
  SIGKILL the stragglers. Returns the instance.``
  [inst &opt timeout]
  (default timeout 15)
  (put inst :stopping true)
  (each i (keys (inst :procs))
    (when-let [p (get-in inst [:procs i])]
      (protect (os/proc-kill p false :term))))
  (def deadline (+ (os/clock :monotonic) timeout))
  (while (and (pos? (length (inst :procs)))
              (< (os/clock :monotonic) deadline))
    (ev/sleep 0.05))
  (each i (keys (inst :procs))
    (when-let [p (get-in inst [:procs i])]
      (protect (os/proc-kill p false :kill))
      (protect (os/proc-wait p))
      (put-in inst [:procs i] nil)))
  inst)
