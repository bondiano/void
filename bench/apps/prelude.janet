### Module-path setup for the bench mini-apps: make the in-repo void
### packages importable relative to this file, wherever the process was
### launched from (the runner spawns the apps from the bench root; a
### human may run them from anywhere).

(def- self (dyn *current-file*))

(defn- dirname [p]
  (def idxs (string/find-all "/" p))
  (if (empty? idxs) "." (string/slice p 0 (last idxs))))

(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(def- repo (os/realpath (string (dirname self) "/../..")))
(add-tree (string repo "/core"))
(add-tree (string repo "/http"))
(add-tree (string repo "/rest"))
(add-tree (string repo "/html"))
(add-tree (string repo "/pressure"))
(add-tree (string repo "/bench"))
# B2/B3 reach Postgres through void/db + void/db-postgres, which reach
# libpq through void/fdwait — the one native module, built out of tree
# (cd fdwait && jpm build).
(add-tree (string repo "/db"))
(add-tree (string repo "/db-postgres"))
(add-tree (string repo "/fdwait"))
(array/insert module/paths 0
              [(string repo "/fdwait/build/:all:.so") :native])
