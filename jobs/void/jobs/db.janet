### void/jobs-db — the job queue in the database.
###
### The piece of void/jobs that needs void/db, kept a separate plugin
### so an application whose jobs live in its heap never loads a
### database driver — exactly what void/cache-redis is to void/cache.
### Add it to the composition and say which backend you mean:
###
###     (void/run! {:plugins [:void/db :void/db-postgres
###                           :void/jobs :void/jobs-db ...]})
###     # config/prod.janet
###     {:void/jobs-backend {:impl :jobs/db}}
###
### It is the backend to reach for when the jobs matter more than the
### throughput: they are rows in the same database as the data they act
### on, they are backed up with it, they survive everything it
### survives, and `SELECT * FROM void_jobs WHERE state = 'dead'` is
### available to anyone who can read the database, at three in the
### morning, without a client library.
###
### Four decisions worth stating.
###
### **Claiming is `FOR UPDATE SKIP LOCKED` where there is one.** On
### Postgres the claim is a single statement: the inner SELECT locks
### the one row it picks and skips rows other workers have locked, so N
### workers claim N different jobs without ever waiting for each other.
### On an engine without it — sqlite — the claim is a SELECT and an
### UPDATE inside a transaction, which on sqlite is exactly right
### because its writer is serialized anyway (the driver opens `BEGIN
### IMMEDIATE`; see void/db-sqlite). What is *not* done is a portable
### "SELECT then UPDATE and hope": the UPDATE carries `AND state =
### 'pending'` and the claim counts as failed when it changes no row,
### so a lost race is a lost race and never a job run twice.
###
### **Queues are claimed in preference order, one statement each.** A
### worker serving [:critical :default] asks :critical first and only
### asks :default when :critical had nothing. It is one extra round
### trip on an empty queue and none on a busy one, and it buys exact
### preference semantics without a CASE expression that every dialect
### spells differently.
###
### **A released unique key is a NULL, not a deleted row.** The
### uniqueness index is partial (`WHERE unique_key IS NOT NULL`), the
### key is cleared when the job finishes, and `push!` is a check inside
### a transaction *and* an index that catches the race the check cannot.
### Two processes enqueueing the same unique job in the same instant
### get one job, on both engines.
###
### **The reaper prunes.** Finished rows are kept for
### `[:jobs-db :keep-for]` seconds and then deleted — by the same
### periodic pass that returns abandoned claims, because that pass is
### the only heartbeat the runtime has and a second timer for one
### DELETE would be a second thing to explain.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/log :as log)
(import void/core/errors :as errors)
(import void/db :as db)
(import void/db/builder :as builder)
(import void/db/lease :as lease)
(import ./backend :as backend)
(import ./record :as record)

(def log-ns "void.jobs.db")

(def Config
  "Schema of the [:jobs-db] config slice."
  {:table [:optional :string]
   :auto-create [:optional :boolean]
   # how long a finished record is kept before the reaper deletes it.
   # :none keeps everything, which is a choice a queue with an audit
   # requirement makes deliberately
   :keep-for [:optional [:or [:number {:min 0}] [:enum :none]]]
   :prune-batch [:optional [:int {:min 1}]]})

(def defaults
  "Defaults of the [:jobs-db] slice."
  {:table "void_jobs"
   :auto-create true
   :keep-for (* 7 24 3600)
   :prune-batch 1000})

(def lock-keep
  ``How long an expired lease row in `<table>_locks` outlives its
  `until` before the reaper deletes it. A schedule lease is taken and
  never unlocked — a slot that fired must stay fired — so expiry plus
  this grace is the only thing between the table and unbounded growth
  ({:every 30} is 2880 rows a day otherwise).``
  86400)

# -- the schema ----------------------------------------------------------

