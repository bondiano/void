### void/cli — the `void` binary (SPEC.md §5.17).
###
### Commands are an extension point, not a switch statement: everything
### beyond the built-ins (new/repl/help/version) comes from the
### :void.core/cli contributions of the application's own plugins. The
### binary loads the project's app module (`main` by default), reads
### its `app` binding — the same boot options main passes to
### (void/run! ...) — runs bootstrap phases 1-5 plus the :config-loaded
### and :before-start hooks (so route tables and contexts exist), then
### starts only the components a command declares in :needs (plus their
### transitive dependencies) and calls the command with those instances
### followed by the raw string arguments. Nothing a command does not
### need ever opens a port.
###
### Command naming: a plain keyword :routes is `void routes`; a
### namespaced :openapi/export is `void openapi export`.
###
### Four commands are built in rather than contributed, and for one
### reason each: `new` and `make` run *before* there is a composition
### to ask (./new, ./make), `repl` has to reach a process this one is
### not (./repl), and `deploy check` and `plugins lock` read what
### void/core owns — the deployment shape and the manifests — and
### void/core is not a plugin (ADR-0030, ADR-0003).

(import void)
(import void/core/init :as core)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/hooks :as hooks)
(import void/core/deploy :as deploy)
(import ./new :as new)
(import ./repl :as repl)
(import ./make :as make)
(import ./lock :as lock)

(def default-app-module
  "Module the CLI loads to find the application: `main` — the file
  `void new` generates."
  "main")

