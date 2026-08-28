# Test-suite module path setup: the in-repo void-core (../core),
# void-db (../db) and void-db-sqlite (../db-sqlite — what the db
# backend is tested against), void-redis (../redis — the other
# backend) and this package's own sources, all importable as void/...
# without installing any of them. jpm test runs each script with
# cwd = jobs/.
#
# void-db-postgres (../db-postgres) and the native void/fdwait it
# reaches libpq through are on the path too, but nothing *imports*
# them: test/db-postgres-test.janet resolves the driver with `require`
# only when VOID_TEST_PG names a server, so a laptop that has never
# run `cd fdwait && jpm build` still gets a green suite.
(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(add-tree (string (os/cwd) "/../core"))
(add-tree (string (os/cwd) "/../db"))
(add-tree (string (os/cwd) "/../db-sqlite"))
(add-tree (string (os/cwd) "/../redis"))
(add-tree (string (os/cwd) "/../db-postgres"))
(add-tree (string (os/cwd) "/../fdwait"))
(array/insert module/paths 0
              [(string (os/cwd) "/../fdwait/build/:all:.so") :native])
(add-tree (os/cwd))
