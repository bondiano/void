### void/dev/netrepl — in-process networked REPL (SPEC.md §4).
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

(defn start
  "Start the netrepl server from the :netrepl slice of the :dev config
  ({:enabled :unix :host :port}); a unix socket is the default. Returns
  the instance table (or {:disabled true})."
  [cfg]
  (def opts (get cfg :netrepl {}))
  (if (= false (get opts :enabled))
    {:disabled true}
    (do
      (def [host port]
        (if-let [h (get opts :host)]
          [h (string (get opts :port 9365))]
          [:unix (get opts :unix default-unix-path)]))
      (when (= :unix host)
        (ensure-parent-dir port)
        # a previous process may have left the socket file behind;
        # closing a listener never unlinks it
        (when (os/stat port)
          (os/rm port)))
      (def env (make-repl-env))
      (def server (netrepl/server host port env nil welcome))
      @{:server server :host host :port port :env env})))

(defn stop
  "Close the listener and unlink the unix socket file."
  [inst]
  (when-let [server (get inst :server)]
    (:close server))
  (when (and (= :unix (get inst :host)) (os/stat (get inst :port)))
    (os/rm (inst :port))))

(def component
  "The :dev/netrepl system component."
  (system/component :dev/netrepl
    :doc "In-process netrepl server (unix socket in dev by default)."
    :config {:key :dev}
    :start (fn [_ cfg] (start (or cfg {})))
    :stop stop))
