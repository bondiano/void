### void/cli — the `void` binary.
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
### A handful of commands are built in rather than contributed, and for
### one reason each: `new` and `make` run *before* there is a
### composition to ask (./new, ./make), `repl` has to reach a process
### this one is not (./repl), and `deploy check` and `plugins lock` read
### what void/core owns — the deployment shape and the manifests — and
### void/core is not a plugin. They are declared as the same struct a
### contributed command is (`builtins` below), so the help listing,
### `--help` and the flag parsing are one implementation for both, and
### the table *is* the dispatch rather than a second description of it.
###
### What a command takes is data — `:args`, `:flags` — and
### void/core/cli is the only thing that reads it. That is what lets
### `void <anything> --help` and `void help` answer without a
### bootstrap: a declaration is readable from the manifests alone.

(import void)
(import void/core/init :as core)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/hooks :as hooks)
(import void/core/deploy :as deploy)
(import void/core/bind :as bind)
(import void/core/cli :as cmd)
(import void/core/util :as util)
(import ./new :as new)
(import ./repl :as repl)
(import ./make :as make)
(import ./lock :as lock)
(import ./doctor :as doctor)
(import ./services :as services)

(def default-app-module
  "Module the CLI loads to find the application: `main` — the file
  `void new` generates."
  "main")

