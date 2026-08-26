(import ../test-support/paths)
(import void/http/prefork :as prefork)

# -- worker detection ----------------------------------------------------

(assert (not (prefork/worker?)) "the test process is a master")
(assert (nil? (prefork/worker-index)))

(assert (= 3 (prefork/worker-count 3)))
(assert (pos? (prefork/worker-count :auto)) ":auto resolves to >= 1")
(assert (not (first (protect (prefork/worker-count 0)))))
(assert (not (first (protect (prefork/worker-count "4")))))

# -- master supervision over a dummy worker command ----------------------

# the dummy worker proves the env contract: it reads VOID_HTTP_WORKER
# and stays up until SIGTERM
(def worker-script
  (string (or (os/getenv "TMPDIR") "/tmp") "/void-prefork-worker-" (os/time) ".janet"))
(spit worker-script
      "(assert (os/getenv \"VOID_HTTP_WORKER\")) (ev/sleep 60)")

(def exits @[])
(def inst
  (prefork/start
    {:workers 2
     :cmd ["janet" worker-script]
     :backoff 0.1
     :on-exit (fn [i status] (array/push exits [i status]))}))

(ev/sleep 0.3)
(assert (deep= @[0 1] (prefork/alive inst)) "both workers spawned")
(def pid0 (get-in inst [:procs 0 :pid]))
(assert (int? pid0))

# kill worker 0 -> supervisor respawns it with a fresh pid
(os/proc-kill (get-in inst [:procs 0]) false :kill)
(ev/sleep 0.5)
(assert (deep= @[0 1] (prefork/alive inst)) "dead worker respawned")
(assert (not= pid0 (get-in inst [:procs 0 :pid])) "respawn is a new process")
(assert (= 1 (length exits)) "unexpected exit reported")
(assert (= 0 (first (exits 0))) "the right worker index reported")

# stop: SIGTERM, wait, none left, no respawns
(prefork/stop inst 2)
(assert (empty? (prefork/alive inst)) "stop leaves no workers")
(ev/sleep 0.3)
(assert (empty? (prefork/alive inst)) "no respawns after stop")

(os/rm worker-script)
(print "prefork-test ok")
