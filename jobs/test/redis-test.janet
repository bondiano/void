(import ../test-support/paths)
(import ../test-support/conformance :as conformance)
(import void/core/log :as log)
(import void/core/plugin :as plugin)
(import void/redis/codec :as codec)
(import void/redis/commands :as rcmd)
(import void/redis/config :as rconfig)
(import void/redis/pool :as rpool)
(import void/redis/state :as redis)
(import void/jobs :as jobs)
(import void/jobs/backend :as backend)
(import void/jobs/job :as job)
(import void/jobs/record :as record)
(import void/jobs/redis :as jobsredis)
(import void/jobs/state :as state)
(import void/jobs/worker :as worker)

(each ns ["void.redis" "void.redis.command" "void.jobs" "void.jobs.redis"
          "void.jobs.worker"]
  (log/set-level! ns :fatal))

# What can be tested without a server is: the record-to-hash mapping,
# the config slice and the plugin's declarations. Everything else is a
# client of a real redis or it is nothing, so it runs against the
# server VOID_TEST_REDIS names and announces itself skipped when there
# is none — a missing server is not a broken backend.

(def env-var "VOID_TEST_REDIS")

# -- records as hashes ---------------------------------------------------

(def r (record/make {:job :mapped :args [1 "two" :three {:m [1 2]}]
                     :queue :mail :priority 2 :group "acme" :timeout 30}))
(def flat (jobsredis/record->hash r))
(assert (even? (length flat)) "the hash is field/value pairs")
(assert (index-of "group_key" flat) "spelled like void/jobs-db's columns")
(assert (not (index-of "result" flat))
        "and a field a record does not have is absent, not empty")

(def h (tabseq [i :range [0 (length flat) 2]] (get flat i) (get flat (inc i))))
(def back (jobsredis/hash->record h))
(each k [:job :queue :priority :group :timeout :state]
  (assert (= (get r k) (get back k))
          (string/format "%q survives the hash" k)))
(assert (deep= (r :args) (tuple ;(back :args))) "and so do the arguments")
(assert (nil? (jobsredis/hash->record {})) "an empty reply is no record at all")

# -- the plugin's declarations -------------------------------------------

(def report
  (plugin/dry-run {:plugins ["void/redis/init" "void/jobs/init" "void/jobs/redis"]
                   :profile :test
                   :config {:env @{}
                            :cli {:log {:level :error}
                                  :void/jobs-backend {:impl :jobs/redis}}}}))
(assert (report :ok) "void/jobs-redis composes with void/jobs and void/redis")
(assert (index-of :jobs/redis (report :components)) "and puts its backend in the graph")

(def [amb _]
  (protect (plugin/dry-run {:plugins ["void/redis/init" "void/jobs/init" "void/jobs/redis"]
                            :profile :test
                            :config {:env @{} :cli {:log {:level :error}}}})))
(assert (not amb)
        "two backends on the interface is the ambiguity the kernel refuses to resolve")

(each [slice reason]
  [[{:jobs-redis {:keep-completed -1}} "a negative retention"]
   [{:jobs-redis {:promote-batch 0}} "a promotion that promotes nothing"]
   [{:jobs-redis {:prefix :not-a-string}} "a prefix that is not a string"]]
  (def [ok _] (protect (plugin/dry-run
                         {:plugins ["void/redis/init" "void/jobs/init" "void/jobs/redis"]
                          :profile :test
                          :config {:env @{}
                                   :cli (merge {:log {:level :error}
                                                :void/jobs-backend {:impl :jobs/redis}}
                                               slice)}})))
  (assert (not ok) (string reason " fails the boot")))

# -- against a real server -----------------------------------------------

(def url (when-let [v (os/getenv env-var)]
           (unless (empty? (string/trim v)) (string/trim v))))

(if (nil? url)
  (printf "redis-test: SKIPPED (set %s to a redis:// url)" env-var)
  (do
    (def cfg {:url url :prefix (string "void-test:jobs:" (os/getpid) ":")})
    (def client
      @{:pool (rpool/make (rconfig/options cfg) (rconfig/pool-options cfg))
        :codec codec/raw
        :prefix (cfg :prefix)
        :retry true
        :conn-opts (rconfig/options cfg)})
    (defer (rpool/close-all! (client :pool))
      (with-dyns [redis/client-dyn client]
        # this suite works under a prefix of its own and takes its keys
        # away afterwards: the database named may be somebody's
        (defer (let [doomed @[]]
                 (rcmd/scan-each |(array/push doomed $) {:match "*"})
                 (unless (empty? doomed) (rcmd/del-keys ;doomed)))

          # -- the contract ------------------------------------------------

          (conformance/run! "redis" (jobsredis/store {}))

          # -- retention ---------------------------------------------------

          (def trimmed (backend/normalize (jobsredis/store {:keep-completed 2})))
          ((trimmed :clear!) {})
          (each i (range 4)
            (def pushed ((trimmed :push!) (record/make {:job :trim :queue :default})))
            (def c ((trimmed :claim!) {:queues [:default] :now (os/clock :realtime)
                                       :token "w"}))
            ((trimmed :settle!) (record/complete! c :ok (os/clock :realtime))))
          (assert (= 2 (get-in ((trimmed :counts)) [:default :completed]))
                  "finished records are trimmed to the retention cap")

          # -- the runtime on top of it ------------------------------------

          (def b (backend/normalize (jobsredis/store {})))
          ((b :clear!) {})
          (def q (state/make b {}))
          (with-dyns [state/queue-dyn q]
            (job/defjob redis-adder [a c] (+ a c))
            (job/defjob redis-dies {:max-attempts 1} [] (error "nope"))
            (def r2 (state/enqueue :redis-adder 2 3))
            (assert (= 1 (worker/drain!)) "the runtime runs jobs out of redis")
            (assert (= 5 ((state/fetch (r2 :id)) :result)))
            (state/enqueue :redis-dies)
            (worker/drain!)
            (assert (= 1 (get-in (state/counts) [:default :dead]))
                    "and puts what dies in the dead letter queue")

            (def root (jobs/flow {:job :redis-adder :args [1 1]
                                  :children [{:job :redis-adder :args [2 2]}]}))
            (worker/drain!)
            (assert (= :completed ((state/fetch (root :id)) :state))
                    "flows work in redis too")
            (assert (= 1 (length ((state/fetch (root :id)) :children)))
                    "with the child's result on the parent"))

          # -- the scripts are shared, and that is the point ---------------

          (def t (os/clock :realtime))
          (assert ((b :lock!) "shared" 30 "a" t) "a lease is taken in redis")
          (assert (not ((b :lock!) "shared" 30 "b" t))
                  "which is what makes a schedule fire once across a fleet")
          ((b :unlock!) "shared" "a")
          (assert (get (backend/capabilities b) :shared)
                  "and the backend says it is shared, so nothing warns about a fleet")
          (assert (= :shared (get (backend/capabilities b) :locks)))
          (assert (= :shared (get (backend/capabilities b) :rate-limit))))))))

(print "redis-test ok")