(def columns
  ``The column of every record field, in creation order, as builder
  columns — a type name void/db/builder spells per dialect, so the one
  declaration is the table on every engine. Kept explicit rather than
  derived: the table is read by people and by other services, and a
  column that quietly renames itself when a field does is a migration
  nobody wrote.

  `:string` where a column is a key or indexed, `:text` where it is a
  document: the two are the same `text` on sqlite and Postgres, and
  on MySQL only the first is indexable without a prefix length.``
  [[:id :string {:primary-key true}]
   [:job :string {:null false}]
   [:args :text {:null false}]
   [:queue :string {:null false}]
   [:priority :integer {:null false}]
   [:state :string {:null false}]
   [:attempt :integer {:null false}]
   [:max-attempts :integer {:null false}]
   [:backoff :text]
   [:timeout :double]
   [:run-at :double {:null false}]
   [:enqueued-at :double {:null false}]
   [:started-at :double]
   [:claimed-at :double]
   [:finished-at :double]
   [:unique-key :string]
   [:unique-until :double]
   [:group-key :string]
   [:parent :string]
   [:children-left :integer]
   [:children :text]
   [:result :text]
   [:error :text]
   [:failures :text]
   [:token :string]])

(def- col-keys
  "The record columns, as the keywords a statement names them by."
  (tuple ;(map |($ 0) columns)))

(defn- unique-index
  ``The index that makes unique jobs exact. Partial — `WHERE unique_key
  IS NOT NULL` — so it is the size of the keys in play, not of the
  history. An engine without partial indexes gets the plain unique
  index, which is the same promise: a NULL is distinct from every
  other NULL in a unique index on every one of the three engines, and
  that is exactly what a released key relies on. The branch is on the
  capability, because it is the capability that decides which index
  this is.``
  [dialect table]
  (def name (string table "_unique_idx"))
  (def idx {:create-index name :on table :if-not-exists true
            :columns [:unique-key] :unique true})
  (if (db/capability dialect :partial-indexes)
    (merge idx {:where [:<> :unique-key nil]})
    idx))

(defn- statements
  "The schema as builder statements, in creation order."
  [dialect table]
  [{:create-table table :if-not-exists true :columns columns}
   {:create-index (string table "_claim_idx") :on table :if-not-exists true
    :columns [:state :queue :priority :run-at]}
   (unique-index dialect table)
   {:create-index (string table "_parent_idx") :on table :if-not-exists true
    :columns [:parent]}
   (lease/statement (string table "_locks"))
   {:create-table (string table "_rates") :if-not-exists true
    :columns [[:queue :string {:null false}]
              [:window-start :double {:null false}]
              [:n :integer {:null false}]]
    :primary-key [:queue :window-start]}])

(defn ddl
  ``Every statement that creates the tables this backend needs, as a
  tuple of SQL strings spelled for `dialect` — what `[:jobs-db
  :auto-create]` runs at boot and what `void jobs-db ddl` prints for a
  deployment that would rather run its own migration. The dialect is
  an argument because the same declaration is a different string on
  each engine, and a migration file asks for the one it runs against
  (`((db/current-driver) :dialect)`).``
  [dialect &opt table]
  (default table (defaults :table))
  (tuple ;(map |(first (builder/format $ dialect)) (statements dialect table))))

(defn create-tables!
  "Run `ddl` — idempotent, and safe to run at every boot."
  [&opt table]
  (db/ddl! (ddl ((db/current-driver) :dialect) table)))

# -- rows <-> records ----------------------------------------------------

(defn record->row
  "A record as the columns that store it — the two structured fields
  as jdn, everything else as itself."
  [r]
  @{:id (r :id)
    :job (string (r :job))
    :args (record/encode-value (get r :args []) "the arguments")
    :queue (string (r :queue))
    :priority (get r :priority 5)
    :state (string (get r :state :pending))
    :attempt (get r :attempt 0)
    :max-attempts (get r :max-attempts 3)
    :backoff (when-let [b (get r :backoff)] (record/encode-value b "the backoff"))
    :timeout (get r :timeout)
    :run-at (get r :run-at 0)
    :enqueued-at (get r :enqueued-at 0)
    :started-at (get r :started-at)
    :claimed-at (get r :claimed-at)
    :finished-at (get r :finished-at)
    :unique-key (get r :unique-key)
    :unique-until (get r :unique-until)
    :group-key (get r :group)
    :parent (get r :parent)
    :children-left (get r :children-left)
    :children (when-let [cs (get r :children)] (record/encode-value cs "the children"))
    :result (unless (nil? (get r :result))
              (record/encode-value (get r :result) "the result"))
    :error (get r :error)
    :failures (record/encode-value (get r :failures []) "the failures")
    :token (get r :token)})

