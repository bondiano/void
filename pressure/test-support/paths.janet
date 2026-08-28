# Test-suite module path setup: the in-repo void-core (../core),
# void-http (../http — void/pressure-http sheds its requests),
# void-rest (../rest — the 503 goes out as problem+json wherever it is
# in the composition) and this package's own sources, all importable
# as void/... without installing any of them. jpm test runs each
# script with cwd = pressure/.
(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(add-tree (string (os/cwd) "/../core"))
(add-tree (string (os/cwd) "/../http"))
(add-tree (string (os/cwd) "/../rest"))
(add-tree (os/cwd))
