### void/jobs/flow — parent-child job graphs (SPEC.md §5.12,
### ROADMAP 2.4).
###
### A flow is one job that must not start until several others have
### finished, with what they returned available to it:
###
###     (jobs/flow {:job :publish-report :args ["2026-08"]
###                 :children [{:job :fetch-sales :args ["2026-08"]}
###                            {:job :fetch-costs :args ["2026-08"]}]})
###
### The parent is enqueued first, in the :waiting state with a count of
### how many children it is waiting for; the children are enqueued
### pointing back at it. Each child that completes decrements the count
### through the backend's `release-parent!` — atomically, because two
### workers finishing the last two children in the same instant must
### not both decide they were last — and the child that takes the count
### to zero moves the parent to :pending, where an ordinary worker
### picks it up like anything else.
###
### The parent reads what its children returned through `children`:
###
###     (jobs/defjob publish-report [month]
###       (def parts (map |($ :result) (jobs/children)))
###       ...)
###
### Two decisions worth stating.
###
### **A dead child kills the flow.** The alternative is a parent that
### waits for a child that will never finish — a queue that has
### silently stopped, which is the failure mode nobody notices until
### the report does not arrive. The parent is moved to :dead naming the
### child, and so is its parent, up the tree (./worker).
###
### **Children are jobs, not closures.** They are queued records with
### their own retries, priorities and queues, and a child may have
### children of its own: nesting is real, and a grandchild finishing
### releases only its own parent. What a flow does *not* do is pass
### values *down* — a child that needs the parent's arguments is given
### them as its own, at enqueue time, where they can be seen.

(import void/core/log :as log)
(import ./backend :as backend)
(import ./record :as record)
(import ./state :as state)

(def log-ns "void.jobs.flow")

(def- allowed-keys
  {:job true :args true :children true :queue true :priority true
   :max-attempts true :backoff true :timeout true :unique true
   :unique-ttl true :group true :delay true :at true})

(defn- check-spec [spec]
  (unless (dictionary? spec)
    (errorf "a flow node must be a dictionary {:job :args :children}, got %q" spec))
  (unless (keyword? (get spec :job))
    (errorf "a flow node needs a :job name, got %q" (get spec :job)))
  (eachk k spec
    (unless (in allowed-keys k)
      (errorf "flow node %q: unknown key %q (allowed: %s)"
              (spec :job) k
              (string/join (map |(string/format "%q" $) (sorted (keys allowed-keys))) " "))))
  (def cs (get spec :children []))
  (unless (indexed? cs)
    (errorf "flow node %q: :children must be a tuple of nodes, got %q" (spec :job) cs))
  cs)

(defn- enqueue-opts [spec extra]
  (def out (table ;(kvs extra)))
  (each k [:queue :priority :max-attempts :backoff :timeout
           :unique :unique-ttl :group :delay :at]
    (when (in spec k) (put out k (get spec k))))
  (table/to-struct out))

(defn- enqueue-node [spec parent-id]
  (def children (check-spec spec))
  (def n (length children))
  (def parent
    (state/enqueue-with
      (enqueue-opts spec (merge @{} (if parent-id {:parent parent-id} {})
                                (if (pos? n) {:children-left n} {})))
      (spec :job)
      ;(get spec :args [])))
  (each c children (enqueue-node c (parent :id)))
  parent)

(defn flow
  ``Enqueue a job graph and return the root record. Every node takes
  the keys `enqueue-with` takes, plus :children — nodes of the same
  shape, nested as deeply as the work is.

  The backend has to be able to hold a parent (`release-parent!`); the
  in-process, db and redis backends all can, and one that cannot is
  refused here rather than losing the parent.``
  [spec]
  (def b (state/active-backend))
  (backend/require-flows! b)
  (check-spec spec)
  (def root (enqueue-node spec nil))
  (log/debug "flow enqueued" :ns log-ns
             :job (root :job) :id (root :id)
             :children (get root :children-left 0))
  root)

# -- what a parent sees --------------------------------------------------

(def current-job-dyn "See state/current-job-dyn." state/current-job-dyn)
(def current-job "See state/current-job — the record this handler runs under." state/current-job)
(def children "See state/children — what this job's children returned." state/children)

(defn pending-children
  "The records of `id`'s children that have not finished yet — the
  reader behind `void jobs show` on a waiting parent."
  [id]
  (tuple ;(filter record/live?
                  (((state/active-backend) :list) {:parent id :limit 1000}))))