(defn- kw [v] (when v (keyword v)))

(defn row->record
  "A row back into a record."
  [row]
  (when row
    @{:id (get row :id)
      :job (kw (get row :job))
      :args (tuple ;(or (record/decode-value (get row :args)) []))
      :queue (kw (get row :queue))
      :priority (get row :priority 5)
      :state (kw (get row :state))
      :attempt (get row :attempt 0)
      :max-attempts (get row :max_attempts 3)
      :backoff (record/decode-value (get row :backoff))
      :timeout (get row :timeout)
      :run-at (get row :run_at 0)
      :enqueued-at (get row :enqueued_at 0)
      :started-at (get row :started_at)
      :claimed-at (get row :claimed_at)
      :finished-at (get row :finished_at)
      :unique-key (get row :unique_key)
      :unique-until (get row :unique_until)
      :group (get row :group_key)
      :parent (get row :parent)
      :children-left (get row :children_left)
      :children (when-let [cs (record/decode-value (get row :children))] (array ;cs))
      :result (record/decode-value (get row :result))
      :error (get row :error)
      :failures (array ;(or (record/decode-value (get row :failures)) []))
      :token (get row :token)}))

# -- the backend ---------------------------------------------------------

(def- live-states
  "The states that still hold a unique key."
  ["pending" "running" "waiting"])

(defn- select-one [table where]
  (row->record (db/one-row {:select col-keys :from table :where where})))

(defn- skip-locked?
  ``Can this engine claim with one statement — `FOR UPDATE SKIP
  LOCKED` inside the id subquery? Where it can, the claim is that
  statement; where it cannot, it is a SELECT and an UPDATE inside a
  transaction. Asked of the dialect rather than of the engine's name:
  it is the capability the two claims differ by.``
  []
  (db/capability ((db/current-driver) :dialect) :skip-locked))

