(import ../test-support/paths)
(import ../test-support/fake-driver :as fake)
(import void/core/log :as log)
(import void/core/errors :as errors)
(import void/db/driver :as driver)
(import void/db/lease :as lease)
(import void/db/pool :as pool)
(import void/db/state :as db)

# the losing INSERT below is driven to its error path on purpose; keep
# the funnel's "db query failed" line out of the test log
(log/set-level! "void.db.query" :fatal)

# What the lease module *says* to an engine — its DDL per dialect and
# the statements each answer is made of — checked against a scripted
# driver. What an engine *does* with them (one holder at a time, the
# race on the first take) is void/db/conformance/lease, run by each
# driver package against the real thing.

# -- the DDL, per dialect ------------------------------------------------

(def sqlite-ddl (lease/ddl :sqlite "t_leases"))
(assert (string/find `"name" text PRIMARY KEY` sqlite-ddl)
        "on sqlite the key is text, which is what it was as a hand-written string")
(assert (string/find `"until" real NOT NULL` sqlite-ddl)
        "and the deadline a real — the affinity `double precision` had")
(assert (string/find "IF NOT EXISTS" sqlite-ddl) "the table is created only when missing")

(assert (string/find `"until" double precision NOT NULL` (lease/ddl :postgres "t_leases"))
        "on Postgres the deadline is a double precision")

# MySQL is the dialect no suite in this repository can run live, so
# what it would receive is pinned here: a TEXT primary key is a syntax
# error there (no prefix length), so the key is a varchar; identifiers
# are backticked; the deadline is MySQL's own `double`
(def mysql-ddl (lease/ddl :mysql "t_leases"))
(assert (string/find "`name` varchar(255) PRIMARY KEY" mysql-ddl)
        "on MySQL the key is a varchar, because a TEXT column cannot be a primary key there")
(assert (string/find "`until` double NOT NULL" mysql-ddl)
        "and the deadline is a double")
(assert (not (string/find `"` mysql-ddl)) "with nothing quoted the ANSI way")

# -- the statements behind an answer -------------------------------------
#
# The driver answers from a plan the test sets before each call:
#   :update  rows the UPDATE reports changed
#   :select  rows the existence check finds
#   :insert  :ok, or what the INSERT raises

(def plan @{:update 0 :select [] :insert :ok})

(defn- respond [sql _]
  (cond
    (string/has-prefix? "UPDATE" sql) @{:rows [] :count (plan :update)}
    (string/has-prefix? "SELECT" sql) @{:rows (plan :select) :count (length (plan :select))}
    (string/has-prefix? "INSERT" sql)
    (case (plan :insert)
      :ok @{:rows [] :count 1}
      (error (plan :insert)))
    @{:rows [] :count 0}))

(def [drv st] (fake/make {:dialect :sqlite :responder respond}))
(def p (pool/make (driver/normalize drv) {:size 2 :checkout-timeout 1}))

(defn- statements
  "The SQL verbs the driver saw during `f`, in order."
  [f]
  (fake/clear! st)
  (def result (f))
  [result (map |(first (string/split " " $)) (fake/sqls st))])

