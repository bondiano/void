(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/cli :as cli)

# -- command words / resolution ------------------------------------------

(assert (deep= (cli/command-words :routes) ["routes"])
        "plain keyword -> one word")
(assert (deep= (cli/command-words :openapi/export) ["openapi" "export"])
        "namespaced keyword -> two words")

(def commands
  [{:name :routes :fn (fn [&])}
   {:name :openapi/export :fn (fn [&])}])

(let [[c args] (cli/find-command commands ["routes" "--keys"])]
  (assert (= :routes (c :name)) "one-word command matches")
  (assert (deep= args ["--keys"]) "the rest is passed through"))

(let [[c args] (cli/find-command commands ["openapi" "export" "out.json"])]
  (assert (= :openapi/export (c :name)) "two-word command matches first")
  (assert (deep= args ["out.json"]) "args after the two words"))

(assert (nil? (cli/find-command commands ["nope"])) "unknown command -> nil")

# -- run-command: :needs subset start, instances + args, stop after ------

(def log @[])

(def app
  (plugin/manifest 'test/app
    :components
    [(system/component :app/dep
       :start (fn [d c] (array/push log :start-dep) @{:name :dep})
       :stop (fn [i] (array/push log :stop-dep)))
     (system/component :app/service
       :deps [:app/dep]
       :start (fn [d c] (array/push log :start-service) @{:name :service})
       :stop (fn [i] (array/push log :stop-service)))
     (system/component :app/unrelated
       :start (fn [d c] (array/push log :start-unrelated) @{})
       :stop (fn [i] (array/push log :stop-unrelated)))]
    :contributes
    {:void.core/cli
     [{:name :app/who
       :doc "test command"
       :needs [:app/service]
       :fn (fn [service & args]
             (array/push log [:ran (service :name) ;args])
             :done)}]}))

(def boot (cli/bootstrap-app {:plugins [app] :profile :test}))
(def cli-commands (plugin/extension boot :void.core/cli))
(def [command args] (cli/find-command cli-commands ["app" "who" "x" "y"]))

(assert (= :done (cli/run-command boot command args))
        "run-command returns the command's value")
(assert (deep= log @[:start-dep :start-service
                     [:ran :service "x" "y"]
                     :stop-service :stop-dep])
        "only :needs + transitive deps start, in order, and stop in reverse")

# -- run-command without :needs starts nothing ---------------------------

(array/clear log)
(def boot2 (cli/bootstrap-app
             {:plugins [(plugin/manifest 'test/app2
                          :components
                          [(system/component :app/unused
                             :start (fn [d c] (array/push log :start-unused) @{}))]
                          :contributes
                          {:void.core/cli
                           [{:name :plain
                             :fn (fn [& args] (tuple ;args))}]})]
              :profile :test}))
(def [c2 a2] (cli/find-command (plugin/extension boot2 :void.core/cli)
                               ["plain" "1"]))
(assert (deep= (cli/run-command boot2 c2 a2) ["1"])
        "a command without :needs gets only the args")
(assert (empty? log) "no component starts for a :needs-less command")

# -- a symbol :fn is rejected with a clear error -------------------------

(def [ok err]
  (protect (cli/run-command boot2 {:name :sym :fn 'some-fn} [])))
(assert (not ok) "symbol :fn throws")
(assert (string/find "symbol" err) "the error explains the limitation")

(print "cli-test ok")
