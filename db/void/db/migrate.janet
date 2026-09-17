### void/db/migrate — migrations as janet files.
###
### A migration is a file named <version>_<name>.janet defining `up`
### and (optionally) `down`:
###
###     (defn up []
###       {:create-table "users"
###        :columns [[:id :serial {:primary-key true}]
###                  [:email :text {:null false :unique true}]]})
###
###     (defn down [] {:drop-table "users"})
###
### What a step *returns* is executed: a statement map (SQL as data —
### void/db/builder compiles the DDL for whichever engine is running,
### which is what keeps one migration file portable), a raw SQL string
### for what the builder has no spelling for, or a tuple of either.
### Either binding may be a bare value instead of a function when there
### is nothing to compute, and a step that ran its own statements
### through db/* and returns nothing is fine too. The version is the filename
### prefix, so ordering is lexicographic and stable across machines;
### `void db migrate` applies everything pending, each file in its own
### transaction (opt out with (def transaction? false) for statements
### the engine cannot run transactionally), and records it in the
### version table. `void db rollback` walks the recorded versions back
### through their `down`, newest first, and refuses to guess when a
### migration has none.
###
### The whole of `up!` runs under an advisory lock on the version
### table's name, held by one connection for the pass: two processes
### of a fleet starting together both find the same migration pending,
### and the one that loses the race reads the pending list again and
### finds nothing to do. Where the engine has no advisory lock
### (sqlite) the pass says so at debug and runs — see `with-lock*`.

(import void/core/log :as log)
(import void/core/util :as util)
(import ./builder :as builder)
(import ./state :as state)

(def default-dir
  "Where `void db migrate` looks for migration files."
  "db/migrations")

(def default-table
  "Table recording applied versions."
  "schema_migrations")

(def- file-peg
  (peg/compile ~(* (<- (some (if-not "_" 1))) "_" (<- (some 1)) -1)))

(defn parse-name
  {:params [:string] :ret (or {:version :string :name :string} :nil)}
  "Split a migration filename into {:version :name}, or nil when it is
  not a migration file."
  [filename]
  (unless (string/has-suffix? ".janet" filename)
    (break nil))
  (def stem (string/slice filename 0 (- (length filename) 6)))
  (when-let [[version name] (peg/match file-peg stem)]
    {:version version :name name}))

(defn files
  {:params [:string?]
   :ret @[DbMigration]
   :throws [:string]}
  ``Every migration in a directory, ordered by version:
  [{:version :name :path} ...].``
  [&opt dir]
  (default dir default-dir)
  (unless (os/stat dir :mode)
    (errorf "migrations directory %q does not exist" dir))
  (def out @[])
  (each f (sorted (os/dir dir))
    (when-let [m (parse-name f)]
      (array/push out (merge m {:path (string dir "/" f)}))))
  (sorted-by |($ :version) out))

# -- the version table ---------------------------------------------------

(def version-table
  ``The version table, as a declaration. `:string` rather than `:text`
  for the key: on MySQL a TEXT column cannot be a primary key without
  a prefix length, and this table was one hand-written string for
  every engine until the builder had a spelling for the difference.``
  {:columns [[:version :string {:primary-key true}]
             [:name :string]
             [:applied-at :string]]})

(defn ensure-table!
  {:params [:string?] :ret :nil
   :throws [:string VoidError]}
  "Create the version table when missing (idempotent)."
  [&opt table]
  (default table default-table)
  (state/run (merge version-table {:create-table table :if-not-exists true})
             {:kind :write :prepared false})
  nil)

(defn applied
  {:params [:string?] :ret @[:string]
   :throws [:string VoidError]}
  "Versions already applied, oldest first."
  [&opt table]
  (default table default-table)
  (ensure-table! table)
  (map |(string (get $ :version))
       (state/query {:select [:version] :from table
                     :order-by [[:version :asc]]})))

(defn pending
  {:params [:string? :string?]
   :ret @[DbMigration]
   :throws [:string VoidError]}
  "Migrations in `dir` not yet recorded in the version table."
  [&opt dir table]
  (def done (tabseq [v :in (applied table)] v true))
  (filter |(not (in done ($ :version))) (files dir)))

