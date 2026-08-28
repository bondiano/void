(import ../test-support/paths)
(import void/core/log :as log)
(import void/jobs/backend :as backend)
(import void/jobs/flow :as flow)
(import void/jobs/job :as job)
(import void/jobs/memory :as memory)
(import void/jobs/state :as state)
(import void/jobs/worker :as worker)

(each ns ["void.jobs" "void.jobs.worker" "void.jobs.flow"] (log/set-level! ns :fatal))

(defn- queue [&opt cfg]
  (state/make (memory/store (memory/make)) (or cfg {})))

(defmacro- with-queue [q & body]
  ~(with-dyns [state/queue-dyn ,q] ,;body))

(job/defjob fetch-part [n] (string "part-" n))
(job/defjob publish [] (map |($ :result) (state/children)))
(job/defjob breaks {:max-attempts 1} [] (error "child trouble"))

# -- the shape -----------------------------------------------------------

(def q (queue))
(with-queue q
  (def root (flow/flow {:job :publish
                        :children [{:job :fetch-part :args [1]}
                                   {:job :fetch-part :args [2]}]}))
  (assert (= :waiting (root :state)) "a parent waits for its children")
  (assert (= 2 (root :children-left)) "and knows how many")
  (assert (= 2 (length (flow/pending-children (root :id))))
          "which are findable by their parent")

  (assert (= 3 (worker/drain!)) "the children run, then the parent")
  (def done (state/fetch (root :id)))
  (assert (= :completed (done :state)) "and the parent finishes")
  (assert (deep= ["part-1" "part-2"] (tuple ;(done :result)))
          "having read what its children returned"))

# -- nesting -------------------------------------------------------------

(def nq (queue))
(with-queue nq
  (def root (flow/flow {:job :publish
                        :children [{:job :publish
                                    :children [{:job :fetch-part :args [:deep]}]}]}))
  (assert (= 3 (worker/drain!)) "a flow three deep runs bottom up")
  (def done (state/fetch (root :id)))
  (assert (= :completed (done :state)))
  (assert (= 1 (length (done :result))) "and each level sees only its own children"))

# -- a dead child kills the flow -----------------------------------------

(def kq (queue))
(with-queue kq
  (def root (flow/flow {:job :publish
                        :children [{:job :breaks} {:job :fetch-part :args [1]}]}))
  (worker/drain!)
  (def parent (state/fetch (root :id)))
  (assert (= :dead (parent :state))
          "a child that dies kills its parent — a flow that waits for ever is worse")
  (assert (string/find "died" (parent :error)) "and the parent says which child"))

(def kq2 (queue))
(with-queue kq2
  (def root (flow/flow {:job :publish
                        :children [{:job :publish :children [{:job :breaks}]}]}))
  (worker/drain!)
  (assert (= :dead ((state/fetch (root :id)) :state))
          "and it kills the whole tree, not merely the level above"))

# -- per-node options ----------------------------------------------------

(def oq (queue))
(with-queue oq
  (def root (flow/flow {:job :publish :queue :reports :priority 1
                        :children [{:job :fetch-part :args [1] :queue :io}]}))
  (assert (= :reports (root :queue)) "a node takes the enqueue options")
  (def [child] (state/list-jobs {:parent (root :id)}))
  (assert (= :io (child :queue)) "and so does a child"))

# -- what a flow refuses -------------------------------------------------

(def bq (queue))
(with-queue bq
  (each [spec reason]
    [[{:children []} "a node with no job"]
     [{:job :publish :children {}} "children that are not a list"]
     [{:job :publish :nonsense 1} "a key that does not exist"]]
    (def [ok _] (protect (flow/flow spec)))
    (assert (not ok) (string reason " is refused"))))

# a backend that cannot hold a parent says so instead of losing it
(def crippled
  (backend/normalize
    (let [t (table ;(kvs (memory/store (memory/make))))]
      (put t :release-parent! nil)
      t)))
(def cq (state/make crippled {}))
(with-queue cq
  (def [ok err] (protect (flow/flow {:job :publish :children [{:job :fetch-part :args [1]}]})))
  (assert (not ok) "a backend without flows refuses them at enqueue")
  (assert (string/find "release-parent" err) "naming what it is missing")
  (assert (empty? (state/list-jobs {})) "and nothing was queued"))

(print "flow-test ok")
