### void/cli/doctor — `void doctor`: is this machine ready to run this
### project?
###
### Nothing is started and nothing is opened: the toolchain is looked
### up on PATH, the libraries are looked for on disk along the same
### candidate list the plugin that needs them will try (each driver's
### `candidates` — libpq.janet and friends), the port is knocked on,
### the netrepl socket is stat'ed. Every row is a verdict and a phrase:
### ok, warn (a run may still work — the note says when), or fail (it
### will not — the note says the fix).
###
### The command has to work exactly when nothing else does, so every
### project-shaped step is protected: a broken `main.janet` becomes a
### row rather than a stack trace, and a directory with no project at
### all gets the toolchain half and nothing else.

(import void/core/plugin :as plugin)
(import void/core/log :as log)

(def min-janet
  "The oldest janet the framework is tested against."
  [1 41 0])

(defn parse-version
  "\"1.41.2-meta\" -> (1 41 2): the numeric dot-parts, pre-release
  suffix dropped."
  [s]
  (def numeric (first (string/split "-" (string s))))
  (tuple ;(map |(or (scan-number $) 0) (string/split "." numeric))))

(defn version<?
  "Numeric tuple comparison, missing parts read as 0."
  [a b]
  (var r false)
  (var decided false)
  (loop [i :range [0 (max (length a) (length b))] :until decided]
    (def x (get a i 0))
    (def y (get b i 0))
    (unless (= x y)
      (set r (< x y))
      (set decided true)))
  r)

(defn which
  "First PATH entry holding `name`, or nil — presence, not a spawn."
  [name]
  (when-let [path-env (os/getenv "PATH")]
    (some (fn [dir]
            (unless (empty? dir)
              (def full (string dir "/" name))
              (when (= :file (os/stat full :mode)) full)))
          (string/split ":" path-env))))

(defn port-listening?
  "Does anything accept on host:port right now? A refused connection
  is the good answer here."
  [host port]
  (def [ok stream]
    (protect (ev/with-deadline 1 (net/connect host (string port) :stream))))
  (when ok (:close stream))
  ok)

# -- the libraries the composition names ---------------------------------
#
# The same resolution the plugin will do at :start — the configured
# path, then the module's own candidate list — but stat instead of
# dlopen. Absolute candidates are checked directly; bare names go to
# the loader's usual directories, and a miss there is a warn rather
# than a fail, because the loader searches further than a stat can.

(def libraries
  "One entry per plugin that opens a system library at :start."
  [{:plugin :void/db-postgres :label "libpq"
    :module "void/db-postgres/libpq" :config-path [:db-postgres :libpq]
    :hint "brew install libpq / apt install libpq5"}
   {:plugin :void/db-mysql :label "libmysqlclient"
    :module "void/db-mysql/libmysql" :config-path [:db-mysql :library]
    :hint "brew install mysql-client / apt install libmysqlclient21"}
   {:plugin :void/kafka :label "librdkafka"
    :module "void/kafka/librdkafka" :config-path [:kafka :library]
    :hint "brew install librdkafka / apt install librdkafka1"}
   {:plugin :void/tls :label "libssl"
    :module "void/tls/lib" :config-path [:tls :libssl]
    :hint "brew install openssl@3 / apt install libssl3"}])

(def- loader-dirs
  ["/usr/lib" "/usr/local/lib" "/usr/lib64"
   "/usr/lib/x86_64-linux-gnu" "/usr/lib/aarch64-linux-gnu"
   "/opt/homebrew/lib" "/opt/local/lib"])

(defn- search-dirs []
  (def env @[])
  (each name ["DYLD_LIBRARY_PATH" "LD_LIBRARY_PATH"]
    (when-let [v (os/getenv name)]
      (array/concat env (filter |(not (empty? $)) (string/split ":" v)))))
  [;env ;loader-dirs])

(defn find-library
  "First candidate that exists on disk: absolute ones stat'ed as they
  are, bare names looked for in the loader's usual directories. Nil
  means only the loader itself can still find it."
  [cands]
  (some (fn [c]
          (if (string/find "/" c)
            (when (os/stat c) c)
            (some (fn [dir]
                    (def full (string dir "/" c))
                    (when (os/stat full) full))
                  (search-dirs))))
        cands))

(defn- path-str
  "A config path as a person writes it: [:db-postgres :libpq]."
  [path]
  (string "[" (string/join (map |(string/format "%q" $) path) " ") "]"))

