# Test-suite module path setup: make the in-repo void packages
# (../../core, ../../http, ../../html, ../../htmx, ../../dev) and this
# example's own root importable without installing anything. jpm test
# runs each script with cwd = examples/guestbook/.
(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(add-tree (string (os/cwd) "/../../core"))
(add-tree (string (os/cwd) "/../../http"))
(add-tree (string (os/cwd) "/../../html"))
(add-tree (string (os/cwd) "/../../htmx"))
(add-tree (string (os/cwd) "/../../dev"))
(add-tree (os/cwd))
