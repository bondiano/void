(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/hooks :as hooks)
(import void/dev/watch :as watch)

# -- workspace -----------------------------------------------------------

(def dir (string (or (os/getenv "TMPDIR") "/tmp") "/void-watch-" (os/time)))
(os/mkdir dir)

(def mod-path (string dir "/watched-mod.janet"))
(spit mod-path "(defn answer [] 1)\n")
(def hidden-dir (string dir "/.git"))
(os/mkdir hidden-dir)
(spit (string hidden-dir "/skip-me.janet") "(this is not even janet")

# -- scan / changed ------------------------------------------------------

(def snap (watch/scan [dir]))
(assert (= 1 (length snap)) "scan finds the .janet file and skips hidden dirs")
(def real-mod (first (keys snap)))
(assert (string/has-suffix? "watched-mod.janet" real-mod))

# dependency trees and build output are not the application: the
# default excludes keep the poll from paying for them twice a second
(def tree-dir (string dir "/jpm_tree"))
(os/mkdir tree-dir)
(spit (string tree-dir "/vendored.janet") "(def vendored 1)\n")
(def build-dir (string dir "/build"))
(os/mkdir build-dir)
(spit (string build-dir "/artifact.janet") "(def artifact 1)\n")
(assert (= 1 (length (watch/scan [dir])))
        "jpm_tree/ and build/ are skipped by default")
(assert (= 2 (length (watch/scan [dir] ["jpm_tree"])))
        "explicit excludes replace the defaults")
(def generated-dir (string dir "/generated"))
(os/mkdir generated-dir)
(spit (string generated-dir "/gen.janet") "(def gen 1)\n")
(assert (= 1 (length (watch/scan [dir] [;watch/default-excludes "generated"])))
        "a config :exclude adds to the defaults")
# not excluded by default — out of the way of the scans below
(os/rm (string generated-dir "/gen.janet"))
(os/rmdir generated-dir)

(assert (empty? (watch/changed snap (watch/scan [dir]))) "no change, no files")
(assert (= [real-mod] (freeze (watch/changed @{} (watch/scan [dir]))))
        "a new file counts as changed")
(def touched (merge-into @{} snap {real-mod 0}))
(assert (= [real-mod] (freeze (watch/changed touched snap)))
        "an mtime difference counts as changed")

# -- reload! into the existing module env (late binding) -----------------

(def menv (require mod-path))
(defn current-answer [] ((get-in menv ['answer :value])))
(assert (= 1 (current-answer)))

(spit mod-path "(defn answer [] 2)\n")
(assert (= :reloaded (watch/reload! real-mod)))
(assert (= 2 (current-answer))
        "reload! updates the same env table in place")

(assert (= :skipped (watch/reload! (string dir "/never-required.janet")))
        "a file that is not a loaded module is skipped")

# -- affected-components + apply-changes! --------------------------------

(def restarts @[])
(def m
  (plugin/manifest 'test/watched
    :source mod-path
    :components [(system/component :w/stateful
                   :start (fn [d c] (array/push restarts :started) :inst)
                   :stop (fn [i] (array/push restarts :stopped)))
                 (system/component :w/stateless
                   :start (fn [d c] :pure))]))
(def other
  (plugin/manifest 'test/elsewhere
    :source (string dir "/other.janet")
    :components [(system/component :o/comp
                   :start (fn [d c] :o)
                   :stop (fn [i] nil))]))

(def boot (plugin/bootstrap {:plugins [m other]} true))
(system/start (boot :system))
(array/clear restarts)

(assert (= [:w/stateful] (freeze (watch/affected-components boot real-mod)))
        "only running stateful components of manifests with this :source")
(assert (empty? (watch/affected-components boot (string dir "/unrelated.janet"))))

(spit mod-path "(defn answer [] 3)\n")
(def report (watch/apply-changes! boot [real-mod]))
(assert (= [real-mod] (freeze (report :reloaded))))
(assert (= [:w/stateful] (freeze (report :restarted))))
(assert (empty? (report :errors)))
(assert (= 3 (current-answer)))
(assert (= [:stopped :started] (freeze restarts))
        "the stateful component was restarted")

# an eval error is reported, not thrown
(spit mod-path "(this is not janet")
(def bad-report (watch/apply-changes! boot [real-mod]))
(assert (= 1 (length (bad-report :errors))))
(assert (empty? (bad-report :restarted)) "no restart after a broken reload")
(spit mod-path "(defn answer [] 3)\n")
(watch/apply-changes! boot [real-mod])

# -- a failed restart is retried on the next save ------------------------
#
# the reload succeeds but the component's new :start throws (a port in
# TIME_WAIT, say): the server is down, and the component is no longer
# :running — saving the file again must retry it, not shrug

(var broken true)
(def flaky-path (string dir "/flaky-mod.janet"))
(spit flaky-path "(defn ignored [] 1)\n")
(require flaky-path)
(def flaky
  (plugin/manifest 'test/flaky
    :source flaky-path
    :components [(system/component :w/flaky
                   :start (fn [d c] (when broken (error "port busy")) :up)
                   :stop (fn [i] nil))]))
(def fboot (plugin/bootstrap {:plugins [flaky]} true))
(set broken false)
(system/start (fboot :system))
(set broken true)
(def real-flaky (os/realpath flaky-path))
(spit flaky-path "(defn ignored [] 2)\n")
(def down-report (watch/apply-changes! fboot [real-flaky]))
(assert (= 1 (length (down-report :errors))) "the failed restart is reported")
(assert (= :stopped (get-in fboot [:system :states :w/flaky])) "the component is down")
(set broken false)
(spit flaky-path "(defn ignored [] 3)\n")
(def up-report (watch/apply-changes! fboot [real-flaky]))
(assert (= [:w/flaky] (freeze (up-report :restarted)))
        "the next save retries the component a failed restart left down")
(assert (= :running (get-in fboot [:system :states :w/flaky])))
(system/stop (fboot :system))

# -- the component loop ends on stop -------------------------------------

(def inst (watch/start {:watch {:paths [dir] :interval 0.01}}))
(assert (inst :fiber))
(watch/stop inst)
(ev/sleep 0.1)
(assert (= :dead (fiber/status (inst :fiber))) "watch loop fiber exited")

(assert (= {:disabled true} (watch/start {:watch {:enabled false}}))
        "disabled watcher starts nothing")

# -- the :void.dev/reloaded hook -----------------------------------------

(def fired @[])
(def hreg (hooks/registry))
(hooks/add! hreg :void.dev/reloaded
            (fn [b report] (array/push fired (freeze (report :reloaded))))
            :name :test/spy)
(hooks/add! hreg :void.dev/reloaded
            (fn [b report] (error "rebuild blew up"))
            :name :test/boom :phase 2000)
(def hook-boot @{:hooks hreg})

(def ok-report @{:reloaded @["a.janet"] :errors @[]})
(watch/notify-reloaded! hook-boot ok-report)
(assert (= [["a.janet"]] (freeze fired)) "handlers see the reloaded files")
(assert (= 1 (length (ok-report :errors)))
        "a failing handler lands in the report, the watcher survives")

(def quiet-report @{:reloaded @[] :errors @[]})
(watch/notify-reloaded! hook-boot quiet-report)
(assert (= 1 (length fired)) "no reloaded files -> the hook does not fire")
(watch/notify-reloaded! nil ok-report)

(system/stop (boot :system))
(os/execute @("rm" "-rf" dir) :p)

(print "watch-test: all assertions passed")
