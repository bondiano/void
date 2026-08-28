### Contributor bootstrap (ADR-0020). Run once from the repository root:
###
###     janet scripts/bootstrap.janet
###
### Installs the external jpm dependencies of every package in the graph
### — including the ones the bundle deliberately leaves out, such as
### janet-lang/sqlite3 (void/db-sqlite's suite needs it even though an
### application opts into the driver) — and builds void/fdwait, the one
### native module.
###
### After it, `cd <package> && jpm test` works anywhere in the tree, and
### `scripts/void` is the CLI without installing anything.
###
### Arguments are passed through to jpm, so a contributor who would
### rather not touch the system tree can say:
###
###     janet scripts/bootstrap.janet --local

(import ./packages :as packages)

(defn- run [& args]
  (print "  $ " (string/join args " "))
  (def code (os/execute args :p))
  (unless (zero? code)
    (errorf "%s failed with exit code %d" (first args) code)))

(defn main [_ & jpm-args]
  (def problems (packages/check))
  (unless (empty? problems)
    (each p problems (eprint "  " p))
    (errorf "package graph: %d problem(s)" (length problems)))

  (print "installing external dependencies")
  (each url (packages/jpm-dependencies true)
    (run "jpm" ;jpm-args "install" url))

  # void/db-postgres parks its fibers on libpq's socket through this
  # (ADR-0011); nothing else in the monorepo is compiled.
  (print "building void/fdwait")
  (def here (os/cwd))
  (defer (os/cd here)
    (os/cd (packages/dir :void/fdwait))
    (run "jpm" ;jpm-args "build"))

  (print)
  (print "ready. `cd <package> && jpm test`, or `scripts/void` for the CLI.")
  (print "libpq (brew install libpq / apt install libpq5) is opened at")
  (print "runtime and only by void/db-postgres — a machine without it is")
  (print "told so at :start, not here."))