(defn add-project-paths!
  {:params [:string] :ret @[[:string :keyword]]}
  "Make the project tree importable: its root (main.janet, app.janet)
  goes on module/paths, like the generated project expects."
  [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(defn load-app
  {:params [:string?]
   :ret {:plugins :any
         :plugins-for (or (fn [:keyword] :any) :nil)
         :profile :keyword?
         :config :any
         :signals (or [:keyword] :nil)
         :shutdown-timeout :number?
         & r}
   :throws [:string]}
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

(defn resolve-plugins
  {:params [{:plugins :any
             :plugins-for (or (fn [:keyword] :any) :nil)
             :profile :keyword?
             :config :any
             :signals (or [:keyword] :nil)
             :shutdown-timeout :number?
             & r}
            :keyword]
   :ret :any
   :throws [:string]}
  ``The app's composition for a profile. An app that declares
  :plugins-for — (fn [profile] plugins), the explicit contract run!
  honors too — is asked; anything else keeps its :plugins list. This
  is what keeps `void dev --profile prod` and `VOID_PROFILE=prod janet
  main.janet` the same application, without the CLI guessing at the
  signature of some binding in main.janet.``
  [app profile]
  (if-let [f (get app :plugins-for)]
    (do
      (unless (function? f)
        (errorf ":plugins-for must be (fn [profile] plugins), got %q" f))
      (f profile))
    (get app :plugins)))

# -- command words -------------------------------------------------------

(def command-words
  "The argv words a command keyword answers to (void/core/cli)."
  cmd/command-words)

(defn find-command
  {:params [[{:name :keyword
              :flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil)
              :args (or @[:string] :nil)
              & r}]
            [:string]]
   :ret (or [{:name :keyword
              :flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil)
              :args (or @[:string] :nil)
              & r}
             [:string]]
            :nil)}
  ``Resolve leading argv words against the commands (longest match
  first). Returns [command remaining-args] or nil.``
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

(defn boot-opts
  {:params [{:plugins :any
             :plugins-for (or (fn [:keyword] :any) :nil)
             :profile :keyword?
             :config :any
             :signals (or [:keyword] :nil)
             :shutdown-timeout :number?
             & r}
            :keyword?]
   :ret @{:keyword :any}}
  "Boot options for plugin/bootstrap from the app binding: the
  bootstrap subset of keys (run! extras like :signals are dropped),
  profile overridable from the command line."
  [app profile]
  (def opts @{})
  (each k [:plugins :profile :config]
    (unless (nil? (get app k))
      (put opts k (app k))))
  (when profile (put opts :profile profile))
  (def prof (get opts :profile :dev))
  (when-let [ps (resolve-plugins app prof)]
    (put opts :plugins ps))
  opts)

(defn bootstrap-app
  {:params [{:plugins :any
             :plugins-for (or (fn [:keyword] :any) :nil)
             :profile :keyword?
             :config :any
             :signals (or [:keyword] :nil)
             :shutdown-timeout :number?
             & r}
            :keyword?]
   :ret {:profile :any :system :any :hooks :any :config :any :extensions :any & r}}
  "Bootstrap phases 1-5 for the app, then run the :config-loaded and
  :before-start hooks — after this route tables and plugin contexts
  exist, but no component has started. Returns the boot value."
  [app &opt profile]
  (def boot (plugin/bootstrap (boot-opts app profile)))
  # the CLI path honours [:log] the way run! does (start! configures
  # the logger for the long-running path)
  (log/configure! (get-in boot [:config :values :log]) (boot :profile))
  # and it attaches the boot the way start! does, before the first hook
  # runs: a component asking for `:deps [:void/boot]` — every database
  # driver does — is resolved against the boot in force, and without
  # this line `void db migrate` failed on the seam rather than on
  # anything about migrating
  (system/attach-boot! (boot :system) boot)
  (hooks/run! (boot :hooks) :config-loaded boot)
  (hooks/run! (boot :hooks) :before-start boot)
  boot)

(defn teardown!
  {:params [{:profile :any :system :any :hooks :any :config :any :extensions :any & r}]
   :ret :nil}
  ``The other half of the lifecycle `bootstrap-app` opened, for a
  command that is done: the :before-stop and :after-stop hooks (a
  plugin that allocated something in :before-start gets them on the
  CLI path too), the system stopped, and the async log writers
  closed. That last one is what lets the process exit: in :prod the
  logger writes JDN through a fiber parked on a channel, and a
  command that bootstrapped, printed and returned would otherwise
  leave that fiber holding the event loop open forever — which is
  exactly what `deploy check` did in a built binary.``
  [boot]
  (each e (hooks/run-protected! (boot :hooks) :before-stop boot)
    (eprint e))
  (system/stop (boot :system))
  (each e (hooks/run-protected! (boot :hooks) :after-stop boot)
    (eprint e))
  (log/close!)
  nil)

(defn run-command
  {:params [{:profile :any :system :any :hooks :any :config :any :extensions :any & r}
            {:name :keyword
             :fn :any
             :needs (or @[:keyword] :nil)
             :flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil)
             :args (or @[:string] :nil)
             & r}
            [:string]]
   :ret :any
   :throws [:string]}
  ``Run one contributed command against a bootstrapped app: start the
  :needs components (plus transitive dependencies), call :fn with those
  instances and the arguments (`cmd/call`: parsed against the
  command's own :args/:flags when it declares them), then stop what
  was started (reverse dependency order, `teardown!`). Returns the
  command's return value.

  :fn is a function or a symbol — `'my-app.ops/status` names `status`
  in module `my-app/ops` and is read through that module's env when
  the command runs (void/core/bind), so a command is as live under the
  watcher and the REPL as a route handler is.``
  [boot command args]
  # resolved before anything starts: a command whose symbol names no
  # function fails here, with the symbol in the message, rather than
  # after a pool has been opened for it
  (def f ((bind/resolve (command :fn) nil
                        (string/format "command %q" (command :name)))
          :call))
  (def needs (get command :needs []))
  (def sys (boot :system))
  (unless (empty? needs)
    (system/start sys needs))
  (defer (teardown! boot)
    (cmd/call command f (map |(get-in sys [:instances $]) needs) args)))

# -- deploy check --------------------------------------------------------

(defn deploy-check
  {:params [{:profile :any :system :any :hooks :any :config :any :extensions :any & r}]
   :ret @[{:name :keyword :what :string
           :shared? (or :boolean (enum :by-design :unknown))
           :store :keyword? :why :string? :replacement :string? :error :string?}]}
  ``The body of `void deploy check` — is this composition fit for the
  shape it is about to be deployed in? Prints the shape, why it is
  that, and one row per store: shared, per-process (with what to
  compose instead) or per-process by design (with why that is right).

  It starts only the components the store declarations name — a check
  you can run on a machine that is already serving must not open the
  listening socket — and stops them again. Exits 1 when a `:fleet`
  composition holds a store that lives in one process's heap, which is
  the verdict `plugin/start!` would reach anyway, printed before the
  deploy rather than during it.``
  [boot]
  (def sys (boot :system))
  (def wanted (deploy/needs boot))
  (unless (empty? wanted)
    (system/start sys wanted))
  (defer (teardown! boot)
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

# -- the invocation -----------------------------------------------------

(def global-command
  "The flags that come before the command word, as a command of their
  own: `void --app ops --profile prod routes`. They are a command's
  worth of surface and the help prints them from the same declaration."
  {:name :void
   :doc "the void framework CLI"
   :flags {"--app" {:key :app :doc "module holding the `app` binding (default: main)"}
           "--profile" {:key :profile :type :keyword :doc "profile to boot in (default: :dev)"}}})

# -- help ----------------------------------------------------------------

(defn app-commands
  {:params [{:profile :keyword?
             :built-in [{:name :keyword
                         :flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil)
                         :args (or @[:string] :nil)
                         & r}]
             :app (fn [] :any)}]
   :ret (or [{:name :keyword
              :flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil)
              :args (or @[:string] :nil)
              & r}]
             :nil)}
  ``The `:void.core/cli` commands this project's composition declares,
  or nil when there is no project here (or its main module will not
  load). Phase 1 of bootstrap and no more — `plugin/declared` reads the
  manifests and stops — because the command whose job is to help must
  not be the one that fails on a config file.``
  [ctx]
  (def [ok cmds]
    (protect (plugin/declared (resolve-plugins ((ctx :app)) (or (ctx :profile) :dev))
                              :void.core/cli)))
  (when ok cmds))

(defn- print-help
  {:params [[{:name :keyword :args (or @[:string] :nil) :doc :string? & r}]
            (or [{:name :keyword :args (or @[:string] :nil) :doc :string? & r}] :nil)]
   :ret :nil}
  ``The listing `void` and `void help` print: two tables of the same
  declaration, rendered by the same `cmd/summary`. `contributed` is nil
  when there is no project here to ask, which is a different sentence
  from an app that contributes nothing.``
  [built-in contributed]
  (print "void — the void framework CLI")
  (print)
  (printf "Usage: %s <command> [args]"
          (string/join ["void" ;(cmd/flag-usage global-command)] " "))
  (print "       void <command> --help")
  (print)
  (print "Built-in commands:")
  (each c built-in (print (cmd/summary c)))
  (if (nil? contributed)
    (do
      (print)
      (print "App commands: none — no app module found here")
      (print "  (`void new myapp` scaffolds one; run `void` inside a project)"))
    (do
      (print)
      (print "App commands (:void.core/cli):")
      (each c (sorted-by |($ :name) contributed) (print (cmd/summary c))))))

# -- the built-in commands -----------------------------------------------
#
# Declared exactly as a contributed command is — :name, :doc, :args,
# :flags — so the help listing, `--help` and the flag parsing are the
# same code for both, and the table below *is* the dispatch rather than
# a second description of it. The one difference is the key that runs
# them: a built-in's `:run` takes the invocation context (the app
# thunk, the profile) that a contributed command's `:fn` gets as
# started components, because these four run before there is a
# composition to start.

(defn- run-builtin
  {:params [{:profile :keyword?
             :built-in [{:name :keyword
                         :flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil)
                         :args (or @[:string] :nil)
                         & r}]
             :app (fn [] :any)}
            {:name :keyword
             :flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil)
             :args (or @[:string] :nil)
             :run (fn [:any :any :any] :any)
             & r}
            [:string]]
   :ret :any
   :throws [:string]}
  "Parse a built-in command's args against its own declaration, then
  call its :run with the invocation context, the parsed flags and the
  remaining positionals."
  [ctx command args]
  (def [opts pos] (cmd/parse command args))
  ((command :run) ctx opts pos))

