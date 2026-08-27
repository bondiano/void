### void/db/migrate — migrations as janet files (SPEC.md §5.9,
### ROADMAP 2.1).
###
### A migration is a file named <version>_<name>.janet defining `up`
### and (optionally) `down`:
###
###     (defn up []
###       (db/execute-sql "CREATE TABLE users (id integer primary key,
###                        email text not null unique)" []))
###
###     (defn down [] (db/execute-sql "DROP TABLE users" []))
###
### SQL a step *returns* is executed too, so the shortest spelling —
### (defn up [] "CREATE TABLE ...") or an array of statements — works
### as it reads, and either binding may be a bare string instead of a
### function when there is nothing to compute. The version is the filename
### prefix, so ordering is lexicographic and stable across machines;
### `void db migrate` applies everything pending, each file in its own
### transaction (opt out with (def transaction? false) for statements
### the engine cannot run transactionally), and records it in the
### version table. `void db rollback` walks the recorded versions back
### through their `down`, newest first, and refuses to guess when a
### migration has none.

(import void/core/log :as log)
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
  "Split a migration filename into {:version :name}, or nil when it is
  not a migration file."
  [filename]
  (unless (string/has-suffix? ".janet" filename)
    (break nil))
  (def stem (string/slice filename 0 (- (length filename) 6)))
  (when-let [[version name] (peg/match file-peg stem)]
    {:version version :name name}))

(defn files
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

(defn ensure-table!
  "Create the version table when missing (idempotent)."
  [&opt table]
  (default table default-table)
  (state/execute-sql
    (string "CREATE TABLE IF NOT EXISTS " table
            " (version text primary key, name text, applied_at text)")
    [] {:kind :write :prepared false})
  nil)

(defn applied
  "Versions already applied, oldest first."
  [&opt table]
  (default table default-table)
  (ensure-table! table)
  (map |(string (get $ :version))
       (state/query {:select [:version] :from table
                     :order-by [[:version :asc]]})))

(defn pending
  "Migrations in `dir` not yet recorded in the version table."
  [&opt dir table]
  (def done (tabseq [v :in (applied table)] v true))
  (filter |(not (in done ($ :version))) (files dir)))

(defn status
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

# -- running -------------------------------------------------------------

(defn- load-migration
  "Load a migration file and read its up/down/transaction? bindings."
  [m]
  (def env (dofile (m :path)))
  (defn binding [name]
    (get-in env [name :value]))
  (merge m {:up (binding 'up)
            :down (binding 'down)
            :transaction? (let [v (binding 'transaction?)] (if (nil? v) true v))}))

(defn- run-sql [v]
  (cond
    (bytes? v) (state/execute-sql (string v) [] {:kind :write :prepared false})
    (indexed? v) (each sql v (run-sql sql))
    # a step that did its own work through db/* returns whatever it
    # returns — only SQL values are executed
    nil))

(defn- run-step [m dir-key]
  (def step (get m dir-key))
  (cond
    (nil? step)
    (errorf "migration %s_%s has no %q" (m :version) (m :name) dir-key)

    # a function may run statements itself *and* return SQL to run —
    # (defn up [] "CREATE TABLE ...") is the shortest spelling there is,
    # and it must not be a silent no-op
    (or (function? step) (cfunction? step)) (run-sql (step))

    (or (bytes? step) (indexed? step)) (run-sql step)

    (errorf "migration %s_%s: %q must be a function, a SQL string or a tuple of them, got %q"
            (m :version) (m :name) dir-key step)))

(defn- utc-string [&opt at]
  (def d (os/date (or at (os/time)) true))
  (string/format "%04d-%02d-%02dT%02d:%02d:%02dZ"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))

(defn- record! [table m]
  (state/execute! {:insert table
                   :values {:version (m :version)
                            :name (m :name)
                            :applied-at (utc-string)}}))

(defn- forget! [table m]
  (state/execute! {:delete table :where {:version (m :version)}}))

(defn- apply-one [table m dir-key]
  (def run
    (fn []
      (run-step m dir-key)
      (if (= :up dir-key) (record! table m) (forget! table m))))
  (if (m :transaction?)
    (state/with-tx* {} run)
    (run)))

(defn up!
  ``Apply pending migrations, oldest first. opts: :dir, :table, :step
  (apply at most N), :to (stop after this version). Returns the
  applied migrations.``
  [&opt opts]
  (default opts {})
  (def table (get opts :table default-table))
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
  done)

(defn down!
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

# -- scaffolding ---------------------------------------------------------

(def- template
  ``### %s
(import void/db :as db)

(defn up []
  # (db/execute-sql "CREATE TABLE ..." [])
  )

(defn down []
  # (db/execute-sql "DROP TABLE ..." [])
  )
``)

(defn timestamp
  "Version stamp for a new migration: UTC YYYYMMDDHHMMSS."
  [&opt at]
  (def d (os/date (or at (os/time)) true))
  (string/format "%04d%02d%02d%02d%02d%02d"
                 (d :year) (inc (d :month)) (inc (d :month-day))
                 (d :hours) (d :minutes) (d :seconds)))

(defn- mkdirs! [dir]
  (var acc (if (string/has-prefix? "/" dir) "" "."))
  (each part (string/split "/" dir)
    (unless (empty? part)
      (set acc (string acc "/" part))
      (os/mkdir acc))))

(defn create!
  "Write an empty migration file and return its path."
  [name &opt dir at]
  (default dir default-dir)
  (mkdirs! dir)
  (def slug (string/replace-all " " "_" name))
  (def path (string dir "/" (timestamp at) "_" slug ".janet"))
  (spit path (string/format template slug))
  path)
