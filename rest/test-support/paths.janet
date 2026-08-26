# Test-suite module path setup: make the in-repo void-core (../core),
# void-http (../http) and this package's own sources importable as
# void/... without installing any of them. jpm test runs each script
# with cwd = rest/.
(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(add-tree (string (os/cwd) "/../core"))
(add-tree (string (os/cwd) "/../http"))
(add-tree (os/cwd))
