### void/jobs-db — the job queue in the database (SPEC.md §5.12,
### ADR-0012, ROADMAP 2.4).
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
(import void/db :as db)
(import void/db/builder :as builder)
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

# -- the schema ----------------------------------------------------------

(def columns
  ``The column of every record field, in creation order. Kept explicit
  rather than derived: the table is read by people and by other
  services, and a column that quietly renames itself when a field does
  is a migration nobody wrote.``
  [[:id "text primary key"]
   [:job "text not null"]
   [:args "text not null"]
   [:queue "text not null"]
   [:priority "integer not null"]
   [:state "text not null"]
   [:attempt "integer not null"]
   [:max_attempts "integer not null"]
   [:backoff "text"]
   [:timeout "double precision"]
   [:run_at "double precision not null"]
   [:enqueued_at "double precision not null"]
   [:started_at "double precision"]
   [:claimed_at "double precision"]
   [:finished_at "double precision"]
   [:unique_key "text"]
   [:unique_until "double precision"]
   [:group_key "text"]
   [:parent "text"]
   [:children_left "integer"]
   [:children "text"]
   [:result "text"]
   [:error "text"]
   [:failures "text"]
   [:token "text"]])

(def- col-names (map |(string ($ 0)) columns))
(def- col-list (string/join col-names ", "))

(defn ddl
  ``Every statement that creates the tables this backend needs, as a
  tuple of SQL strings — what `[:jobs-db :auto-create]` runs at boot
  and what `void jobs-db ddl` prints for a deployment that would
  rather run its own migration.``
  [&opt table]
  (default table (defaults :table))
  [(string "CREATE TABLE IF NOT EXISTS " table " (\n  "
           (string/join (map |(string ($ 0) " " ($ 1)) columns) ",\n  ")
           "\n)")
   (string "CREATE INDEX IF NOT EXISTS " table "_claim_idx ON " table
           " (state, queue, priority, run_at)")
   (string "CREATE UNIQUE INDEX IF NOT EXISTS " table "_unique_idx ON " table
           " (unique_key) WHERE unique_key IS NOT NULL")
   (string "CREATE INDEX IF NOT EXISTS " table "_parent_idx ON " table
           " (parent)")
   (string "CREATE TABLE IF NOT EXISTS " table "_locks (\n"
           "  name text primary key,\n"
           "  token text not null,\n"
           "  until double precision not null\n)")
   (string "CREATE TABLE IF NOT EXISTS " table "_rates (\n"
           "  queue text not null,\n"
           "  window_start double precision not null,\n"
           "  n integer not null,\n"
           "  primary key (queue, window_start)\n)")])

(defn create-tables!
  "Run `ddl` — idempotent, and safe to run at every boot."
  [&opt table]
  (each sql (ddl table)
    (db/execute-sql sql [] {:kind :write :prepared false}))
  nil)

# -- rows <-> records ----------------------------------------------------

(defn- ph
  "The dialect's placeholder for parameter `n` (1-based): `?` on
  sqlite, `$n` on Postgres."
  [n]
  (((builder/dialect ((db/current-driver) :dialect)) :placeholder) n))

(defn- phs
  "`n` placeholders from `start`, comma separated."
  [start n]
  (string/join (seq [i :range [0 n]] (ph (+ start i))) ", "))

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

(defn- live-states-sql []
  "('pending','running','waiting')")

(defn- select-one [table where params]
  (row->record
    (first (db/query-sql
             [(string "SELECT " col-list " FROM " table " WHERE " where) params]))))