(defn add-project-paths!
  "Make the project tree importable: its root (main.janet, app.janet)
  goes on module/paths, like the generated project expects."
  [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(defn load-app
  ``Load the application boot options: require `module` (default
  `main`) and read its `app` binding — a dictionary of plugin/bootstrap
  options ({:plugins [...] :profile ...}). Throws with a helpful
  message when the module or the binding is missing.``
  [&opt module]
  (default module default-app-module)
  (def [ok env] (protect (require module)))
  (unless ok
    (errorf "cannot load app module %q: %s\n  (run `void` from the project root, or point at the module with --app)"
            module (if (string? env) env (describe env))))
  (def app (get-in env ['app :value]))
  (unless (dictionary? app)
    (errorf "module %q does not define `app` — expected (def app {:plugins [...] ...}) boot options"
            module))
  app)

# -- command words -------------------------------------------------------

(defn command-words
  "The argv words a command keyword answers to: :routes -> [\"routes\"],
  :openapi/export -> [\"openapi\" \"export\"]."
  [name]
  (tuple ;(string/split "/" (string name))))

(defn find-command
  ``Resolve leading argv words against the contributed commands
  (longest match first). Returns [command remaining-args] or nil.``
  [commands words]
  (def by-words
    (tabseq [c :in commands] (command-words (c :name)) c))
  (or (when (>= (length words) 2)
        (when-let [c (in by-words [(words 0) (words 1)])]
          [c (tuple ;(drop 2 words))]))
      (when (>= (length words) 1)
        (when-let [c (in by-words [(words 0)])]
          [c (tuple ;(drop 1 words))]))))

# -- app command execution -----------------------------------------------

(defn- boot-opts
  "Boot options for plugin/bootstrap from the app binding: the
  bootstrap subset of keys (run! extras like :signals are dropped),
  profile overridable from the command line."
  [app profile]
  (def opts @{})
  (each k [:plugins :profile :config]
    (unless (nil? (get app k))
      (put opts k (app k))))
  (when profile (put opts :profile profile))
  opts)

(defn bootstrap-app
  "Bootstrap phases 1-5 for the app, then run the :config-loaded and
  :before-start hooks — after this route tables and plugin contexts
  exist, but no component has started. Returns the boot value."
  [app &opt profile]
  (def boot (plugin/bootstrap (boot-opts app profile)))
  (hooks/run! (boot :hooks) :config-loaded boot)
  (hooks/run! (boot :hooks) :before-start boot)
  boot)

(defn run-command
  ``Run one contributed command against a bootstrapped app: start the
  :needs components (plus transitive dependencies), call :fn with those
  instances followed by the string arguments, then stop what was
  started (reverse dependency order). Returns the command's return
  value.``
  [boot command args]
  (def f (command :fn))
  (when (symbol? f)
    (errorf "command %q: :fn is the symbol %q — symbol resolution for CLI commands is not wired yet, contribute a function"
            (command :name) f))
  (def needs (get command :needs []))
  (def sys (boot :system))
  (unless (empty? needs)
    (system/start sys needs))
  (defer (system/stop sys)
    (f ;(map |(get-in sys [:instances $]) needs) ;args)))

# -- deploy check --------------------------------------------------------

(defn deploy-check
  ``The body of `void deploy check` — is this composition fit for the
  shape it is about to be deployed in? Prints the shape, why it is
  that, and one row per store: shared, per-process (with what to
  compose instead) or per-process by design (with why that is right).

  It starts only the components the store declarations name — a check
  you can run on a machine that is already serving must not open the
  listening socket — and stops them again. Exits 1 when a `:fleet`
  composition holds a store that lives in one process's heap, which is
  the verdict `plugin/start!` would reach anyway, printed before the
  deploy rather than during it (ADR-0030).``
  [boot]
  (def sys (boot :system))
  (def wanted (deploy/needs boot))
  (unless (empty? wanted)
    (system/start sys wanted))
  (defer (system/stop sys)
    (def entries (deploy/survey boot))
    (each l (deploy/report boot entries) (print l))
    (when (and (deploy/fleet?) (not (empty? (deploy/per-process entries))))
      # the verdict goes to stderr, the report to stdout; flush first so
      # the two arrive in the order they were written
      (flush)
      (eprint)
      (eprint (deploy/message entries (get (deploy/deployment) :reason "resolved")))
      (os/exit 1))
    entries))

# -- help ----------------------------------------------------------------

(def builtin-help
  [["new NAME" "create a project skeleton in ./NAME"]
   ["make resource NAME" "scaffold entity + routes + views + migration + tests"]
   ["make auth [NAME]" "scaffold register/login/logout, reset and verify"]
   ["dev" "run the app in the :dev profile (watcher + netrepl by default)"]
   ["repl" "connect to the running app's netrepl (see void repl --help)"]
   ["deploy check" "is this composition fit for [:deploy :shape]?"]
   ["plugins" "print the composition: plugins, points, contribution chains"]
   ["plugins lock" "write void.lock — the composition, as a value"]
   ["plugins check" "does the composition still match void.lock? (CI)"]
   ["version" "print the void/core version"]
   ["help" "this message"]])

(defn- print-help [commands]
  (print "void — the void framework CLI")
  (print)
  (print "Usage: void [--app MODULE] [--profile PROFILE] <command> [args]")
  (print)
  (print "Built-in commands:")
  (each [words doc] builtin-help
    (printf "  %-18s %s" words doc))
  (if (nil? commands)
    (do
      (print)
      (print "App commands: none — no app module found here")
      (print "  (`void new myapp` scaffolds one; run `void` inside a project)"))
    (do
      (print)
      (print "App commands (:void.core/cli):")
      (each c commands
        (printf "  %-18s %s"
                (string/join (command-words (c :name)) " ")
                (get c :doc ""))))))

# -- entrypoint ----------------------------------------------------------

(def- global-flags {"--app" :app "--profile" :profile})

(defn- parse-global
  "Split argv into {:app :profile} global options and the remaining
  words. Global flags are only recognized before the command word."
  [argv]
  (def opts @{})
  (var i 0)
  (while (< i (length argv))
    (def a (argv i))
    (if-let [k (in global-flags a)]
      (do
        (when (>= (inc i) (length argv))
          (errorf "%s expects a value" a))
        (put opts k (argv (inc i)))
        (+= i 2))
      (break)))
  [opts (tuple ;(drop i argv))])

(defn dispatch
  ``Run one CLI invocation (argv without the program name). Returns the
  command's return value; throws on any failure — `main` turns that
  into exit code 1.

  `app` is the application's boot options when the caller already has
  them — a single binary does (`app-main` below), because `jpm build`
  marshalled them into the executable and there is no module left to
  require. Left out, they are loaded from the project's `main` module
  as ever.``
  [argv &opt app-value]
  (def [gopts words] (parse-global argv))
  (def profile (when-let [p (gopts :profile)] (keyword p)))
  (defn the-app [] (or app-value (load-app (gopts :app))))
  (case (first words)
    nil (print-help nil)
    "help" (let [[ok boot] (protect (bootstrap-app (the-app) profile))]
             (print-help (when ok (plugin/extension boot :void.core/cli))))
    "version" (printf "void %s" core/version)
    "new" (new/create ;(drop 1 words))
    # a built-in because it runs *before* there is a composition to
    # ask: `void make` works in a project whose bootstrap is currently
    # broken, which is often exactly when a file is being added
    "make" (make/create ;(drop 1 words))
    # the one long-running built-in: the full run!/signals lifecycle in
    # the :dev profile (--profile still wins) — `void new && void dev`
    "dev" (do
            (unless (empty? (drop 1 words))
              (errorf "void dev takes no arguments (got %q) — profile via --profile"
                      (string/join (drop 1 words) " ")))
            (void/run! (merge (the-app)
                              {:profile (or profile :dev)})))
    # a built-in rather than a contribution, because void/core owns
    # [:deploy :shape] and void/core is not a plugin (ADR-0030)
    "deploy" (do
               (unless (= ["check"] (tuple ;(drop 1 words)))
                 (errorf "unknown command %q — the only one is `void deploy check`"
                         (string/join words " ")))
               (deploy-check (bootstrap-app (the-app) profile)))
    # likewise a built-in: the manifests are void/core's, and a lock
    # file that only some compositions could write would be a lock
    # file nobody trusts (ADR-0003)
    "plugins" (let [boot (bootstrap-app (the-app) profile)
                    r (lock/dispatch boot (tuple ;(drop 1 words)))]
                # `plugins check` answers false; CI reads exit codes
                (when (false? r) (flush) (os/exit 1))
                r)
    "repl" (repl/connect
             (tuple ;(drop 1 words))
             (fn netrepl-config []
               (get-in (plugin/bootstrap
                         (boot-opts (the-app) profile) true)
                       [:config :values :dev :netrepl] {})))
    (do
      (def app (the-app))
      (def boot (bootstrap-app app profile))
      (def commands (or (plugin/extension boot :void.core/cli) []))
      (def found (find-command commands words))
      (unless found
        (errorf "unknown command %q — `void help` lists the available commands"
                (string/join words " ")))
      (def [command args] found)
      (run-command boot command args))))

(defn- fail [err]
  # log/message-of rather than `describe`: a command that failed on a
  # structured throw used to print `void: <struct 0xAAAA…>`, which is
  # the address of the sentence rather than the sentence
  (eprintf "void: %s" (log/message-of err))
  (os/exit 1))

(defn main
  "Binscript entrypoint: `args` as janet passes them (program name
  first). Errors print to stderr and exit 1."
  [& args]
  (add-project-paths! (os/cwd))
  (def [ok err] (protect (dispatch (tuple ;(drop 1 args)))))
  (unless ok (fail err)))

(defn app-main
  ``Entrypoint for an application that carries its own CLI — what the
  `main` of a single binary calls (docs/DEPLOY.md).

  With no arguments it runs the application, exactly as `void/run!`
  would. With arguments it *is* the `void` binary — `db migrate`,
  `routes`, `plugins check`, `jobs work` — against the composition
  that is in this executable and no other. `jpm build` marshals the
  application into the file, so there is no `main.janet` on the target
  for `load-app` to require; the value it would have produced is the
  one being passed in, which is the whole difference.

  `new` and `make` are still reachable and still work: they write
  files and never needed a composition. `repl` connects outward.``
  [app & args]
  (def argv (tuple ;args))
  (if (empty? argv)
    (void/run! app)
    (do
      (add-project-paths! (os/cwd))
      (def [ok result] (protect (dispatch argv app)))
      (unless ok (fail result))
      result)))