(defn status
  {:params [:string? :string?]
   :ret @[{:version :string :name :string :applied :boolean & r}]
   :throws [:string VoidError]}
  ``Every migration with its state: [{:version :name :applied bool}
  ...], plus rows recorded in the table whose file has disappeared
  (:missing true) — the drift that bites when a branch is switched.``
  [&opt dir table]
  (def done (tabseq [v :in (applied table)] v true))
  (def out @[])
  (each m (files dir)
    (array/push out (merge m {:applied (truthy? (in done (m :version)))}))
    (put done (m :version) :seen))
  (eachp [v state] done
    (when (= true state)
      (array/push out {:version v :name "?" :applied true :missing true})))
  (sorted-by |($ :version) out))

# -- the lock ------------------------------------------------------------
#
# Two processes of a fleet starting together both find the same
# migration pending, and both run it. What happens next depends on the
# migration and is never good: two `CREATE TABLE`s where one fails
# halfway through a transaction the other is inside, a data backfill
# applied twice, two rows in the version table.
#
# So the pass takes a lock on a *name* — an advisory lock, which
# belongs to no table and is held by the connection rather than by a
# transaction. That last part is why the whole pass runs inside one
# `with-conn`: a lock taken on a connection that goes back to the pool
# is a lock that has been released.
#
# Where the engine has no such thing (sqlite) the pass runs unlocked
# and says so once, at debug: sqlite has a single writer, and a fleet
# on a file in one filesystem is a deployment shape void/deploy
# already refuses (`ready no — the store is per-process`).

(defn lock-name
  {:params [:string] :ret :string}
  "The name the migration lock is taken under — the version table, so
  two applications sharing a database do not wait for each other."
  [table]
  (string "void_migrate:" table))

(defn- with-lock*
  {:params [:string (fn [] :any)] :ret :any :throws [:any]}
  "Run (f) holding the migration lock, on one connection."
  [table f]
  (def dialect ((state/driver) :dialect))
  (def spec (builder/capability dialect :advisory-lock))
  (if-not spec
    (do
      (log/debug "migrating without a lock — this engine has no advisory lock"
                 :ns "void.db.migrate" :dialect dialect)
      (f))
    (state/with-conn*
      (fn locked [_]
        (def name (lock-name table))
        (def [sql params] ((spec :acquire) name))
        (def rows (get (state/execute-sql sql params {:kind :select :prepared false})
                       :rows []))
        (def got? (get spec :acquired? (fn always [_] true)))
        (unless (got? rows)
          (errorf (string "could not take the migration lock %q — another process "
                          "is migrating this database and has been for a while. "
                          "Nothing was applied")
                  name))
        (defer (let [[rsql rparams] ((spec :release) name)]
                 (protect (state/execute-sql rsql rparams {:kind :select :prepared false})))
          (f))))))

# -- running -------------------------------------------------------------