(with-dyns [db/pool-dyn p]

  # -- a holder renews with one statement ------------------------------

  (put plan :update 1)
  (def [got verbs] (statements |(lease/acquire! "t_leases" "l" "a" 100 30)))
  (assert got "the UPDATE changing a row is the whole of a take or a renewal")
  (assert (deep= @["UPDATE"] verbs) "and it is the only statement — a heartbeat costs one round trip")

  (def upd (first (fake/log st)))
  (assert (string/find "(\"until\" <= ? OR \"token\" = ?)" (upd :sql))
          "the fence is in the WHERE: free, expired or already mine")
  (assert (deep= ["a" 130 "l" 100 "a"] (tuple ;(upd :params)))
          "with the new deadline now + ttl, and now, not the clock, as the reference")

  # -- a follower does not hammer the primary key ----------------------

  (put plan :update 0)
  (put plan :select [{:name "l"}])
  (def [got verbs] (statements |(lease/acquire! "t_leases" "l" "b" 100 30)))
  (assert (not got) "a lease held by another token is refused")
  (assert (deep= @["UPDATE" "SELECT"] verbs)
          "after one look at the row — never an INSERT that would fail on every poll")

  # -- the first taker inserts, in a scope of its own -------------------

  (put plan :select [])
  (def [got verbs] (statements |(lease/acquire! "t_leases" "fresh" "a" 100 30)))
  (assert got "a lease nobody has taken is taken by inserting it")
  (assert (deep= @["UPDATE" "SELECT" "BEGIN" "INSERT" "COMMIT"] verbs)
          "inside a transaction of its own when the caller has none")

  (def [got verbs]
    (statements |(db/with-tx* {} (fn [] (lease/acquire! "t_leases" "fresh" "a" 100 30)))))
  (assert got)
  (assert (deep= @["BEGIN" "UPDATE" "SELECT" "SAVEPOINT" "INSERT" "RELEASE" "COMMIT"] verbs)
          "and inside a savepoint when the caller has one")

  # -- a lost race is an answer; anything else is an error --------------

  (put plan :insert {:db/error :fake :sqlstate "23505" :message "duplicate key"})
  (def [got verbs]
    (statements |(db/with-tx* {} (fn [] (lease/acquire! "t_leases" "fresh" "b" 100 30)))))
  (assert (not got) "losing the INSERT to another first taker reads as `held by somebody else`")
  (assert (deep= @["BEGIN" "UPDATE" "SELECT" "SAVEPOINT" "INSERT" "ROLLBACK" "COMMIT"] verbs)
          "the savepoint is rolled back and the caller's transaction commits — nothing poisoned")

  (put plan :insert "the connection went away")
  (def [ok e] (protect (lease/acquire! "t_leases" "fresh" "b" 100 30)))
  (assert (not ok) "a connection lost under the INSERT is not `somebody else has it`")
  (assert (string/find "went away" (errors/message e)) "it propagates as what it was")
  (put plan :insert :ok)

  # -- release and prune are one statement each --------------------------

  (put plan :update 1)
  (def [_ verbs] (statements |(lease/release! "t_leases" "l" "a")))
  (assert (deep= @["DELETE"] verbs) "a release is a DELETE")
  (def del (first (fake/log st)))
  (assert (deep= ["l" "a"] (tuple ;(del :params))) "of the row this token holds")

  (def [_ verbs] (statements |(lease/prune! "t_leases" 50)))
  (assert (deep= @["DELETE"] verbs) "a prune is a DELETE")
  (assert (string/find `"until" < ?` ((first (fake/log st)) :sql)) "of what expired before the horizon"))

# -- what MySQL would receive --------------------------------------------
#
# The same calls compiled for the one dialect that has no RETURNING,
# no ON CONFLICT and a SKIP LOCKED that depends on the server version:
# none of the three appears, and every parameter is a `?`. The lease
# stays inside the SQL every engine has.

(def [mdrv mst] (fake/make {:dialect :mysql :responder respond}))
(def mp (pool/make (driver/normalize mdrv) {:size 1 :checkout-timeout 1}))
(with-dyns [db/pool-dyn mp]
  (put plan :update 0)
  (put plan :select [])
  (lease/acquire! "t_leases" "l" "a" 100 30)
  (lease/release! "t_leases" "l" "a")
  (lease/prune! "t_leases" 50))
(each sql (fake/sqls mst)
  (each word ["RETURNING" "ON CONFLICT" "ON DUPLICATE" "SKIP LOCKED" "FOR UPDATE" "$1" `"`]
    (assert (not (string/find word sql))
            (string/format "the MySQL statement %q has no %s" sql word))))
(assert (some |(string/find "`t_leases`" $) (fake/sqls mst))
        "and every identifier is backticked, MySQL's own quoting")

# the placeholder count is the parameter count on a `?` dialect — the
# trap a reused `$2` would fall into, with no engine to catch it here
(each {:sql sql :params params} (fake/log mst)
  (assert (= (length params) (length (string/find-all "?" sql)))
          (string/format "%q binds one parameter per `?`" sql)))

(pool/close-all! p)
(pool/close-all! mp)
(print "void/db/lease tests OK")
