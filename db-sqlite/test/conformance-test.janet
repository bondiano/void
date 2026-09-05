(import ../test-support/paths)
(import void/core/log :as log)
(import void/db/conformance/driver :as conformance)
(import void/db-sqlite/driver :as sqlite)

(each ns ["void.db" "void.db.query"] (log/set-level! ns :fatal))

# The :void/db-driver conformance suite against sqlite — the engine
# every other suite in this repository tests against, and the one
# with no SQLSTATE of its own: what it asserts here is that the
# synthesized states classify like everyone else's.
#
# Two drivers, because they are two different arrangements: a file
# with RETURNING (the shape a deployment has) and one without it, which
# is the :insert-id path the entity layer takes on an older sqlite.

(def sandbox (string (os/cwd) "/.tmp-conformance-" (os/time) "-" (os/getpid)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(defer (rimraf sandbox)
  (conformance/run! "sqlite"
                    (sqlite/make {:path (string sandbox "/returning.sqlite3")
                                  :returning true :busy-timeout 1000}))
  (conformance/run! "sqlite (no RETURNING)"
                    (sqlite/make {:path (string sandbox "/insert-id.sqlite3")
                                  :busy-timeout 1000})))
