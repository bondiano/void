### void/db/lease — a named lease in a table: taken with a token and a
### deadline, renewed by its holder, stolen once it expires.
###
### Two plugins need "one process at a time" across a fleet — void/jobs-db
### for a schedule slot that must fire once and for `defschedule`'s
### locks, void/bus-db for the reader of a consumer group and for the
### outbox forwarder — and before this module each carried its own
### lease table, its own DDL string per dialect and its own take/renew
### dance. Here is the one copy: a row `(name, token, until)` per lease,
### the DDL as a builder statement so every dialect spells it itself,
### and three operations over builder queries.
###
### **The fence is the UPDATE's WHERE, not a lock.** `acquire!` is an
### `UPDATE ... WHERE name = ? AND (until <= now OR token = mine)` —
### one row changes when the lease is free, expired or already mine, and
### no row changes when somebody else holds it. That is the whole
### arbitration: two processes asking in the same instant race on the
### row, the engine serializes the two UPDATEs, and the second one
### re-reads the row the first one wrote and changes nothing. No `FOR
### UPDATE`, no `SKIP LOCKED`, no advisory lock — deliberately, because
### the lease is *held across application code* (a batch of handlers, a
### schedule's job), and a row lock held that long would be a
### transaction open across arbitrary code, which is the thing void/db
### exists to keep from happening by accident. It also keeps the module
### inside the SQL every engine has, MySQL included: no RETURNING, no
### ON CONFLICT, nothing version-dependent.
###
### **The first taker inserts, and a lost insert is an answer.** A lease
### that has never been taken has no row; the UPDATE changes nothing,
### the module checks that the row is really absent (a follower polling
### a live lease must not hammer the primary key on every pass), then
### INSERTs. Two first takers race on the primary key, one loses with a
### unique violation, and that violation means "somebody else has it" —
### `false`, not an error. The INSERT runs in its own transaction scope
### (a savepoint inside a caller's transaction) because on Postgres a
### failed statement poisons the transaction around it (SQLSTATE 25P02),
### and the lease must be askable from inside one.
###
### **A release is a DELETE.** The row goes, the next taker inserts.
### A lease that is taken and never released — a schedule slot that
### fired — is what `prune!` is for: the owner deletes rows whose
### deadline is older than a grace it chooses, on whatever periodic pass
### it already has.
###
### Time is the caller's: `now` is passed in (seconds, a real number),
### never read from the clock here, so a suite can move it and the two
### plugins can share one reading across a pass.

(import void/core/errors :as errors)
(import ./builder :as builder)
(import ./state :as state)

(def columns
  ``The lease table as builder columns. `:string`, not `:text`, for the
  key: the two are the same on sqlite and Postgres, and on MySQL a TEXT
  column cannot be a primary key without a prefix length — `varchar(255)`
  can. `until` is a `:double` (seconds, with a fraction): 17 significant
  digits round-trip, which is more than a clock reading carries.``
  [[:name :string {:primary-key true}]
   [:token :text {:null false}]
   [:until :double {:null false}]])

(defn statement
  "The `CREATE TABLE IF NOT EXISTS` of a lease table, as a builder map."
  [table]
  {:create-table table :if-not-exists true :columns columns})

(defn ddl
  ``The DDL of a lease table as one SQL string, spelled for `dialect` —
  what `void jobs-db ddl` and `void bus-db ddl` print.``
  [dialect table]
  (first (builder/format (statement table) dialect)))

(defn create-table!
  "Create the lease table on the active pool — idempotent, safe at every boot."
  [table]
  (state/run (statement table) {:kind :write :prepared false})
  nil)

# -- the three operations ------------------------------------------------

(defn- renew-or-steal!
  ``The fence: one row changes when the lease is free, expired or
  already held under `token`; none when somebody else holds it.``
  [table name token now until]
  (pos? (state/execute!
          {:update table
           :set {:token token :until until}
           :where [:and [:= :name [:val name]]
                   [:or [:<= :until [:val now]]
                    [:= :token [:val token]]]]})))

(defn- taken?
  "Is there a row for `name` at all — whoever holds it?"
  [table name]
  (truthy? (state/one {:select [:name] :from table :where {:name name}})))

(defn- insert-first!
  ``The first taker's INSERT, in its own transaction scope so a lost
  race on the primary key stays a `false` and never poisons a
  transaction the caller is in.``
  [table name token until]
  (def [ok e]
    (protect
      (state/with-tx*
        {}
        (fn lease-insert []
          (state/execute! {:insert table
                           :values {:name name :token token :until until}})))))
  (cond
    ok true
    # the only failure that is an answer: somebody inserted first. A
    # connection lost under the INSERT is still an error
    (errors/kind? e :void.db/unique-violation) false
    (error e)))

(defn acquire!
  ``Take or renew the lease `name` under `token` until `now + ttl`.
  True when this caller holds it on return — it was free, it had
  expired, or it was already this token's; false when another token
  holds it and its deadline has not passed. Renewing is the same call
  with the same token, which is what a heartbeat is.``
  [table name token now ttl]
  (def until (+ now ttl))
  (state/with-conn*
    (fn lease-acquire [_]
      (cond
        (renew-or-steal! table name token now until) true
        (taken? table name) false
        (insert-first! table name token until)))))

(defn release!
  ``Give the lease back: the row is deleted when `token` holds it. True
  when it was this token's to release; false when it was not — an
  expired lease somebody else has since taken is theirs, and a release
  that changed nothing says so rather than taking it from them.``
  [table name token]
  (pos? (state/execute! {:delete table :where {:name name :token token}})))

(defn prune!
  ``Delete every lease whose deadline passed before `horizon`. For the
  owner's periodic pass: a lease that is taken and never released — a
  schedule slot that fired — is otherwise a row forever. Returns how
  many went.``
  [table horizon]
  (state/execute! {:delete table :where [:< :until [:val horizon]]}))

(defn holder
  "Who holds `name`: {:token :until}, or nil when nobody has taken it."
  [table name]
  (state/one {:select [:token :until] :from table :where {:name name}}))