(defn store
  ``A `:void/jobs-backend` over the running void/db pool. Nothing is
  captured but the table name and the retention policy: which
  database, which driver and which dialect are read off the pool at
  call time, so the backend outlives a restart of the pool under it.``
  [opts]
  # `tbl`, not `table`: the name would shadow the constructor this
  # module builds statement maps with, and a string in function
  # position is a confusing way to find that out
  (def tbl (get opts :table (defaults :table)))
  (def locks (string tbl "_locks"))
  (def rates (string tbl "_rates"))
  (def keep-for (get opts :keep-for (defaults :keep-for)))
  (def prune-batch (get opts :prune-batch (defaults :prune-batch)))

  (defn insert-row! [row]
    (db/execute! {:insert tbl :values row}))

  (defn unique-holder [k now]
    (when k
      (select-one tbl
                  [:and [:= :unique-key k]
                   [:or [:in :state live-states]
                    [:and [:<> :unique-until nil]
                     [:> :unique-until [:val now]]]]])))

  {:name :db
   :shared? true

   :push!
   (fn db-push [r]
     (def now (get r :enqueued-at (os/clock :realtime)))
     (def k (get r :unique-key))
     (db/with-tx*
       {}
       (fn push-tx []
         (if (and k (unique-holder k now))
           nil
           (do
             # under a unique key the INSERT gets its own savepoint (a
             # nested with-tx* is one): on Postgres a unique violation
             # aborts the whole transaction (SQLSTATE 25P02), and
             # without the savepoint the second unique-holder check
             # below could never run
             (def [ok e]
               (protect
                 (if k
                   (db/with-tx* {} (fn insert-sp [] (insert-row! (record->row r))))
                   (insert-row! (record->row r)))))
             (cond
               ok (record/copy r)
               # the partial unique index caught what the check could
               # not: another process inserted between the two. That is
               # not an error, it is the answer — and only that one
               # kind is; a lost connection under the same INSERT is
               # still an error
               (and k (errors/kind? e :void.db/unique-violation)) nil
               (error e)))))))

   :claim!
   (fn db-claim [o]
     (def now (get o :now (os/clock :realtime)))
     (def token (get o :token))
     (def skip (sorted (keys (get o :skip-groups {}))))
     # the claim, as one value both paths read: an attempt is `attempt
     # + 1` because the column's own value is on the right-hand side,
     # which is what a fragment with parameters is for
     (def taken {:state "running" :token token
                 :attempt [:sql "attempt + ?" [1]]
                 :started-at now :claimed-at now})
     (var out nil)
     (each qn (get o :queues [])
       (when (nil? out)
         (def where
           (db/all-of [:= :state "pending"]
                      [:= :queue (string qn)]
                      [:<= :run-at [:val now]]
                      (unless (empty? skip)
                        [:or [:= :group-key nil] [:not-in :group-key skip]])))
         (def candidate
           {:select [:id] :from tbl :where where
            :order-by [:priority :run-at :id] :limit 1})
         (if (skip-locked?)
           # one statement: the inner SELECT locks the row it picks and
           # steps over the rows other workers hold
           (set out
                (row->record
                  (first (db/query-sql
                           {:update tbl :set taken
                            :where [:= :id (merge candidate
                                                  {:lock {:mode :update
                                                          :skip-locked true}})]
                            :returning col-keys}))))
           # no SKIP LOCKED: select then update, inside a transaction,
           # with the state re-checked in the UPDATE so a lost race is
           # a lost race and not a second run
           (db/with-tx*
             {}
             (fn claim-tx []
               (when-let [cand (db/one-row candidate)
                          id (get cand :id)]
                 (when (pos? (db/execute! {:update tbl :set taken
                                           :where [:and [:= :id id]
                                                   [:= :state "pending"]]}))
                   (set out (select-one tbl {:id id})))))))))
     out)

   :settle!
   (fn db-settle [r &opt expected]
     (def now (get r :finished-at (os/clock :realtime)))
     (def row (record->row r))
     # a finished job releases its unique key unless a ttl says it is
     # still holding it — the NULL is what makes the partial index
     # exact rather than a graveyard
     (when (and (index-of (r :state) [:completed :dead])
                (or (nil? (get r :unique-until))
                    (<= (get r :unique-until) now)))
       # db/null, not nil: putting nil into a table *removes* the key,
       # and a column left out of the UPDATE is a key never released
       (put row :unique-key db/null))
     (def sets @{})
     (eachk k row
       (unless (= :id k)
         (def v (get row k))
         (put sets k (if (nil? v) db/null v))))
     # `expected` is the fence reap! relies on: a claim that was
     # re-tokened away must not be overwritten by its old holder — the
     # reaped job ran again, and that run's settle is the one that
     # counts. nil answers "the claim was lost", exactly like a claim
     # that changed no row answers "the race was lost"
     (def where @{:id (r :id)})
     (when expected (put where :token expected))
     (def n (db/execute! {:update tbl :set sets :where where}))
     (if (and expected (zero? n))
       nil
       (record/copy r)))

   :fetch (fn db-fetch [id] (select-one tbl {:id id}))

   :list
   (fn db-list [o0]
     (def o (or o0 {}))
     (def where
       (db/all-of ;(seq [k :in [:queue :state :job :parent]
                         :when (not (nil? (get o k)))]
                    [:= k (string (get o k))])))
     (tuple ;(map row->record
                  (db/query-sql
                    {:select col-keys :from tbl :where where
                     :order-by [[:enqueued-at :desc] [:id :desc]]
                     :limit (math/floor (get o :limit 50))}))))

   :counts
   (fn db-counts [&opt _]
     (def out @{})
     (each row (db/query-sql {:select [:queue :state [:raw "count(*) AS n"]]
                              :from tbl :group-by [:queue :state]})
       (def q (keyword (get row :queue)))
       (def t (or (get out q) (let [t @{}] (put out q t) t)))
       (put t (keyword (get row :state)) (get row :n 0)))
     (table/to-struct (tabseq [q :keys out] q (table/to-struct (get out q)))))

   :remove!
   (fn db-remove [id]
     (pos? (db/execute! {:delete tbl :where {:id id}})))

   :clear!
   (fn db-clear [o0]
     (def o (or o0 {}))
     (def where @{})
     (when-let [q (get o :queue)] (put where :queue (string q)))
     (when-let [s (get o :state)] (put where :state (string s)))
     (db/execute! (merge {:delete tbl} (if (empty? where) {} {:where where}))))

   :reap!
   (fn db-reap [o]
     (def now (get o :now (os/clock :realtime)))
     (def ttl (get o :ttl 60))
     (def token (get o :token))
     (def cutoff (- now ttl))
     # the prune rides on the reaper: it is the periodic pass the
     # runtime already has, and a queue that never deletes a completed
     # row is a tbl that only grows
     (when (number? keep-for)
       (def horizon (- now keep-for))
       # a batch is picked and then deleted by id — two statements
       # rather than `DELETE ... WHERE id IN (SELECT ... LIMIT n)`,
       # which sqlite and Postgres take and MySQL refuses (no LIMIT in
       # an IN subquery, no reading the table being deleted from)
       (def finished [:and [:in :state ["completed" "dead"]]
                      [:< :finished-at [:val horizon]]])
       (def batch (map |(get $ :id)
                       (db/query-sql {:select [:id] :from tbl :where finished
                                      :order-by [:finished-at :id]
                                      :limit (math/floor prune-batch)})))
       (def n (if (empty? batch)
                0
                (db/execute! {:delete tbl :where [:and finished [:in :id batch]]})))
       (when (pos? n)
         (log/debug "pruned finished job records" :ns log-ns
                    :rows n :keep-for keep-for)))
     # the schedule leases ride along: fire! takes one per slot and
     # never unlocks it, so rows whose lease expired past its grace are
     # this pass's to delete — see lock-keep
     (lease/prune! locks (- now lock-keep))
     (def stale
       (map row->record
            (db/query-sql
              {:select col-keys :from tbl
               :where [:and [:= :state "running"] [:< :claimed-at [:val cutoff]]]
               :order-by [:claimed-at] :limit (math/floor (get o :limit 100))})))
     (def out @[])
     (each r stale
       # take it over rather than release it: the row stays :running
       # under this worker's token, so a second reaper cannot take it
       # as well
       (def n (db/execute! {:update tbl :set {:token token :claimed-at now}
                            :where [:and [:= :id (r :id)]
                                    [:= :state "running"]
                                    [:= :token (r :token)]]}))
       (when (pos? n)
         (put r :token token)
         (put r :claimed-at now)
         (array/push out r)))
     (tuple ;out))

   :touch!
   (fn db-touch [ids now &opt token]
     (if (empty? ids)
       0
       # the token fences the heartbeat the way it fences the settle: a
       # claim a reaper took away is not this worker's to keep alive
       (db/execute! {:update tbl :set {:claimed-at now}
                     :where (db/all-of [:= :state "running"]
                                       (when token [:= :token token])
                                       [:in :id ids])})))

   :release-parent!
   (fn db-release-parent [child]
     (when-let [pid (get child :parent)]
       (db/with-tx*
         {}
         (fn release-tx []
           (when-let [parent (select-one tbl {:id pid})]
             (array/push (or (get parent :children) (put parent :children @[]))
                         {:id (child :id) :job (child :job)
                          :result (get child :result)})
             (def left (max 0 (dec (get parent :children-left 0))))
             (put parent :children-left left)
             (def released (and (zero? left) (= :waiting (parent :state))))
             (when released
               (put parent :state :pending)
               (put parent :run-at (os/clock :realtime)))
             (db/execute!
               {:update tbl
                :set {:children (record/encode-value (parent :children) "the children")
                      :children-left left
                      :state (string (parent :state))
                      :run-at (parent :run-at)}
                :where {:id pid}})
             (when released parent))))))

   # the locks are leases in `<table>_locks` — void/db/lease's take,
   # renew and release, with the fence and the first taker's savepoint
   # written once there
   :lock!
   (fn db-lock [name ttl token now]
     (lease/acquire! locks name token now ttl))

   :unlock!
   (fn db-unlock [name token]
     (lease/release! locks name token))

   :rate-take!
   (fn db-rate-take [queue limit duration now]
     (if (or (nil? limit) (nil? duration) (<= limit 0) (<= duration 0))
       0
       (do
         (def start (* duration (math/floor (/ now duration))))
         (def window {:queue (string queue) :window-start start})
         (defn wait [] (max 0.001 (- (+ start duration) now)))
         (db/with-tx*
           {}
           (fn rate-tx []
             (if (pos? (db/execute! {:update rates
                                     :set {:n [:sql "n + ?" [1]]}
                                     :where [:and window [:< :n limit]]}))
               0
               # no window row yet, or one that is full. The INSERT
               # says what to do about the race in the statement — a
               # dropped duplicate — so a lost race needs neither a
               # savepoint (the losing INSERT would otherwise abort the
               # transaction around it on Postgres) nor a second
               # SELECT to tell "full" from "somebody else got there
               # first": both answers are "count against it next pass"
               (if (pos? (db/execute! {:insert rates
                                       :values (merge window {:n 1})
                                       :on-conflict {:on [:queue :window-start]}}))
                 0
                 (wait))))))))

   :stats
   (fn db-stats []
     {:store :db
      :table tbl
      :dialect ((db/current-driver) :dialect)
      :keep-for keep-for})

   # the pool belongs to void/db's :db/pool component, which closes it
   :close (fn db-close [] nil)})

