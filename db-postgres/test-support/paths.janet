# Test-suite module path setup: the in-repo void-core (../core),
# void-db (../db), void-fdwait (../fdwait, sources plus the native
# module in its build/ tree) and this package's own sources, all
# importable as void/... without installing any of them. jpm test runs
# each script with cwd = db-postgres/.
(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(add-tree (string (os/cwd) "/../core"))
(add-tree (string (os/cwd) "/../db"))
(add-tree (string (os/cwd) "/../fdwait"))
(add-tree (os/cwd))
(array/insert module/paths 0
              [(string (os/cwd) "/../fdwait/build/:all:.so") :native])
