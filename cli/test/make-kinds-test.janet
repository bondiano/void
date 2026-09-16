(import ../test-support/paths)
(import void/cli/make :as make)
(import void/cli/make/job :as job)
(import void/cli/make/plugin :as mplugin)
(import void/cli/make/migration :as migration)
(import void/core/plugin :as plugin)
(import void/jobs)

# The three kinds wave 8.9 added: a job, a plugin and the migration
# `void db new` used to write from inside a bootstrapped application.
# Each one is checked the way the older two are — the declaration is
# read correctly, the files are where the spec says, and the generated
# code runs.

(def root (os/cwd))
(def sandbox (string root "/.tmp-make-kinds-" (os/time)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(defn- parses? [path]
  (def p (parser/new))
  (parser/consume p (slurp path))
  (parser/eof p)
  (not (parser/error p)))

# -- the dispatch is the table -------------------------------------------

(each k ["resource" "auth" "job" "plugin" "migration"]
  (assert (in make/kinds k) (string "`void make " k "` is a kind")))
(each entry (values make/kinds)
  (def c (entry :command))
  (assert (keyword? (c :name)) "each kind declares a command struct")
  (assert (indexed? (c :args)) "with its positionals")
  (assert (function? (entry :fn)) "and the generator behind it"))

(assert (not (first (protect (make/create "nosuchkind"))))
        "an unknown kind is refused by name")

# -- the specs -----------------------------------------------------------

(def js (job/job-spec "SendWelcome" [] {:project "demo"}))
(assert (= "send-welcome" (js :name)) "the name is normalized once")
(assert (= "demo/send-welcome-job" (js :plugin)) "and becomes a plugin keyword")
(assert (= "jobs/send-welcome" (js :module-path)) "the module lands under jobs/")
(assert (= :default (js :queue)) "the queue defaults")
(assert (not (first (protect (job/job-spec "Bad_Name!" []))))
        "a name that cannot be a job keyword is refused")

(def ps (mplugin/plugin-spec "billing" {:project "demo"}))
(assert (= "demo/billing" (ps :plugin)))
(assert (= "billing" (ps :module-path)) "a plugin lands beside app.janet")

(def ms (migration/migration-spec "add users index" {:version "20260101000000"}))
(assert (= "add_users_index" (ms :slug)) "spaces become underscores")
(assert (= "db/migrations" (ms :migrations-dir)) "and the default dir is the usual one")
(assert (not (first (protect (migration/migration-spec "x" {:version "../v"}))))
        "--version must be a migration timestamp, not a path")

(defer (do (os/cd root) (rimraf sandbox))
  (os/cd sandbox)
  (spit "project.janet" "(declare-project\n  :name \"demo\"\n  :version \"0.1.0\")\n")

  # -- make migration ----------------------------------------------------

  (def [mpath]
    (make/create "migration" "add-users-index" "--version" "20260101000000"))
  (assert (= "db/migrations/20260101000000_add_users_index.janet" (string mpath))
          "the file is named the way void/db reads one")
  (assert (parses? mpath) "and it parses")
  (def env (dofile mpath))
  (assert (function? (get-in env ['up :value])) "with an up")
  (assert (function? (get-in env ['down :value])) "and a down")

  (assert (not (first (protect (make/create "migration" "add-users-index"
                                            "--version" "20260101000000"))))
          "an existing migration is not overwritten")

  # -- make job ----------------------------------------------------------

  (def written
    (make/create "job" "send-welcome" "user-id:int"
                 "--queue" "mail" "--max-attempts" "3" "--schedule" "0 3 * * *"))
  (assert (deep= ["jobs/send-welcome.janet" "test/send-welcome-job-test.janet"]
                 (tuple ;(map string written)))
          "one file per template entry, where the spec says")
  (each f written (assert (parses? f) (string f " parses")))

  (def module (slurp "jobs/send-welcome.janet"))
  (assert (string/find "(jobs/defjob send-welcome" module) "the job is declared")
  (assert (string/find ":queue :mail" module) "--queue reaches the policy")
  (assert (string/find ":max-attempts 3" module) "--max-attempts too")
  (assert (string/find "(jobs/defschedule send-welcome-schedule" module)
          "--schedule adds the schedule that fires it")
  (assert (string/find "[user-id]" module) "and the arguments are the job's parameters")

  (def without-schedule
    (make/create "job" "recount" "--dir" "work" "--dry-run"))
  (assert (not (os/stat "work/recount.janet")) "--dry-run writes no file")
  (assert (= "work/recount.janet" (string (first without-schedule)))
          "--dir moves the module")

  # the generated job runs, and its own suite passes: the module is
  # loaded here so that `defjob` registers, then the suite's assertions
  # are made against that registration
  (array/insert module/paths 0 [(string (os/cwd) "/:all:.janet") :source])
  (def job-env (require "jobs/send-welcome"))
  (def d (jobs/job-of :send-welcome))
  (assert d "the job registered under the name a schedule and a retry use")
  (assert (= :mail (get-in d [:opts :queue])) "on the queue it declares")
  (assert (= :done (jobs/perform :send-welcome 42))
          "and the body runs on the arguments an enqueue would carry")

  # -- make plugin -------------------------------------------------------

  (def plugin-files (make/create "plugin" "billing"))
  (assert (deep= ["billing.janet" "test/billing-plugin-test.janet"]
                 (tuple ;(map string plugin-files)))
          "the module lands beside app.janet")
  (each f plugin-files (assert (parses? f) (string f " parses")))

  (def penv (require "billing"))
  (def manifest (get-in penv ['manifest :value]))
  (assert manifest "the generated module exports a manifest")
  (assert (= :demo/billing (manifest :name)) "named after the project and the word")

  (def boot (plugin/start! {:plugins [manifest] :profile :test}))
  (def inst (get-in boot [:system :instances :billing/service]))
  (assert inst "the component starts under the config its own slice defaults")
  (assert (= "hello, Ada!" ((get-in penv ['serve :value]) inst "Ada"))
          "and the plugin does its work")
  (def commands (plugin/extension boot :void.core/cli))
  (def greet (find |(= :billing/greet ($ :name)) commands))
  (assert greet "the contribution reaches the point it is addressed to")
  (assert (deep= ["NAME..."] (tuple ;(greet :args)))
          "declaring its surface as data, the way the scaffold teaches")
  (plugin/shutdown! boot))

(print "make-kinds-test ok")
