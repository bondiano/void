### void/cli/services — `void services up|down|status|logs|print`: the
### dev infrastructure, by its compose file.
###
### A thin wrapper on purpose: every subcommand is one `docker compose
### -f docker-compose.dev.yml ...` invocation, printed before it runs,
### so the day this wrapper is outgrown the command underneath is
### already in the shell history. The file itself is `void new`'s; for
### a project that predates it there is `print`, which renders the same
### template to stdout and writes nothing — printing beats editing.

(import ./new :as new)

(def compose-file
  "The one file this command wraps."
  "docker-compose.dev.yml")

(def actions
  "Subcommand -> the compose words it stands for. `up` detaches and
  `logs` follows, because this is a laptop's infrastructure, not a
  foreground process."
  {"up" ["up" "-d"]
   "down" ["down"]
   "status" ["ps"]
   "logs" ["logs" "--follow" "--tail" "100"]})

(defn plan
  {:params [:string :string] :ret [:string] :throws [:string]}
  "The full argv for one subcommand (extra words pass through to
  compose). Throws by name on a subcommand that is not one."
  [action & extra]
  (def words (actions action))
  (when (nil? words)
    (errorf "unknown subcommand %q — void services up|down|status|logs|print"
            (string action)))
  ["docker" "compose" "-f" compose-file ;words ;extra])

(defn- project-name
  {:params [] :ret :string}
  "The compose template's one hole, from the directory this runs in —
  squeezed to the [a-z0-9-] a project name is made of."
  []
  (def base (last (string/split "/" (os/cwd))))
  (def out @"")
  (each b (string/ascii-lower base)
    (def c (string/from-bytes b))
    (when (peg/match '(+ (range "az") (range "09") "-") c)
      (buffer/push-string out c)))
  (if (empty? out) "app" (string out)))

(defn- docker-missing
  {:params [] :ret :never :throws [:string]}
  "Explain why `docker` has to be on PATH for this command to run."
  []
  (error "docker is not on PATH — `void services` is docker compose with the file name filled in; install docker, or run postgres/redis your own way (the file says which ports the app expects)"))

(defn- file-missing
  {:params [] :ret :never :throws [:string]}
  "Explain that the compose file `void new` writes is missing here, and
  how to get an equivalent one without it."
  []
  (errorf "no %s here — `void new` writes it; for an existing project, print the same template and keep what you like:\n  void services print > %s"
          compose-file compose-file))

(defn- on-path?
  {:params [:string] :ret :boolean? :narrows :any}
  "Whether an executable of this name is somewhere on PATH."
  [name]
  (when-let [path-env (os/getenv "PATH")]
    (some (fn [dir]
            (unless (empty? dir)
              (= :file (os/stat (string dir "/" name) :mode))))
          (string/split ":" path-env))))

(defn run
  {:params [[:string]] :ret (or :nil :number) :throws [:string]}
  "The command. `print` writes the rendered template to stdout and
  nothing else; the rest exec docker compose and return its exit code
  (non-zero exits non-zero, so CI can trust it)."
  [words]
  (def [action & extra] (if (empty? words) [nil] words))
  (cond
    (nil? action)
    (error "usage: void services up|down|status|logs|print")

    (= "print" action)
    (do (prin (new/render-compose (project-name))) nil)

    (do
      (def argv (plan action ;extra))
      (unless (os/stat compose-file) (file-missing))
      (unless (on-path? "docker") (docker-missing))
      (print "  " (string/join argv " "))
      (def code (os/execute argv :p))
      (unless (zero? code)
        (flush)
        (os/exit code))
      code)))
