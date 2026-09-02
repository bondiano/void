### `void services` — the wrapper is thin enough to prove without
### docker: the plan is data (an argv), the guard rails are phrases,
### and `print` renders the same compose template `void new` writes.

(import ../test-support/paths)
(import void/cli/services :as services)

# work in a throwaway directory; jpm test runs with cwd = cli/
(def root (os/cwd))
(def sandbox (string root "/.tmp-services-test-" (os/time)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

# -- the plan is exactly the command it stands for ------------------------

(assert (deep= ["docker" "compose" "-f" "docker-compose.dev.yml" "up" "-d"]
               (services/plan "up"))
        "up detaches — this is a laptop's infrastructure, not a foreground process")
(assert (deep= ["docker" "compose" "-f" "docker-compose.dev.yml" "down"]
               (services/plan "down")))
(assert (deep= ["docker" "compose" "-f" "docker-compose.dev.yml" "ps"]
               (services/plan "status")))
(assert (deep= ["docker" "compose" "-f" "docker-compose.dev.yml"
                "logs" "--follow" "--tail" "100"]
               (services/plan "logs")))
(assert (deep= ["docker" "compose" "-f" "docker-compose.dev.yml" "down" "--volumes"]
               (services/plan "down" "--volumes"))
        "extra words pass through to compose")

(def [plan-ok plan-err] (protect (services/plan "restart")))
(assert (not plan-ok) "a subcommand that is not one is refused by name")
(assert (string/find "up|down|status|logs|print" plan-err)
        "and the refusal lists what is")

# -- the guard rails are phrases ------------------------------------------

(defer (do (os/cd root) (rimraf sandbox))
  (os/cd sandbox)

  (def [ok err] (protect (services/run ["up"])))
  (assert (not ok) "no compose file, no docker run")
  (assert (string/find "void new" err) "the phrase names who writes the file")
  (assert (string/find "void services print > docker-compose.dev.yml" err)
          "and offers the copy command instead of writing anything itself")

  (def [usage-ok usage-err] (protect (services/run [])))
  (assert (not usage-ok))
  (assert (string/find "usage" usage-err))

  # -- print renders the template, writes nothing --------------------------

  (def out @"")
  (with-dyns [:out out]
    (services/run ["print"]))
  (assert (string/find "postgres:16-alpine" (string out))
          "print renders the same dev compose `void new` writes")
  (assert (string/find "-dev" (string out))
          "named for the directory it is printed in")
  (assert (nil? (os/stat "docker-compose.dev.yml"))
          "and printing is not writing"))

(print "services-test ok")