(defn- load-migration
  {:params [DbMigration]
   :ret DbLoadedMigration
   :throws [:any]}
  "Load a migration file and read its up/down/transaction? bindings."
  [m]
  (def env (dofile (m :path)))
  (defn binding [name]
    (get-in env [name :value]))
  (merge m {:up (binding 'up)
            :down (binding 'down)
            :transaction? (let [v (binding 'transaction?)] (if (nil? v) true v))}))

(defn- run-sql
  {:params [(or :string :buffer DbStatement @[:any] [:any] :nil)]
   :ret DbResult?
   :throws [:string VoidError]}
  "Execute what a migration step evaluated to: a raw SQL string, a
  statement map for the builder, a tuple of either run in order, or
  nothing when the step already did its own work through db/*."
  [v]
  (cond
    (bytes? v) (state/execute-sql (string v) [] {:kind :write :prepared false})
    # a statement map is SQL as data (void/db/builder), DDL included:
    # {:create-table "authors" :columns [[:id :serial {:primary-key true}] ...]}
    # compiles for the driver's own dialect, so one migration file runs
    # on every engine
    (dictionary? v) (state/run v {:kind :write :prepared false})
    (indexed? v) (each sql v (run-sql sql))
    # a step that did its own work through db/* returns whatever it
    # returns — only SQL values are executed
    nil))

(defn- run-step
  {:params [DbLoadedMigration (enum :up :down)]
   :ret DbResult?
   :throws [:any]}
  "Run one direction of a migration — a function, a bare SQL value, or
  a tuple of either — and refuse a step that names neither."
  [m dir-key]
  (def step (get m dir-key))
  (cond
    (nil? step)
    (errorf "migration %s_%s has no %q" (m :version) (m :name) dir-key)

    # a function may run statements itself *and* return SQL to run —
    # (defn up [] "CREATE TABLE ...") is the shortest spelling there is,
    # and it must not be a silent no-op
    (util/callable? step) (run-sql (step))

    (or (bytes? step) (indexed? step)) (run-sql step)

    (errorf "migration %s_%s: %q must be a function, a SQL string or a tuple of them, got %q"
            (m :version) (m :name) dir-key step)))

(defn- utc-string
  {:params [:number?] :ret :string}
  "The applied-at timestamp, ISO 8601 UTC — the record format for
  every engine's :string column, independent of its own date type."
  [&opt at]
  (def d (os/date (or at (os/time)) true))
  (string/format "%04d-%02d-%02dT%02d:%02d:%02dZ"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))

(defn- record!
  {:params [:string DbLoadedMigration] :ret :number
   :throws [:string VoidError]}
  "Record a migration as applied."
  [table m]
  (state/execute! {:insert table
                   :values {:version (m :version)
                            :name (m :name)
                            :applied-at (utc-string)}}))

(defn- forget!
  {:params [:string DbLoadedMigration] :ret :number
   :throws [:string VoidError]}
  "Remove a migration's applied record, on rollback."
  [table m]
  (state/execute! {:delete table :where {:version (m :version)}}))

(defn- apply-one
  {:params [:string DbLoadedMigration (enum :up :down)]
   :ret :number
   :throws [:any]}
  "Run one migration's step and record (or unrecord) it, wrapped in a
  transaction unless the migration opted out with `(def transaction?
  false)`."
  [table m dir-key]
  (def run
    (fn []
      (run-step m dir-key)
      (if (= :up dir-key) (record! table m) (forget! table m))))
  (if (m :transaction?)
    (state/with-tx* {} run)
    (run)))

(defn up!
  {:params [(or {:dir :string? :table :string? :step :number? :to :string? & r} :nil)]
   :ret @[DbMigration]
   :throws [:any]}
  ``Apply pending migrations, oldest first. opts: :dir, :table, :step
  (apply at most N), :to (stop after this version). Returns the
  applied migrations.``
  [&opt opts]
  (default opts {})
  (def table (get opts :table default-table))
  (with-lock* table
    (fn migrate-up []
      # inside the lock, not before it: the pending list is what the
      # process that lost the race has to read again, or it applies
      # what the winner has just applied
      (def todo (pending (get opts :dir) table))
      (def limited
        (let [by-to (if-let [to (get opts :to)]
                      (filter |(<= (compare ($ :version) to) 0) todo)
                      todo)]
          (if-let [n (get opts :step)] (take n by-to) by-to)))
      (def done @[])
      (each m limited
        (def loaded (load-migration m))
        (def t0 (os/clock :monotonic))
        (apply-one table loaded :up)
        (log/info "migration applied" :ns "void.db.migrate"
                  :version (m :version) :name (m :name)
                  :ms (math/round (* 1000 (- (os/clock :monotonic) t0))))
        (array/push done m))
      done)))

(defn down!
  {:params [(or {:dir :string? :table :string? :step :number? :to :string? & r} :nil)]
   :ret @[DbMigration]
   :throws [:any]}
  ``Roll the newest applied migrations back through their `down`.
  opts: :dir, :table, :step (default 1), :to (roll back everything
  after this version). Returns the reverted migrations.``
  [&opt opts]
  (default opts {})
  (def table (get opts :table default-table))
  (def done (tabseq [v :in (applied table)] v true))
  (def candidates
    (reverse (filter |(in done ($ :version)) (files (get opts :dir)))))
  (def limited
    (if-let [to (get opts :to)]
      (filter |(> (compare ($ :version) to) 0) candidates)
      (take (get opts :step 1) candidates)))
  (def reverted @[])
  (each m limited
    (def loaded (load-migration m))
    (unless (loaded :down)
      (errorf "migration %s_%s is irreversible (no `down`) — nothing was rolled back"
              (m :version) (m :name)))
    (apply-one table loaded :down)
    (log/info "migration reverted" :ns "void.db.migrate"
              :version (m :version) :name (m :name))
    (array/push reverted m))
  reverted)