(def builtins
  ``The commands that are built in rather than contributed, and for one
  reason each: `new` and `make` run *before* there is a composition to
  ask, `doctor` is the command for the machine where nothing else works
  (a broken bootstrap is one of its rows, never its crash), `services`
  starts the infrastructure a plugin will *want* running, `repl` has to
  reach a process this one is not, and `deploy check` / `plugins` read
  what void/core owns — the deployment shape and the manifests — where
  void/core is not a plugin.``
  [{:name :new
    :doc "create a project skeleton in ./NAME"
    :args ["NAME"]
    :run (fn [_ _ pos] (new/create ;pos))}

   {:name :make
    :doc "scaffold into an existing project: resource, auth, job, plugin, migration"
    :args ["[KIND]" "[ARG...]"]
    # the one built-in that dispatches again: `void make job --help` is
    # a question about the job generator, so the `--help` interception
    # below has to let it through rather than answer it here
    :own-help? true
    :run (fn [_ _ pos] (make/create ;pos))}

   {:name :dev
    :doc "run the app in the :dev profile (watcher + netrepl by default)"
    :args []
    # the one long-running built-in: the full run!/signals lifecycle,
    # so `void new && void dev` is the whole first session. An app that
    # declares :plugins-for gets its composition for *this* profile —
    # run! resolves the same key, so `void dev` and `janet main.janet`
    # cannot drift
    :run (fn [ctx _ _]
           (void/run! (merge ((ctx :app)) {:profile (or (ctx :profile) :dev)})))}

   {:name :doctor
    :doc "is this machine ready? toolchain, libraries, port, socket"
    :args []
    :run (fn [ctx _ _] (doctor/run (ctx :app)))}

   {:name :services
    :doc "dev infrastructure: up|down|status|logs|print (docker compose)"
    :args ["ACTION" "[ARG...]"]
    :run (fn [_ _ pos] (services/run pos))}

   {:name :repl
    :doc "connect to the running app's netrepl"
    :args []
    :flags {"--unix" {:key :unix :doc "path of the netrepl unix socket"}
            "--host" {:key :host :doc "host of a tcp netrepl"}
            "--port" {:key :port :doc "port of a tcp netrepl (default 9365)"}}
    :run (fn [ctx opts _]
           (repl/connect opts
                         (fn netrepl-config []
                           (get-in (plugin/bootstrap
                                     (boot-opts ((ctx :app)) (ctx :profile)) true)
                                   [:config :values :dev :netrepl] {}))))}

   {:name :deploy/check
    :doc "is this composition fit for [:deploy :shape]?"
    :args []
    :run (fn [ctx _ _] (deploy-check (bootstrap-app ((ctx :app)) (ctx :profile))))}

   {:name :plugins
    :doc "print the composition: plugins, points, contribution chains"
    :args []
    :run (fn [ctx _ _] (lock/show (bootstrap-app ((ctx :app)) (ctx :profile))))}

   {:name :plugins/lock
    :doc "write void.lock — the composition, as a value"
    :args []
    :flags {"--out" {:key :path :doc "where to write it (default: void.lock)"}}
    :run (fn [ctx opts _]
           (lock/write-lock (bootstrap-app ((ctx :app)) (ctx :profile)) opts))}

   {:name :plugins/check
    :doc "does the composition still match void.lock? (CI)"
    :args []
    :flags {"--lock" {:key :path :doc "the lock file to compare against"}}
    # `check` answers false; CI reads exit codes
    :run (fn [ctx opts _]
           (def r (lock/check-lock (bootstrap-app ((ctx :app)) (ctx :profile)) opts))
           (when (false? r) (flush) (os/exit 1))
           r)}

   {:name :version
    :doc "print the void/core version"
    :args []
    :run (fn [_ _ _] (printf "void %s" core/version))}

   {:name :help
    :doc "this message"
    :args []
    :run (fn [ctx _ _] (print-help (ctx :built-in) (app-commands ctx)))}])