(defn- postgres? []
  (= :postgres ((db/current-driver) :dialect)))

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
    (db/execute-sql
      (string "INSERT INTO " tbl " (" col-list ") VALUES ("
              (phs 1 (length col-names)) ")")
      (map |(get row (keyword (string/replace-all "_" "-" $))) col-names)
      {:kind :write}))

  (defn unique-holder [k now]
    (when k
      (select-one tbl
                  (string "unique_key = " (ph 1)
                          " AND (state IN " (live-states-sql)
                          " OR (unique_until IS NOT NULL AND unique_until > " (ph 2) "))")
                  [k now])))

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
             (def [ok e] (protect (insert-row! (record->row r))))
             (cond
               ok (record/copy r)
               # the partial unique index caught what the check could
               # not: another process inserted between the two. That is
               # not an error, it is the answer
               (and k (unique-holder k now)) nil
               (error e)))))))

   :claim!
   (fn db-claim [o]
     (def now (get o :now (os/clock :realtime)))
     (def token (get o :token))
     (def skip (sorted (keys (get o :skip-groups {}))))
     (defn group-clause [n]
       (if (empty? skip)
         ""
         (string " AND (group_key IS NULL OR group_key NOT IN ("
                 (phs n (length skip)) "))")))
     (var out nil)
     (each qn (get o :queues [])
       (when (nil? out)
         (def where
           (string "state = 'pending' AND queue = " (ph 1)
                   " AND run_at <= " (ph 2) (group-clause 3)))
         (def params (array (string qn) now ;skip))
         (if (postgres?)
           # every placeholder is used once and the repeated value is
           # passed twice: `?` dialects count placeholders, not indices,
           # and a reused $2 is a portability trap waiting for a dialect
           (let [n (length params)
                 rows (db/query-sql
                        [(string "UPDATE " tbl
                                 " SET state = 'running', token = " (ph (+ n 1))
                                 ", attempt = attempt + 1"
                                 ", started_at = " (ph (+ n 2))
                                 ", claimed_at = " (ph (+ n 3))
                                 " WHERE id = (SELECT id FROM " tbl
                                 " WHERE " where
                                 " ORDER BY priority, run_at, id LIMIT 1"
                                 " FOR UPDATE SKIP LOCKED)"
                                 " RETURNING " col-list)
                         (array ;params token now now)])]
             (set out (row->record (first rows))))
           # no SKIP LOCKED: select then update, inside a transaction,
           # with the state re-checked in the UPDATE so a lost race is
           # a lost race and not a second run
           (db/with-tx*
             {}
             (fn claim-tx []
               (def cand
                 (first (db/query-sql
                          [(string "SELECT id FROM " tbl " WHERE " where
                                   " ORDER BY priority, run_at, id LIMIT 1")
                           params])))
               (when cand
                 (def id (get cand :id))
                 (def n (db/execute-sql
                          (string "UPDATE " tbl
                                  " SET state = 'running', token = " (ph 1)
                                  ", attempt = attempt + 1"
                                  ", started_at = " (ph 2)
                                  ", claimed_at = " (ph 3)
                                  " WHERE id = " (ph 4) " AND state = 'pending'")
                          [token now now id] {:kind :write}))
                 (when (pos? (get n :count 0))
                   (set out (select-one tbl (string "id = " (ph 1)) [id])))))))))
     out)

   :settle!
   (fn db-settle [r]
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
     (db/execute! {:update tbl :set sets :where {:id (r :id)}})
     (record/copy r))

   :fetch (fn db-fetch [id] (select-one tbl (string "id = " (ph 1)) [id]))

   :list
   (fn db-list [o0]
     (def o (or o0 {}))
     (def clauses @[])
     (def params @[])
     (each [k col] [[:queue "queue"] [:state "state"] [:job "job"] [:parent "parent"]]
       (when-let [v (get o k)]
         (array/push params (string v))
         (array/push clauses (string col " = " (ph (length params))))))
     (def where (if (empty? clauses) "1 = 1" (string/join clauses " AND ")))
     (tuple ;(map row->record
                  (db/query-sql
                    [(string "SELECT " col-list " FROM " tbl " WHERE " where
                             " ORDER BY enqueued_at DESC, id DESC LIMIT "
                             (math/floor (get o :limit 50)))
                     params]))))

   :counts
   (fn db-counts [&opt _]
     (def out @{})
     (each row (db/query-sql
                 [(string "SELECT queue, state, count(*) AS n FROM " tbl
                          " GROUP BY queue, state") []])
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
       (def n (db/execute-sql
                (string "DELETE FROM " tbl
                        " WHERE state IN ('completed','dead') AND finished_at < " (ph 1)
                        " AND id IN (SELECT id FROM " tbl
                        " WHERE state IN ('completed','dead') AND finished_at < " (ph 2)
                        " LIMIT " (math/floor prune-batch) ")")
                [horizon horizon] {:kind :write}))
       (when (pos? (get n :count 0))
         (log/debug "pruned finished job records" :ns log-ns
                    :rows (get n :count 0) :keep-for keep-for)))
     (def stale
       (map row->record
            (db/query-sql
              [(string "SELECT " col-list " FROM " tbl
                       " WHERE state = 'running' AND claimed_at < " (ph 1)
                       " ORDER BY claimed_at LIMIT " (math/floor (get o :limit 100)))
               [cutoff]])))
     (def out @[])
     (each r stale
       # take it over rather than release it: the row stays :running
       # under this worker's token, so a second reaper cannot take it
       # as well
       (def n (db/execute-sql
                (string "UPDATE " tbl " SET token = " (ph 1) ", claimed_at = " (ph 2)
                        " WHERE id = " (ph 3) " AND state = 'running' AND token = " (ph 4))
                [token now (r :id) (r :token)] {:kind :write}))
       (when (pos? (get n :count 0))
         (put r :token token)
         (put r :claimed-at now)
         (array/push out r)))
     (tuple ;out))

   :touch!
   (fn db-touch [ids now]
     (if (empty? ids)
       0
       (get (db/execute-sql
              (string "UPDATE " tbl " SET claimed_at = " (ph 1)
                      " WHERE state = 'running' AND id IN (" (phs 2 (length ids)) ")")
              (array now ;ids) {:kind :write})
            :count 0)))

   :release-parent!
   (fn db-release-parent [child]
     (when-let [pid (get child :parent)]
       (db/with-tx*
         {}
         (fn release-tx []
           (when-let [parent (select-one tbl (string "id = " (ph 1)) [pid])]
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

   :lock!
   (fn db-lock [name ttl token now]
     (def until (+ now ttl))
     (db/with-tx*
       {}
       (fn lock-tx []
         (def cur (first (db/query-sql
                           [(string "SELECT token, until FROM " locks
                                    " WHERE name = " (ph 1)) [name]])))
         (cond
           (nil? cur)
           (let [[ok e] (protect
                          (db/execute-sql
                            (string "INSERT INTO " locks " (name, token, until) VALUES ("
                                    (phs 1 3) ")")
                            [name token until] {:kind :write}))]
             # the primary key caught the race the SELECT could not
             (truthy? ok))

           (or (= token (get cur :token)) (<= (get cur :until 0) now))
           (pos? (get (db/execute-sql
                        (string "UPDATE " locks " SET token = " (ph 1) ", until = " (ph 2)
                                " WHERE name = " (ph 3)
                                " AND (until <= " (ph 4) " OR token = " (ph 5) ")")
                        [token until name now token] {:kind :write})
                      :count 0))

           false))))

   :unlock!
   (fn db-unlock [name token]
     (pos? (db/execute! {:delete locks :where {:name name :token token}})))

   :rate-take!
   (fn db-rate-take [queue limit duration now]
     (if (or (nil? limit) (nil? duration) (<= limit 0) (<= duration 0))
       0
       (do
         (def start (* duration (math/floor (/ now duration))))
         (db/with-tx*
           {}
           (fn rate-tx []
             (def n (db/execute-sql
                      (string "UPDATE " rates " SET n = n + 1"
                              " WHERE queue = " (ph 1) " AND window_start = " (ph 2)
                              " AND n < " (ph 3))
                      [(string queue) start limit] {:kind :write}))
             (cond
               (pos? (get n :count 0)) 0

               (first (db/query-sql
                        [(string "SELECT n FROM " rates
                                 " WHERE queue = " (ph 1) " AND window_start = " (ph 2))
                         [(string queue) start]]))
               (max 0.001 (- (+ start duration) now))

               (let [[ok _] (protect
                              (db/execute-sql
                                (string "INSERT INTO " rates
                                        " (queue, window_start, n) VALUES (" (phs 1 3) ")")
                                [(string queue) start 1] {:kind :write}))]
                 (if ok
                   0
                   # somebody inserted the window between our UPDATE and
                   # our INSERT: count against it on the next pass
                   (max 0.001 (- (+ start duration) now))))))))))

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
    :config {:key :jobs-db :schema Config}
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
   :doc "Print the SQL this backend needs: void jobs-db ddl"
   :fn (fn cli-ddl [& args]
         (unless (empty? args)
           (errorf "void jobs-db ddl takes no arguments (got %q)" (string/join args " ")))
         (def cfg (merge defaults
                         (or (get-in plugin/current-boot [:config :values :jobs-db]) {})))
         (each sql (ddl (cfg :table))
           (printf "%s;\n" sql)))})

(plugin/defplugin void/jobs-db
  :doc "The job queue in the database: a :void/jobs-backend over void/db — SKIP LOCKED claims on Postgres, transactional claims where there is no SKIP LOCKED, a partial unique index that makes unique jobs exact, and shared locks and rate-limit windows for a fleet of workers."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/jobs ">=0.0.1" :void/db ">=0.0.1"}
  :config-key :jobs-db
  :config-schema Config
  :config-defaults defaults
  :components [component])
