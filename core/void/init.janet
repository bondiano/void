### void — application entrypoint.
###
### (void/run! {:plugins [...] :profile :prod}) = bootstrap phases 1-5,
### start phases 6-7, then park on a stop channel until a POSIX signal
### (SIGTERM/SIGINT by default) or (void/stop! boot) requests a
### graceful shutdown with a per-component timeout. Blocks the calling
### fiber, not the event loop — netrepl sessions, the bus and every
### component fiber keep running underneath.

(import ./core/init :as core)
(import ./core/plugin :as plugin)

(def version core/version)

(def- allowed-run-opts
  {:plugins true :plugins-for true :profile true :config true
   :signals true :shutdown-timeout true})

(defn stop!
  "Request a graceful stop of a system parked in run!, from any fiber
  (a netrepl session, a component, a hook). Returns the boot value."
  [boot &opt reason]
  (def c (or (get boot :stop-chan)
             (error "boot is not running under void/run! — use plugin/shutdown!")))
  (ev/give c (or reason :stop))
  boot)

(defn run!
  ``Run an application until it is told to stop:

      (void/run!
        {:plugins [void/dev my-app/module]
         :profile (keyword (or (os/getenv "VOID_PROFILE") "dev"))})

  Options: :plugins / :profile / :config as in plugin/bootstrap, plus
    :plugins-for       (fn [profile] plugins) — the composition as a
                       function of the profile. When present it wins
                       over :plugins, and it is the contract the CLI
                       honors too, so `void dev --profile prod` and
                       `VOID_PROFILE=prod janet main.janet` are the
                       same application by construction
    :signals           signals that trigger a graceful stop
                       (default [:term :int])
    :shutdown-timeout  per-component :stop deadline in seconds
                       (default 10)

  Bootstraps and starts the system, installs the signal handlers and
  blocks until a signal arrives or (void/stop! boot) is called — the
  boot value is reachable in the meantime through hooks and the REPL
  tools (plugin/inspect ...). Then restores the signal handlers, runs
  the shutdown (stop hooks + reverse-order component stop) and returns
  the boot value; the stop reason is left in (boot :stop-reason).``
  [opts]
  (unless (dictionary? opts)
    (errorf "run! expects an options dictionary, got %q" opts))
  (eachk k opts
    (unless (in allowed-run-opts k)
      (errorf "run!: unknown option %q (allowed: %s)"
              k (string/join (map |(string/format "%q" $)
                                  (sorted (keys allowed-run-opts)))
                             " "))))
  (def signals (get opts :signals [:term :int]))
  (def timeout (get opts :shutdown-timeout 10))
  # signal handlers go in before anything starts: a signal racing the
  # startup must queue a graceful stop, not kill the process half-way
  (def stop-chan (ev/chan 4))
  (each sig signals
    (os/sigaction sig (fn on-signal [&] (ev/give stop-chan sig)) true))
  (def plugins
    (if-let [f (get opts :plugins-for)]
      (do
        (unless (function? f)
          (errorf "run!: :plugins-for must be (fn [profile] plugins), got %q" f))
        (f (get opts :profile :dev)))
      (get opts :plugins)))
  (def boot-opts
    {:plugins plugins :profile (get opts :profile) :config (get opts :config)})
  (defer (each sig signals (os/sigaction sig nil))
    (def boot
      (plugin/start!
        (tabseq [k :in [:plugins :profile :config]
                 :when (not (nil? (get boot-opts k)))]
          k (boot-opts k))))
    (put boot :stop-chan stop-chan)
    (def reason (ev/take stop-chan))
    (put boot :stop-chan nil)
    (put boot :stop-reason reason)
    (plugin/shutdown! boot timeout)
    boot))
