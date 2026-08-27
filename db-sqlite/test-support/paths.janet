# Test-suite module path setup: make the in-repo void-core (../core),
# void-db (../db) and this package's own sources importable as
# void/... without installing any of them. jpm test runs each script
# with cwd = db-sqlite/.
(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(add-tree (string (os/cwd) "/../core"))
(add-tree (string (os/cwd) "/../db"))
(add-tree (os/cwd))
