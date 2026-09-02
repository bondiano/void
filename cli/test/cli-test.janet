(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/deploy :as deploy)
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
             :done)}]
     # the CLI path runs the whole lifecycle: a plugin that allocated
     # something in :before-start gets its stop hooks here too
     :void.core/hooks
     [{:hook :before-stop :name :test/bs
       :fn (fn [b] (array/push log :hook-before-stop))}
      {:hook :after-stop :name :test/as
       :fn (fn [b] (array/push log :hook-after-stop))}]}))

(def boot (cli/bootstrap-app {:plugins [app] :profile :test}))
(def cli-commands (plugin/extension boot :void.core/cli))
(def [command args] (cli/find-command cli-commands ["app" "who" "x" "y"]))

(assert (= :done (cli/run-command boot command args))
        "run-command returns the command's value")
(assert (deep= log @[:start-dep :start-service
                     [:ran :service "x" "y"]
                     :hook-before-stop
                     :stop-service :stop-dep
                     :hook-after-stop])
        "only :needs + transitive deps start, in order, and stop in reverse — inside the stop hooks")

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

# -- void deploy check ---------------------------------------------------
#
# The survey printed before the deploy rather than during it: it starts
# the components the store declarations name and nothing else, so it is
# safe on a machine that is already serving (ADR-0030).

(array/clear log)

(def surveyed
  (plugin/manifest 'test/stores
    :components
    [(system/component :store/thing
       :start (fn [d c] (array/push log :start-thing) @{:shared? false})
       :stop (fn [i] (array/push log :stop-thing)))
     (system/component :store/listener
       :start (fn [d c] (array/push log :start-listener) @{})
       :stop (fn [i] (array/push log :stop-listener)))]
    :contributes
    {:void.core/store
     [{:name :test/thing
       :what "a thing"
       :needs [:store/thing]
       :ask (fn [boot]
              (when (get-in boot [:system :instances :store/thing])
                {:store :memory :shared? false
                 :replacement "compose the shared thing"}))}
      {:name :test/room
       :what "rooms"
       :ask (fn [_] {:store :process :shared? :by-design
                     :why "a connection lives where its socket does"})}]}))

# -- load-plugins-fn: void dev asks main for the composition -------------
#
# `void dev --profile prod` used to boot the unconditional `app` list —
# netrepl and the watcher included — while `VOID_PROFILE=prod janet
# main.janet` filtered them out through `plugins`. One project, one
# composition per profile: the CLI reads the same function.

(def fake-root (string (or (os/getenv "TMPDIR") "/tmp") "/void-cli-test-" (os/time)))
(os/mkdir fake-root)
(spit (string fake-root "/fake-main.janet")
      (string "(def app {:plugins [:void/http :void/dev]})\n"
              "(defn plugins [profile]\n"
              "  (if (= :prod profile)\n"
              "    (filter |(not= :void/dev $) (app :plugins))\n"
              "    (app :plugins)))\n"))
(cli/add-project-paths! fake-root)
(def pf (cli/load-plugins-fn "fake-main"))
(assert (function? pf) "main's plugins function is found")
(assert (deep= (pf :prod) @[:void/http])
        "and answers the :prod composition — without :void/dev")
(assert (deep= (freeze (pf :dev)) [:void/http :void/dev])
        "while :dev keeps the whole list")
(assert (nil? (cli/load-plugins-fn "no-such-module"))
        "a missing module is nil, not an error — `app` alone is still a valid main")
(os/rm (string fake-root "/fake-main.janet"))
(os/rmdir fake-root)

(def boot3 (cli/bootstrap-app {:plugins [surveyed] :profile :test}))
(def entries (cli/deploy-check boot3))

(assert (deep= log @[:start-thing :stop-thing])
        "only what a store declaration needs starts — never the listener")
(assert (= 2 (length entries)))
(assert (= 1 (length (deploy/per-process entries)))
        "a per-process store is a finding; one that is per-process by design is not")

(print "cli-test ok")