# -- the component -------------------------------------------------------

(def component
  (system/component :jobs/db
    :doc "The job queue in the database: rows in the same database as
    the data the jobs act on, claimed with FOR UPDATE SKIP LOCKED
    where the engine has it and inside a transaction where it does
    not, with the locks and rate-limit windows two processes need in
    two small tables beside it."
    :deps [:db/pool]
    :provides [:void/jobs-backend]
    :config {:key :jobs-db}
    :start
    (fn start [_ cfg0]
      (def cfg (merge defaults (or cfg0 {})))
      (when (cfg :auto-create)
        (create-tables! (cfg :table)))
      (log/info "jobs db backend ready" :ns log-ns
                :table (cfg :table)
                :dialect ((db/current-driver) :dialect)
                :keep-for (cfg :keep-for))
      (store cfg))
    :stop
    (fn stop [b] ((b :close)))
    :health
    (fn health [b] (merge {:status :up} ((b :stats))))))

(plugin/contribute! :void.core/cli
  {:name :jobs-db/ddl
   :read-only? true
   :doc "Print the SQL this backend needs (connects, to learn the dialect): void jobs-db ddl"
   # the pool, for its dialect: the same declaration is a different
   # string on each engine, and the one to print is the one this
   # composition runs against
   :needs [:db/pool]
   :fn (fn cli-ddl [_ & args]
         (unless (empty? args)
           (errorf "void jobs-db ddl takes no arguments (got %q)" (string/join args " ")))
         (def cfg (merge defaults
                         (or (get-in plugin/current-boot [:config :values :jobs-db]) {})))
         (each sql (ddl ((db/current-driver) :dialect) (cfg :table))
           (printf "%s;\n" sql)))})

(plugin/defplugin void/jobs-db
  :doc "The job queue in the database: a :void/jobs-backend over void/db — SKIP LOCKED claims on Postgres, transactional claims where there is no SKIP LOCKED, a partial unique index that makes unique jobs exact, and shared locks and rate-limit windows for a fleet of workers."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/jobs ">=0.0.1" :void/db ">=0.0.1"}
  :config-key :jobs-db
  :config-schema Config
  :config-defaults defaults
  :components [component])
