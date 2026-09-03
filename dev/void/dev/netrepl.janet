### void/dev/netrepl — in-process networked REPL.
###
### spork/netrepl served from inside the running system — a unix
### socket in dev by default. Every connection lands in one shared
### environment (definitions persist across sessions) that has the
### core modules under their usual prefixes (system/ config/ plugin/
### schema/ hooks/) and (boot)/(sys) resolving the current boot — so
### (plugin/inspect), (config/explain ...) and system/restart are at
### hand. Note the sun_path limit (~104 bytes): keep the socket path
### short and relative.

(import spork/netrepl)
(import void/core/system :as system)
(import void/core/plugin :as plugin)

(def default-unix-path
  "Default dev socket, relative to the working directory."
  ".void/repl.sock")

(defn- ensure-parent-dir [path]
  (def dir (string/join (drop -1 (string/split "/" path)) "/"))
  (unless (or (empty? dir) (os/stat dir))
    (os/mkdir dir)))

(defn make-repl-env
  "Build the environment served to netrepl clients."
  []
  (def e (make-env))
  (each [mod prefix] [["void/core/system" "system/"]
                      ["void/core/config" "config/"]
                      ["void/core/schema" "schema/"]
                      ["void/core/plugin" "plugin/"]
                      ["void/core/hooks" "hooks/"]]
    (merge-module e (require mod) prefix))
  (put e 'boot
       @{:value (fn boot [] plugin/current-boot)
         :doc "The boot value of the running system (plugin/start!)."})
  (put e 'sys
       @{:value (fn sys [] (get plugin/current-boot :system))
         :doc "The running system value — (system/restart (sys) :key) etc."})
  e)

(defn- welcome [name]
  (string "void/dev repl — client " name "\n"
          "  (boot)              the running boot value\n"
          "  (sys)               the running system\n"
          "  (plugin/inspect)    who registered what\n"
          "  (config/explain (get (boot) :config) :key ...)\n"))

(def- loopback-hosts
  {"127.0.0.1" true "localhost" true "::1" true "loopback" true})

(defn start
  "Start the netrepl server from the :netrepl slice of the :dev config
  ({:enabled :unix :host :port :allow-remote}); a unix socket is the
  default. A TCP :host beyond loopback is refused unless :allow-remote
  is set — netrepl has no authentication, and a reachable one is a
  remote eval in the application's address space. Returns the instance
  table (or {:disabled true})."
  [cfg]
  (def opts (get cfg :netrepl {}))
  (if (= false (get opts :enabled))
    {:disabled true}
    (do
      (def [host port]
        (if-let [h (get opts :host)]
          [h (string (get opts :port 9365))]
          [:unix (get opts :unix default-unix-path)]))
      (when (and (not= :unix host)
                 (not (in loopback-hosts (string host)))
                 (not (get opts :allow-remote)))
        (errorf (string "netrepl: refusing to listen on %q — netrepl has no "
                        "authentication, and beyond loopback that is a remote "
                        "eval in this process; set [:dev :netrepl :allow-remote] "
                        "true if that is really what you want")
                host))
      (when (= :unix host)
        (ensure-parent-dir port)
        # a previous process may have left the socket file behind;
        # closing a listener never unlinks it. Only ever a socket: a
        # typo in :unix must not delete a source file
        (when-let [mode (os/stat port :mode)]
          (unless (= :socket mode)
            (errorf "netrepl: %s exists and is not a socket — refusing to delete it (check [:dev :netrepl :unix])"
                    port))
          (os/rm port)))
      (def env (make-repl-env))
      # owner-only from the first instant: the socket is a REPL, and on
      # a shared machine default permissions hand it to every local user
      (def server
        (if (= :unix host)
          (let [mask (os/umask 8r077)]
            (defer (os/umask mask)
              (netrepl/server host port env nil welcome)))
          (netrepl/server host port env nil welcome)))
      (when (= :unix host)
        (os/chmod port 8r700))
      @{:server server :host host :port port :env env})))

(defn stop
  "Close the listener and unlink the unix socket file."
  [inst]
  (when-let [server (get inst :server)]
    (:close server))
  (when (and (= :unix (get inst :host))
             (= :socket (os/stat (get inst :port) :mode)))
    (os/rm (inst :port))))

(def component
  "The :dev/netrepl system component."
  (system/component :dev/netrepl
    :doc "In-process netrepl server (unix socket in dev by default)."
    :config {:key :dev}
    :start (fn [_ cfg] (start (or cfg {})))
    :stop stop))