# -- entrypoint ----------------------------------------------------------

(defn- split-global
  {:params [[:string]]
   :ret [@{:keyword :any} [:string]]
   :throws [:string]}
  ``Split argv into the global flags — which are only recognized before
  the command word, so `void routes --profile x` is the command's
  business and not ours — and the words from the command on. The flags
  themselves are read by the one parser, off `global-command`.``
  [argv]
  (var i 0)
  (while (and (< i (length argv)) (in (global-command :flags) (argv i)))
    (+= i 2))
  (def [opts _] (cmd/parse global-command (tuple ;(slice argv 0 (min i (length argv))))))
  [opts (tuple ;(drop i argv))])

(defn- unknown-command
  {:params [[:string] @[:keyword]] :ret :never :throws [:string]}
  "The error for a first word that names no built-in and no
  contributed command, with a `did you mean` suggestion off the
  known command names."
  [words names]
  (errorf "unknown command %q — `void help` lists the available commands%s"
          (string/join words " ")
          (util/suggest (first words) (map |(first (cmd/command-words $)) names))))

(defn dispatch
  {:params [[:string]
            (or {:plugins :any
                 :plugins-for (or (fn [:keyword] :any) :nil)
                 :profile :keyword?
                 :config :any
                 :signals (or [:keyword] :nil)
                 :shutdown-timeout :number?
                 & r}
                :nil)]
   :ret :any
   :throws [:string]}
  ``Run one CLI invocation (argv without the program name). Returns the
  command's return value; throws on any failure — `main` turns that
  into exit code 1.

  Resolution is one lookup over two tables — the built-ins above and
  whatever the composition contributes — and `--help` is answered off
  the declaration before either of them starts anything.

  `app` is the application's boot options when the caller already has
  them — a single binary does (`app-main` below), because `jpm build`
  marshalled them into the executable and there is no module left to
  require. Left out, they are loaded from the project's `main` module
  as ever.``
  [argv &opt app-value]
  (def [gopts words] (split-global argv))
  (def ctx {:profile (gopts :profile)
            :built-in builtins
            :app (fn the-app [] (or app-value (load-app (gopts :app))))})
  (if (empty? words)
    (print-help builtins (app-commands ctx))
    (if-let [[command args] (find-command builtins words)]
      (if (and (cmd/help-wanted? command args) (not (get command :own-help?)))
        (each l (cmd/help command) (print l))
        (run-builtin ctx command args))
      # a contributed command: its declaration is readable without a
      # bootstrap, so `void jobs list --help` costs a `require` and not
      # a composition
      (let [declared (or (app-commands ctx) [])
            found (find-command declared words)]
        (cond
          (and found (cmd/help-wanted? (first found) (get found 1)))
          (each l (cmd/help (first found)) (print l))

          (let [boot (bootstrap-app ((ctx :app)) (ctx :profile))
                live (find-command (or (plugin/extension boot :void.core/cli) []) words)]
            (unless live
              (teardown! boot)
              (unknown-command words (map |($ :name) (array ;builtins ;declared))))
            (run-command boot (first live) (get live 1))))))))

(defn- fail
  {:params [:any] :ret :never}
  "Print a failed command's error and exit 1. `err` is whatever was
  thrown — a string or a structured value — and `log/message-of` is
  what turns either into a sentence."
  [err]
  # log/message-of rather than `describe`: a command that failed on a
  # structured throw used to print `void: <struct 0xAAAA…>`, which is
  # the address of the sentence rather than the sentence
  (eprintf "void: %s" (log/message-of err))
  (os/exit 1))

(defn main
  {:params [:string] :ret :nil}
  "Binscript entrypoint: `args` as janet passes them (program name
  first). Errors print to stderr and exit 1."
  [& args]
  (add-project-paths! (os/cwd))
  (def [ok err] (protect (dispatch (tuple ;(drop 1 args)))))
  (unless ok (fail err)))

(defn app-main
  {:params [:any :string] :ret :any :throws [:string]}
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