(defn- library-row
  "One row per named library, degrading honestly: no module here means
  the plugin will speak for itself at :start."
  [{:label label :module module :config-path config-path :hint hint} values]
  (def [ok env] (protect (require module)))
  (def candidates-fn (when ok (get-in env ['candidates :value])))
  (if (nil? candidates-fn)
    {:status :warn :name label
     :note (string "the driver module is not importable here — the plugin"
                   " will name its candidates itself at :start")}
    (do
      (def configured (get-in values config-path))
      (def cands (candidates-fn configured))
      (if-let [found (find-library cands)]
        {:status :ok :name label :note found}
        {:status :warn :name label
         :note (string/format
                 "not found where doctor looked — the loader searches further; if :start fails, point %s at the file (%s)"
                 (path-str config-path) hint)}))))

# -- gathering ------------------------------------------------------------

(defn- plugin-names
  "The :plugins list as keywords: keyword entries as they are, inline
  manifests by their :name."
  [app]
  (seq [p :in (get app :plugins [])]
    (cond
      (keyword? p) p
      (dictionary? p) (keyword (get p :name))
      (keyword (string p)))))

(defn- toolchain-rows []
  (def rows @[])
  (def jv (parse-version janet/version))
  (array/push rows
    (if (version<? jv min-janet)
      {:status :fail :name "janet"
       :note (string/format "%s — void wants >= %s; upgrade: https://janet-lang.org"
                            janet/version (string/join (map string min-janet) "."))}
      {:status :ok :name "janet" :note janet/version}))
  (array/push rows
    (if-let [jpm (which "jpm")]
      {:status :ok :name "jpm" :note jpm}
      {:status :fail :name "jpm"
       :note "not on PATH — `jpm --local deps` is how void arrives; install: https://github.com/janet-lang/jpm"}))
  (def cc-name (or (os/getenv "CC") "cc"))
  (array/push rows
    (if-let [cc (which cc-name)]
      {:status :ok :name "cc" :note cc}
      {:status :warn :name "cc"
       :note "no C compiler — only native modules need one (xcode-select --install / apt install build-essential)"}))
  (array/push rows
    (if-let [docker (which "docker")]
      {:status :ok :name "docker" :note docker}
      {:status :warn :name "docker"
       :note "not on PATH — `void services` runs the dev infrastructure with it; without docker, run postgres/redis your own way"}))
  rows)

(defn- socket-row
  "The netrepl socket, when a file is at its path: it must be a
  socket, and it should be nobody's but the owner's — a netrepl is an
  unauthenticated eval in the process."
  [path]
  (when-let [st (os/stat path)]
    (def perms (get st :permissions ""))
    (cond
      (not= :socket (st :mode))
      {:status :fail :name "netrepl"
       :note (string/format "%s exists and is not a socket — remove it, or point [:dev :netrepl :unix] elsewhere" path)}
      (and (>= (length perms) 9) (string/find "w" (string/slice perms 3)))
      {:status :warn :name "netrepl"
       :note (string/format "%s is writable beyond its owner (%s) — a netrepl is an unauthenticated eval; chmod 600 it" path perms)}
      {:status :ok :name "netrepl"
       :note (string/format "%s (%s) — a `void dev` may be running" path perms)})))

(defn- project-rows
  "The half that needs a project: the app, its config, its port, its
  libraries. Every step protected — a failing step is a row."
  [load-app]
  (def rows @[])
  (def [app-ok app] (protect (load-app)))
  (if (not app-ok)
    (array/push rows
      {:status :fail :name "app"
       :note (string (log/message-of app))})
    (do
      (def names (plugin-names app))
      (def [boot-ok boot]
        (protect (plugin/bootstrap
                   (merge {:profile :dev}
                          (tabseq [k :in [:plugins :profile :config]
                                   :when (get app k)] k (app k)))
                   true)))
      (def values (if boot-ok (get-in boot [:config :values] {}) {}))
      (array/push rows
        (if boot-ok
          {:status :ok :name "app"
           :note (string/format "%d plugins, profile %q bootstraps"
                                (length names) (get boot :profile :dev))}
          {:status :fail :name "app"
           :note (string "loads, but does not bootstrap: " (log/message-of boot))}))
      # the port the composition would open, knocked on rather than bound
      (when (index-of :void/http names)
        (def port (get-in values [:http :port] 8080))
        (array/push rows
          (if (port-listening? "127.0.0.1" port)
            {:status :warn :name (string "port " port)
             :note "something already answers — maybe your own `void dev`; [:http :port] picks another"}
            {:status :ok :name (string "port " port) :note "free"})))
      # the libraries only the named plugins will open
      (each spec libraries
        (when (index-of (spec :plugin) names)
          (array/push rows (library-row spec values))))
      # the dev socket, wherever this composition puts it
      (when-let [row (socket-row (get-in values [:dev :netrepl :unix]
                                         ".void/repl.sock"))]
        (array/push rows row))))
  rows)

(defn gather
  "Every row `void doctor` prints. `load-app` is the CLI's own loader
  (init.janet passes it in); without one — or without a main.janet —
  the toolchain half is the whole of the answer."
  [&opt load-app]
  (def rows (toolchain-rows))
  (if (and load-app (os/stat "main.janet"))
    (array/concat rows (project-rows load-app))
    (array/push rows
      {:status :ok :name "project"
       :note "no main.janet here — toolchain checks only (`void doctor` inside a project checks its port and libraries too)"}))
  rows)

# -- the report -----------------------------------------------------------

(def- status-word {:ok "ok" :warn "warn" :fail "FAIL"})

(defn report
  "The rows as printed lines, verdict last."
  [rows]
  (def lines @[])
  (each r rows
    (array/push lines
      (string/format "  %-5s %-16s %s" (status-word (r :status))
                     (r :name) (r :note))))
  (def fails (count |(= :fail ($ :status)) rows))
  (def warns (count |(= :warn ($ :status)) rows))
  (array/push lines "")
  (array/push lines
    (cond
      (pos? fails)
      (string/format "  %d problem%s — the FAIL lines say the fix."
                     fails (if (= 1 fails) "" "s"))
      (pos? warns)
      (string/format "  %d warning%s — nothing blocks a run; the notes say when it would."
                     warns (if (= 1 warns) "" "s"))
      "  everything answers — this machine is ready."))
  lines)

(defn run
  "The command: gather, print, exit 1 when a row is a FAIL (CI reads
  exit codes; a person reads the phrases)."
  [words &opt load-app]
  (unless (empty? words)
    (errorf "void doctor takes no arguments (got %q)"
            (string/join words " ")))
  (def rows (gather load-app))
  (each l (report rows) (print l))
  (when (some |(= :fail ($ :status)) rows)
    (flush)
    (os/exit 1))
  rows)
