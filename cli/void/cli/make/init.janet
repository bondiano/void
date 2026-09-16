### void/cli/make — `void make KIND ...`, the scaffolding generators.
###
### Each kind is a module of its own — a spec, its templates, and the
### twenty lines that turn one into the other — and this file is the
### table that maps a word to it. Five kinds share one runner
### (./scaffold), one vocabulary of names and field types (./spec) and
### one declaration format: a kind's `command` is the same struct a
### `:void.core/cli` contribution is, so `void make job --help` is
### rendered from what the generator actually accepts and the flags are
### parsed by void/core/cli rather than by a loop per generator.
###
### **Nothing existing is edited.** `make` writes new files, refuses to
### clobber (`--force` to insist) and *prints* what has to be added to
### `project.janet`, `main.janet` and a config file rather than reaching
### into them. A generator that rewrites hand-edited code is a generator
### nobody dares run twice — phx.gen.auth edits the router because it
### can pattern-match one line of Elixir it wrote itself, and the files
### here are not that.
###
### `--dry-run` prints what would be written, to stdout, so it composes
### with a pager and a diff. Every question the interactive pass asks
### has a flag and a default, so the same command runs in CI.

(import void/core/cli :as cmd)
(import ./resource)
(import ./auth)
(import ./job)
(import ./plugin)
(import ./migration)

(def kinds
  ``What `void make` can make: the word a reader types, and the module
  that knows what to do with the rest of the line. The table is the
  reason a sixth entry is a line rather than a rewrite of the
  dispatcher.``
  {"resource" {:command resource/command :fn resource/create}
   "auth" {:command auth/command :fn auth/create}
   "job" {:command job/command :fn job/create}
   "plugin" {:command plugin/command :fn plugin/create}
   "migration" {:command migration/command :fn migration/create}})

(def commands
  "The declarations, for `void make --help` to list."
  (sorted-by |($ :name) (map |($ :command) (values kinds))))

(defn- print-help []
  (print "usage: void make KIND [args]")
  (print)
  (print "Kinds:")
  (each c commands
    (print (cmd/summary {:name (keyword (last (cmd/command-words (c :name))))
                         :doc (c :doc)
                         :args (c :args)}
                        26)))
  (print)
  (print "  void make KIND --help  for the flags of one"))

(defn create
  ``The body of `void make KIND ...`: resolve the kind, answer `--help`
  off its declaration, parse the rest of the line against the same
  declaration, and hand the generator its options and positionals.``
  [& args]
  (def word (first args))
  (def rest (tuple ;(drop 1 args)))
  (cond
    (or (nil? word) (= "--help" word) (= "-h" word))
    (print-help)

    (let [kind (or (in kinds word)
                   (errorf "void make: unknown kind %q (one of: %s)"
                           word (string/join (sorted (keys kinds)) ", ")))
          c (kind :command)]
      (if (cmd/help-wanted? c rest)
        (each l (cmd/help c) (print l))
        (cmd/call c (kind :fn) [] rest)))))
