(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
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

# -- the component loop ends on stop -------------------------------------

(def inst (watch/start {:watch {:paths [dir] :interval 0.01}}))
(assert (inst :fiber))
(watch/stop inst)
(ev/sleep 0.1)
(assert (= :dead (fiber/status (inst :fiber))) "watch loop fiber exited")

(assert (= {:disabled true} (watch/start {:watch {:enabled false}}))
        "disabled watcher starts nothing")

(system/stop (boot :system))
(os/execute @("rm" "-rf" dir) :p)

(print "watch-test: all assertions passed")
