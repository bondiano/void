# Fixture app for run-test.janet: started as a subprocess, reports its
# lifecycle on stdout and relies on void/run! to handle SIGTERM.
(import ../void/init :as void)
(import ../void/core/plugin :as plugin)
(import ../void/core/system :as system)

(defn- say [& xs]
  (print ;xs)
  (flush))

(def app
  (plugin/manifest 'test/app
    :components [(system/component :app/a
                   :start (fn [d c] (say "start a") :a)
                   :stop (fn [i] (say "stop a")))
                 (system/component :app/b
                   :deps [:app/a]
                   :start (fn [d c] (say "start b") :b)
                   :stop (fn [i] (say "stop b")))]
    :contributes {:void.core/hooks
                  [{:hook :after-start :fn (fn [b] (say "READY"))}
                   {:hook :before-stop :fn (fn [b] (say "before-stop"))}
                   {:hook :after-stop :fn (fn [b] (say "after-stop"))}]}))

(def boot (void/run! {:plugins [app]}))
(say (string/format "stopped %q" (boot :stop-reason)))
