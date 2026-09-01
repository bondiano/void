### The bundle, installed — the other half of scripts/bootstrap.janet
### (ADR-0020).
###
### bootstrap prepares a *checkout*: every package importable from where
### it is written, `scripts/void` as the CLI, nothing installed. This
### installs the very same packages the way a stranger gets them — one
### `jpm install` of the repository root into a tree of its own — and
### prints the two lines that put that tree in front of a shell:
###
###     janet scripts/install-tree.janet          # install (or reinstall)
###     eval "$(janet scripts/install-tree.janet --export)"
###
### examples/hub is why this exists (ROADMAP 6.6). Every other example
### runs off the checkout through its own test-support/paths.janet, so
### no ordinary `jpm test` ever proves that the install works; CI's
### "clean machine" job proves it once, for scaffolds. The hub imports
### `void/...` like a stranger instead, which means a change to the
### framework reaches it only after this script has run again. That is
### the cost of the arrangement, and it is also the point of it.
###
### The tree is <root>/.void-tree by default (git-ignored), and
### `--tree=PATH` puts it anywhere. Nothing here touches the system
### tree: a contributor's `jpm install` habits and this are separate
### directories on purpose.

(import ./packages :as packages)

(def default-tree
  "Where the installed bundle lives unless --tree says otherwise."
  (string packages/root "/.void-tree"))

(defn- run [& args]
  (print "  $ " (string/join args " "))
  (def code (os/execute args :p))
  (unless (zero? code)
    (errorf "%s failed with exit code %d" (first args) code)))

(defn- installed? [tree]
  (= :directory (os/stat (string tree "/lib/void") :mode)))

(defn exports
  ``The three lines a shell needs to speak to the installed tree, one
  per thing that has to be told: `janet` resolves modules through
  JANET_PATH, `jpm` (which is what runs a suite, and which ignores
  JANET_PATH entirely) through JANET_TREE, and the `void` binary is
  found on PATH. PATH keeps its tail, so the tree shadows a `void`
  installed elsewhere rather than hiding the rest of the shell.``
  [tree]
  [(string "export JANET_TREE=" tree)
   (string "export JANET_PATH=" tree "/lib")
   (string "export PATH=" tree "/bin:$PATH")])

(defn main [_ & args]
  (var tree default-tree)
  (var deps? nil)     # nil = decide by whether the tree exists
  (var export-only? false)
  (each arg args
    (cond
      # not os/realpath: the tree usually does not exist yet, and a
      # relative --tree is relative to the shell that typed it
      (string/has-prefix? "--tree=" arg)
      (let [p (string/slice arg 7)]
        (set tree (if (string/has-prefix? "/" p) p (string (os/cwd) "/" p))))
      (= "--deps" arg) (set deps? true)
      (= "--no-deps" arg) (set deps? false)
      (= "--export" arg) (set export-only? true)
      (errorf "usage: janet scripts/install-tree.janet [--tree=PATH] [--deps|--no-deps] [--export]")))

  (when export-only?
    (each line (exports tree) (print line))
    (break))

  (def problems (packages/check))
  (unless (empty? problems)
    (each p problems (eprint "  " p))
    (errorf "package graph: %d problem(s)" (length problems)))

  (def here (os/cwd))
  (defer (os/cd here)
    (os/cd packages/root)
    # `jpm deps` clones the bundle's external dependencies (spork, and
    # nothing else — janet-lang/sqlite3 is an application's opt-in, so
    # an application that wants it declares it in its own project.janet
    # and installs it into this same tree). Skipped once they are there,
    # because a reinstall after a one-line edit should not go to the
    # network; --deps forces it.
    (when (or deps? (and (nil? deps?) (not (installed? tree))))
      (print "installing external dependencies into " tree)
      (run "jpm" (string "--tree=" tree) "deps")
      # and what the installed examples declare on top of the bundle —
      # janet-lang/sqlite3, which the bundle leaves out on purpose. An
      # application that lists :void/db-sqlite installs the driver's
      # library itself; here the application is examples/hub and this
      # is it doing that.
      (each url (packages/installed-jpm-dependencies)
        (run "jpm" (string "--tree=" tree) "install" url)))

    (print "installing the void bundle into " tree)
    (run "jpm" (string "--tree=" tree) "install"))

  (print)
  (print "ready. This shell speaks to the installed tree with:")
  (print)
  (each line (exports tree) (print "  " line))
  (print)
  (print "  eval \"$(janet scripts/install-tree.janet --export)\"")
  (print)
  (print "and `janet scripts/packages.janet check` still describes the")
  (print "checkout, which is a different thing entirely."))
