(import ../test-support/paths)
(import void/core/log :as log)
(import void/db/conformance/lease :as lease-conformance)
(import void/db-sqlite/driver :as sqlite)

(each ns ["void.db" "void.db.query"] (log/set-level! ns :fatal))

# void/db/lease over sqlite — the engine every other suite tests
# against, and the one whose writer is serialized: the race on the
# first take is decided by BEGIN IMMEDIATE and the busy timeout, not
# by row locks, and it has to come out the same way.

(def sandbox (string (os/cwd) "/.tmp-lease-" (os/time) "-" (os/getpid)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(defer (rimraf sandbox)
  (lease-conformance/run! "sqlite"
                          (sqlite/make {:path (string sandbox "/lease.sqlite3")
                                        :busy-timeout 2000})))
