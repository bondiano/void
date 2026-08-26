# void/run! integration: the entrypoint blocks until SIGTERM and shuts
# down gracefully (SPEC.md §3.6). Runs the fixture app as a subprocess
# and drives it with a real signal.
(import ../void/init :as void)
(import ../void/core/plugin :as plugin)
(import ../void/core/system :as system)

# -- option validation ----------------------------------------------------

(def [ok err] (protect (void/run! {:plugin []})))
(assert (not ok))
(assert (string/find "unknown option" (string err)))

# -- stop! rejects a boot that is not parked in run! ----------------------

(def boot (plugin/bootstrap {:plugins []} true))
(def [ok2 err2] (protect (void/stop! boot)))
(assert (not ok2))
(assert (string/find "run!" (string err2)))

# -- subprocess: SIGTERM -> graceful stop in reverse order ----------------

(def proc (os/spawn @("janet" "test-support/run-app.janet") :p {:out :pipe :err :pipe}))
(def out (proc :out))

(defn read-until [pat deadline]
  (def buf @"")
  (ev/with-deadline deadline
    (while (not (string/find pat buf))
      (unless (ev/read out 1024 buf)
        (errorf "subprocess closed stdout early; got: %s" buf))))
  buf)

(def head (read-until "READY" 15))
(os/proc-kill proc false :term)
(def status (os/proc-wait proc))
(def tail (string head (or (ev/read out :all) "")))

(assert (zero? status) (string "app exited with " status ": " tail))
(each pat ["start a" "start b" "READY" "before-stop" "stop b" "stop a"
           "after-stop" "stopped :term"]
  (assert (string/find pat tail)
          (string/format "output lacks %q:\n%s" pat tail)))
(assert (< (string/find "start a" tail) (string/find "start b" tail)))
(assert (< (string/find "before-stop" tail) (string/find "stop b" tail))
        ":before-stop precedes component stops")
(assert (< (string/find "stop b" tail) (string/find "stop a" tail))
        "components stop in reverse dependency order")
(assert (< (string/find "stop a" tail) (string/find "after-stop" tail))
        ":after-stop follows component stops")

(print "run-test: all assertions passed")
