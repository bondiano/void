# Test-suite module path setup: this package's own sources plus the
# native module `jpm build` leaves in build/ (janet loads native
# modules from .so on every platform jpm supports, macOS included).
# jpm test runs each script with cwd = fdwait/.
(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(add-tree (os/cwd))
(array/insert module/paths 0 [(string (os/cwd) "/build/:all:.so") :native])
