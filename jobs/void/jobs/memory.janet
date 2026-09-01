### void/jobs/memory — the in-process backend (SPEC.md §5.12).
###
### The backend an application starts with: a table of records in this
### process's heap, which is a real queue with real retries, real
### delays and real flows, and which loses everything when the process
### exits. That is not a defect to apologise for — it is the right
### store for a test suite, for `void dev`, and for the enormous number
### of applications whose "background job" means "answer the request
### first, send the mail after". Swapping it for one that survives a
### restart is a config line once void/jobs-db or void/jobs-redis is in
### the composition.
###
### Two properties it has that the shared backends buy with a round
### trip. Claiming is atomic for free: the ev loop is one thread, and
### `claim!` does not yield, so no second fiber can be inside it. And
### ordering is exact rather than indexed — the claim scans every live
### record and takes the best one, which is O(n) per claim and
### completely fine at the scale a heap-sized queue reaches. At the
### scale where it is not, the answer is not a better index here; it is
### a backend several processes can share.

(import ./backend :as backend)
(import ./record :as record)

(def defaults
  ``Defaults of the [:jobs-memory] slice. The two retention numbers
  are the ones worth knowing: finished records are kept so that
  `void jobs show` can answer "did it run?", and they are trimmed so
  that a process running a job a second does not turn its queue into
  a memory leak with a good reputation.``
  {:max-completed 200
   :max-dead 1000})

(defn make
  "The table behind an in-process backend."
  [&opt opts]
  (def cfg (merge defaults (or opts {})))
  @{:jobs @{}
    :unique @{}
    :finished @{:completed @[] :dead @[]}
    :max-completed (cfg :max-completed)
    :max-dead (cfg :max-dead)
    :stats @{:pushed 0 :claimed 0 :completed 0 :failed 0 :dead 0
             :duplicates 0 :reaped 0}})

# -- unique keys ---------------------------------------------------------

(defn- unique-held? [m k now]
  (when-let [e (get-in m [:unique k])]
    (def owner (get-in m [:jobs (e :id)]))
    (cond
      # a ttl outlives the job it was taken for: that is what it is for
      (and (e :until) (> (e :until) now)) true
      (and owner (record/live? owner)) true
      (do (put (m :unique) k nil) false))))

(defn- release-unique! [m r now]
  (when-let [k (get r :unique-key)]
    (def e (get-in m [:unique k]))
    (when (and e (= (e :id) (r :id))
               (not (and (e :until) (> (e :until) now))))
      (put (m :unique) k nil))))

# -- retention -----------------------------------------------------------

(defn- remember-finished! [m r]
  (def state (r :state))
  (def ring (get-in m [:finished state]))
  (when ring
    (array/push ring (r :id))
    (def cap (if (= :completed state) (m :max-completed) (m :max-dead)))
    (while (> (length ring) cap)
      # array/remove answers with the array, not with what it removed
      (def old (get ring 0))
      (array/remove ring 0)
      # only if it is still the finished record we put there: an id
      # revived by `void jobs retry` is live again and not ours to drop
      (when-let [victim (get-in m [:jobs old])]
        (when (= state (victim :state))
          (put (m :jobs) old nil))))))

(defn- forget-finished! [m id]
  (each state [:completed :dead]
    (def ring (get-in m [:finished state]))
    (when-let [i (index-of id ring)]
      (array/remove ring i))))

# -- ordering ------------------------------------------------------------

(defn claim-order
  ``The sort key of a claimable record: the position of its queue in
  the worker's preference list first — a worker asked to serve
  [:critical :default] drains :critical first, whatever :default's
  priorities say — then :priority (lower first), then :run-at, then
  the id, which sorts by creation time and so breaks the last tie in
  favour of whoever has been waiting longest.``
  [r queues]
  [(or (index-of (r :queue) queues) (length queues))
   (get r :priority 5)
   (get r :run-at 0)
   (get r :id "")])

(defn- better? [a b]
  (< (compare a b) 0))

# -- the backend ---------------------------------------------------------

