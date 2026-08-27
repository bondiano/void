# Test-suite module path setup: make the in-repo void-core (../core),
# void-dev (../dev — the test suite drives test/inject against this
# package's kernel) and this package's own sources importable as
# void/... without installing any of them. jpm test runs each script
# with cwd = http/.
(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(add-tree (string (os/cwd) "/../core"))
(add-tree (string (os/cwd) "/../dev"))
(add-tree (os/cwd))
