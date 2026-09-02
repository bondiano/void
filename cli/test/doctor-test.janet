### `void doctor` — the halves that can be proven without a machine to
### heal: version arithmetic, the PATH walk, the library stat, the
### port knock, and the shape of the report. The row a check produces
### is data ({:status :name :note}), so what is asserted here is the
### verdict and the phrase, not a terminal.

(import ../test-support/paths)
(import void/cli/doctor :as doctor)
(import void/http)

# work in a throwaway directory; jpm test runs with cwd = cli/
(def root (os/cwd))
(def sandbox (string root "/.tmp-doctor-test-" (os/time)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(defn- row [rows name]
  (find |(= name ($ :name)) rows))

# -- versions ------------------------------------------------------------

(assert (deep= [1 41 2] (doctor/parse-version "1.41.2")))
(assert (deep= [1 41 0] (doctor/parse-version "1.41.0-dev"))
        "a pre-release suffix is not a version part")
(assert (doctor/version<? [1 40 9] [1 41 0]))
(assert (doctor/version<? [1 41] [1 41 1]) "missing parts read as zero")
(assert (not (doctor/version<? [1 41 0] [1 41 0])))
(assert (not (doctor/version<? [2 0] [1 41 0])))

# -- the PATH walk and the library stat ----------------------------------

(assert (nil? (doctor/which "no-such-binary-void-doctor-test"))
        "an absent binary is nil, not an error")

(def somewhere (string sandbox "/libfake.dylib"))
(spit somewhere "not really a library")
(assert (= somewhere (doctor/find-library [somewhere]))
        "an absolute candidate that exists is the answer")
(assert (nil? (doctor/find-library [(string sandbox "/no.dylib")]))
        "an absolute candidate that does not exist is not")
(assert (nil? (doctor/find-library ["libno-such-thing-void.so"]))
        "a bare name doctor cannot find is nil — the loader may still know better")

# -- the port knock ------------------------------------------------------

(def server (net/listen "127.0.0.1" "0"))
(def port (last (net/localname server)))
(assert (doctor/port-listening? "127.0.0.1" port)
        "a listening port answers the knock")
(:close server)
(assert (not (doctor/port-listening? "127.0.0.1" port))
        "a closed one refuses it")

# -- gathering, in a directory that is not a project ---------------------

(defer (do (os/cd root) (rimraf sandbox))
  (os/cd sandbox)

  (def bare (doctor/gather))
  (assert (row bare "janet") "the toolchain half always runs")
  (assert (= :ok ((row bare "janet") :status)) "and this janet is new enough")
  (assert (string/find "toolchain checks only" ((row bare "project") :note))
          "no main.janet -> doctor says what it could not check, not nothing")

  # -- and in a project whose main is broken -----------------------------
  #
  # doctor is the command for the machine where nothing else works: a
  # loader that throws becomes a row, never a stack trace.
  (spit "main.janet" "(def app {:plugins [:void/http]})\n")
  (def broken (doctor/gather (fn [] (error "boom in main"))))
  (assert (= :fail ((row broken "app") :status)))
  (assert (string/find "boom in main" ((row broken "app") :note))
          "the row carries the loader's own words")

  # -- and in one that loads --------------------------------------------

  (def rows (doctor/gather (fn [] {:plugins [:void/http]})))
  (assert (= :ok ((row rows "app") :status)) "the composition bootstraps")
  (assert (row rows "port 8080") "and its [:http :port] is knocked on")

  # a library is checked only when the composition names its plugin —
  # and here void/db-postgres is not even importable, which is its own
  # honest row rather than a crash
  (assert (nil? (row rows "libpq")) "no :void/db-postgres, no libpq row")
  (def with-pg (doctor/gather (fn [] {:plugins [:void/db-postgres]})))
  (assert (= :warn ((row with-pg "libpq") :status)))
  (assert (string/find ":start" ((row with-pg "libpq") :note))
          "the note says who gets the final word")

  # a netrepl path holding something that is not a socket is exactly
  # the mess doctor exists to name
  (os/mkdir ".void")
  (spit ".void/repl.sock" "a previous experiment")
  (def stale (doctor/gather (fn [] {:plugins [:void/http]})))
  (assert (= :fail ((row stale "netrepl") :status)))
  (assert (string/find "not a socket" ((row stale "netrepl") :note)))

  # -- the report is lines, verdict last ---------------------------------

  (def report (doctor/report rows))
  (assert (string/find "janet" (string/join report "\n")))
  (assert (or (string/find "ready" (last report))
              (string/find "warning" (last report))
              (string/find "problem" (last report)))
          "the last line is a verdict, whatever this machine deserves"))

(print "doctor-test ok")
