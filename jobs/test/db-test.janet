(import ../test-support/paths)
(import ../test-support/conformance :as conformance)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/db/driver :as driver)
(import void/db/pool :as pool)
(import void/db/state :as db)
(import void/db-sqlite/driver :as sqlite)
(import void/jobs :as jobs)
(import void/jobs/backend :as backend)
(import void/jobs/db :as jobsdb)
(import void/jobs/job :as job)
(import void/jobs/record :as record)
(import void/jobs/state :as state)
(import void/jobs/worker :as worker)

(each ns ["void.db" "void.db.query" "void.jobs" "void.jobs.db" "void.jobs.worker"]
  (log/set-level! ns :fatal))

# The db backend is tested against the reference driver — sqlite,
# which is also the engine *without* SKIP LOCKED, so what runs here is
# the portable claim path. The Postgres path (one statement, FOR
# UPDATE SKIP LOCKED) is different code for the same contract, and it
# runs the same conformance suite in test/db-postgres-test.janet when
# VOID_TEST_PG names a server; ROADMAP 2.4.

(def sandbox (string (os/cwd) "/.tmp-jobs-db-" (os/time) "-" (os/getpid)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(def p (pool/make (driver/normalize (sqlite/make {:path (string sandbox "/jobs.sqlite3")}))
                  {:size 2}))

(defer (do (pool/close-all! p) (rimraf sandbox))
  (with-dyns [db/pool-dyn p]
    (jobsdb/create-tables!)

    # -- the contract ----------------------------------------------------

    (conformance/run! "db" (jobsdb/store {}))

    # -- the schema ------------------------------------------------------

    (assert (>= (length (jobsdb/ddl)) 6)
            "the ddl covers the queue, its indexes, the locks and the rate windows")
    (assert (some |(string/find "unique_key IS NOT NULL" $) (jobsdb/ddl))
            "the uniqueness index is partial — a released key is a NULL, not a deleted row")
    (jobsdb/create-tables!)
    (assert true "creating the tables twice is not an error")

    # -- rows and records --------------------------------------------------

    (def b (backend/normalize (jobsdb/store {})))
    (def rich (record/make {:job :rich :args [1 "two" :three {:m [1 2]}]
                            :queue :mail :priority 2 :group "acme"
                            :timeout 30 :max-attempts 9}))
    ((b :push!) rich)
    (def back ((b :fetch) (rich :id)))
    (each k [:job :queue :priority :group :timeout :max-attempts]
      (assert (= (get rich k) (get back k))
              (string/format "%q survives the row" k)))
    (assert (deep= (rich :args) (tuple ;(back :args))) "and so do the arguments")

    # a released unique key really is a NULL in the column, which is
    # what makes the partial index exact
    ((b :clear!) {})
    (def u ((b :push!) (record/make {:job :u :queue :default :unique-key "k"})))
    (def claimed ((b :claim!) {:queues [:default] :now (os/clock :realtime) :token "w"}))
    ((b :settle!) (record/complete! claimed nil (os/clock :realtime)))
    # sqlite leaves a NULL column out of the row entirely, so an absent
    # key and a null one read the same way here — which is the answer
    # either way: the key is not held
    (def released (db/one {:select [:unique-key] :from "void_jobs"
                           :where {:id (u :id)}}))
    (assert (nil? (get released :unique_key))
            "the column is cleared when the job finishes")

    # -- retention -------------------------------------------------------

    ((b :clear!) {})
    (def keeper (backend/normalize (jobsdb/store {:keep-for 0})))
    (def old ((keeper :push!) (record/make {:job :old :queue :default})))
    (def oc ((keeper :claim!) {:queues [:default] :now (os/clock :realtime) :token "w"}))
    ((keeper :settle!) (record/complete! oc nil (- (os/clock :realtime) 10)))
    ((keeper :reap!) {:now (os/clock :realtime) :ttl 60 :token "w"})
    (assert (nil? ((keeper :fetch) (old :id)))
            "the reaper prunes finished records past their retention")

    (def keeps-everything (backend/normalize (jobsdb/store {:keep-for :none})))
    (def kept ((keeps-everything :push!) (record/make {:job :kept :queue :default})))
    (def kc ((keeps-everything :claim!) {:queues [:default] :now (os/clock :realtime) :token "w"}))
    ((keeps-everything :settle!) (record/complete! kc nil (- (os/clock :realtime) 10)))
    ((keeps-everything :reap!) {:now (os/clock :realtime) :ttl 60 :token "w"})
    (assert ((keeps-everything :fetch) (kept :id)) ":keep-for :none keeps everything")

    # -- the runtime on top of it ----------------------------------------

    ((b :clear!) {})
    (def q (state/make b {}))
    (with-dyns [state/queue-dyn q]
      (job/defjob db-adder [a c] (+ a c))
      (job/defjob db-dies {:max-attempts 1} [] (error "nope"))
      (def r (state/enqueue :db-adder 2 3))
      (assert (= 1 (worker/drain!)) "the runtime runs jobs out of the database")
      (assert (= 5 ((state/fetch (r :id)) :result)))
      (state/enqueue :db-dies)
      (worker/drain!)
      (assert (= 1 (get-in (state/counts) [:default :dead]))
              "and puts what dies in the dead letter queue")

      (def root (jobs/flow {:job :db-adder :args [1 1]
                            :children [{:job :db-adder :args [2 2]}]}))
      (worker/drain!)
      (assert (= :completed ((state/fetch (root :id)) :state))
              "flows work across the database too")
      (assert (= 1 (length ((state/fetch (root :id)) :children)))
              "with the child's result on the parent"))

    # -- the plugin ------------------------------------------------------

    (def report
      (plugin/dry-run {:plugins ["void/db/init" "void/db-sqlite/init" "void/jobs/init"
                                 "void/jobs/db"]
                       :profile :test
                       :config {:env @{}
                                :cli {:log {:level :error}
                                      :void/jobs-backend {:impl :jobs/db}
                                      :db-sqlite {:path (string sandbox "/plugin.sqlite3")}}}}))
    (assert (report :ok) "void/jobs-db composes with void/jobs and a driver")
    (assert (index-of :jobs/db (report :components)) "and puts its backend in the graph")

    (def [amb _]
      (protect (plugin/dry-run {:plugins ["void/db/init" "void/db-sqlite/init"
                                          "void/jobs/init" "void/jobs/db"]
                                :profile :test
                                :config {:env @{} :cli {:log {:level :error}}}})))
    (assert (not amb)
            "two backends on the interface is the ambiguity the kernel refuses to resolve")))

(print "db-test ok")