(defn store
  ``A `:void/jobs-backend` over the table from `make`. Nothing is
  captured but that table, so a REPL holding onto the backend keeps
  seeing the same queue after a component restart handed it out
  again.``
  [m]
  {:name :memory
   :shared? false

   :push!
   (fn mem-push [r]
     (def now (get r :enqueued-at (os/clock :realtime)))
     (def k (get r :unique-key))
     (if (and k (unique-held? m k now))
       (do (update (m :stats) :duplicates inc) nil)
       (do
         (when k (put (m :unique) k {:id (r :id) :until (get r :unique-until)}))
         (put (m :jobs) (r :id) (record/copy r))
         (update (m :stats) :pushed inc)
         (record/copy r))))

   # not a single yield in here: on the ev loop that is what makes it
   # atomic, and the reason this backend needs no lock of any kind
   :claim!
   (fn mem-claim [opts]
     (def now (get opts :now (os/clock :realtime)))
     (def queues (get opts :queues []))
     (def skip (get opts :skip-groups {}))
     (var best nil)
     (var best-key nil)
     (each id (keys (m :jobs))
       (def r (get-in m [:jobs id]))
       (when (and r
                  (record/runnable? r now)
                  (index-of (r :queue) queues)
                  (not (and (r :group) (in skip (r :group)))))
         (def k (claim-order r queues))
         (when (or (nil? best) (better? k best-key))
           (set best r)
           (set best-key k))))
     (when best
       (record/start! best (get opts :token) now)
       (update (m :stats) :claimed inc)
       (record/copy best)))

   :settle!
   (fn mem-settle [r]
     (def now (get r :finished-at (os/clock :realtime)))
     (def stored (record/copy r))
     (put (m :jobs) (r :id) stored)
     (case (r :state)
       :completed (do (update (m :stats) :completed inc)
                      (release-unique! m r now)
                      (remember-finished! m stored))
       :dead (do (update (m :stats) :dead inc)
                 (release-unique! m r now)
                 (remember-finished! m stored))
       :pending (update (m :stats) :failed inc)
       nil)
     (record/copy r))

   :fetch (fn mem-fetch [id] (record/copy (get-in m [:jobs id])))

   :list
   (fn mem-list [opts]
     (def o (or opts {}))
     (def limit (get o :limit 50))
     (def out
       (seq [id :in (sorted (keys (m :jobs)))
             :let [r (get-in m [:jobs id])]
             :when (and r
                        (or (nil? (o :queue)) (= (o :queue) (r :queue)))
                        (or (nil? (o :state)) (= (o :state) (r :state)))
                        (or (nil? (o :job)) (= (o :job) (r :job)))
                        (or (nil? (o :parent)) (= (o :parent) (r :parent))))]
         (record/copy r)))
     (tuple ;(if (> (length out) limit) (array/slice out 0 limit) out)))

   :counts
   (fn mem-counts [&opt _]
     (def out @{})
     (each id (keys (m :jobs))
       (def r (get-in m [:jobs id]))
       (when r
         (def q (or (get out (r :queue)) (let [t @{}] (put out (r :queue) t) t)))
         (put q (r :state) (inc (get q (r :state) 0)))))
     (table/to-struct
       (tabseq [q :keys out] q (table/to-struct (get out q)))))

   :remove!
   (fn mem-remove [id]
     (if-let [r (get-in m [:jobs id])]
       (do
         (release-unique! m r (+ 1 (get r :unique-until 0)))
         (forget-finished! m id)
         (put (m :jobs) id nil)
         true)
       false))

   :clear!
   (fn mem-clear [opts]
     (def o (or opts {}))
     (var n 0)
     (each id (keys (m :jobs))
       (def r (get-in m [:jobs id]))
       (when (and r
                  (or (nil? (o :queue)) (= (o :queue) (r :queue)))
                  (or (nil? (o :state)) (= (o :state) (r :state))))
         (release-unique! m r (+ 1 (get r :unique-until 0)))
         (forget-finished! m id)
         (put (m :jobs) id nil)
         (++ n)))
     n)

   :reap!
   (fn mem-reap [opts]
     (def now (get opts :now (os/clock :realtime)))
     (def ttl (get opts :ttl 60))
     (def token (get opts :token))
     (def out @[])
     (each id (sorted (keys (m :jobs)))
       (def r (get-in m [:jobs id]))
       (when (and r (record/stalled? r now ttl))
         # taken over, not released: the record stays :running under a
         # new token, so a second worker reaping at the same moment
         # cannot pick it up as well
         (put r :token token)
         (put r :claimed-at now)
         (update (m :stats) :reaped inc)
         (array/push out (record/copy r))))
     (tuple ;out))

   :touch!
   (fn mem-touch [ids now]
     (var n 0)
     (each id ids
       (when-let [r (get-in m [:jobs id])]
         (when (= :running (r :state))
           (put r :claimed-at now)
           (++ n))))
     n)

   :release-parent!
   (fn mem-release-parent [child]
     (when-let [pid (get child :parent)
                parent (get-in m [:jobs pid])]
       (array/push (or (get parent :children) (put parent :children @[]))
                   {:id (child :id) :job (child :job) :result (get child :result)})
       (def left (max 0 (dec (get parent :children-left 0))))
       (put parent :children-left left)
       (when (and (zero? left) (= :waiting (parent :state)))
         (put parent :state :pending)
         (put parent :run-at (os/clock :realtime))
         (record/copy parent))))

   :stats
   (fn mem-stats []
     (merge {:store :memory
             :jobs (length (m :jobs))
             :unique-keys (length (m :unique))}
            (table/to-struct (m :stats))))

   :close (fn mem-close [] nil)})

(defn backend-of
  "A normalized backend over a fresh table — the one-liner tests and
  fixtures reach for."
  [&opt opts]
  (backend/normalize (store (make opts))))
