(import ../test-support/paths)
(import ../test-support/fake-driver :as fake)
(import void/core/log :as log)
(import void/db/driver :as driver)
(import void/db/pool :as pool)
(import void/db/state :as db)

# the cancel test deliberately drives a query to its error path; keep the
# funnel's "db query failed" line out of the test log
(log/set-level! "void.db.query" :fatal)

(defn- setup [&opt opts]
  (def [drv st] (fake/make (or opts {})))
  [(pool/make (driver/normalize drv) {:size 2 :checkout-timeout 1}) st])

# every scope below runs against its own pool through the dyn override
(defmacro- with-db [p & body]
  ~(with-dyns [db/pool-dyn ,p] ,;body))

# -- statements ----------------------------------------------------------

(def [p st]
  (setup {:responder (fake/rows-responder
                       {`SELECT * FROM "users"` [{:id 1 :email "a@b.c"}]})}))

(with-db p
  (assert (deep= [{:id 1 :email "a@b.c"}] (db/query {:select [:*] :from "users"}))
          "query returns the driver's rows")
  (assert (= 1 ((db/one {:select [:*] :from "users"}) :id)) "one returns a row")
  (assert (string/has-suffix? "LIMIT ?" (get-in (fake/log st) [1 :sql]))
          "one caps the select at one row")
  (assert (= 0 (db/execute! {:delete "users" :where {:id 2}}))
          "execute! returns the affected count"))

(def [p2 st2] (setup {:responder (fake/rows-responder {"count(*)" [{:n 7}]})}))
(with-db p2
  (assert (= 7 (db/value {:select [[:raw "count(*) AS n"]] :from "users"}))
          "value unwraps a single-column row"))

# -- one connection per scope --------------------------------------------

(def [p3 st3] (setup))
(with-db p3
  (db/with-conn
    (db/query {:select [:*] :from "a"})
    (db/query {:select [:*] :from "b"}))
  (assert (= 1 (st3 :conns)) "a with-conn scope uses one connection")
  (db/query {:select [:*] :from "c"})
  (assert (= 1 (st3 :conns)) "the connection went back to the pool and was reused")
  (assert (deep= @[1 1 1] (map |($ :conn) (fake/log st3)))
          "every statement ran on that same connection"))

# -- transactions --------------------------------------------------------

(def [p4 st4] (setup))
(with-db p4
  (assert (not (db/in-transaction?)) "no transaction outside with-tx")
  (def result
    (db/with-tx
      (assert (db/in-transaction?) "inside with-tx")
      (db/execute! {:insert "users" :values {:email "a"}})
      :committed))
  (assert (= :committed result) "with-tx returns the body value")
  (assert (deep= @["BEGIN" `INSERT INTO "users" ("email") VALUES (?)` "COMMIT"]
                 (fake/sqls st4))
          "begin, work, commit"))

# a panic rolls back and propagates
(def [p5 st5] (setup))
(def [ok err]
  (protect (with-db p5
             (db/with-tx (error "boom")))))
(assert (not ok) "the error leaves with-tx")
(assert (= "boom" err) "and keeps its value")
(assert (deep= @["BEGIN" "ROLLBACK"] (fake/sqls st5)) "the transaction rolled back")

# rollback! is a deliberate, quiet abort
(def [p6 st6] (setup))
(with-db p6
  (assert (nil? (db/with-tx
                  (db/execute! {:insert "users" :values {:email "a"}})
                  (db/rollback!)
                  :never))
          "rollback! ends the scope with nil"))
(assert (= "ROLLBACK" (last (fake/sqls st6))) "and rolls back")

# -- nesting is savepoints, not a silent merge ---------------------------

(def [p7 st7] (setup))
(with-db p7
  (db/with-tx
    (db/execute! {:insert "users" :values {:email "outer"}})
    (protect (db/with-tx
               (db/execute! {:insert "users" :values {:email "inner"}})
               (error "inner failed")))
    (db/execute! {:insert "users" :values {:email "after"}})))
(def sqls (fake/sqls st7))
(assert (= "BEGIN" (first sqls)) "one BEGIN for the outer scope")
(assert (= 1 (length (filter |(= "BEGIN" $) sqls))) "the inner scope does not BEGIN again")
(assert (string/has-prefix? "SAVEPOINT void_sp_1" (in sqls 2)) "the inner scope takes a savepoint")
(assert (string/has-prefix? "ROLLBACK TO SAVEPOINT void_sp_1" (in sqls 4))
        "the inner failure rolls back only to the savepoint")
(assert (= "COMMIT" (last sqls)) "the outer scope still commits")

# -- a failed commit poisons the connection ------------------------------

(def [p8 st8]
  (setup {:responder (fn [sql _]
                       (when (= "COMMIT" sql) (error "connection reset")))}))
(def [ok8 err8] (protect (with-db p8 (db/with-tx :work))))
(assert (not ok8) "a failed commit surfaces")
(assert (string/find "transaction commit failed" err8) "with context")
(assert (= 1 (st8 :closed)) "the connection is closed, not handed back")
(assert (zero? ((pool/stats p8) :created)) "and its pool slot is freed")

# -- metrics -------------------------------------------------------------

(def [p9 _] (setup))
(with-db p9
  (db/query {:select [:*] :from "users"})
  (db/query {:select [:*] :from "users"}))
(def s9 (pool/stats p9))
(assert (= 2 (s9 :queries)) "queries are counted")
(assert (>= (s9 :query-us) 0) "query time is measured")

# -- H1: a fiber cancelled mid-query never pools the connection dirty ----

(def gate (ev/chan 1))
(def [pc stc] (setup {:gate gate}))
(def csup (ev/chan 1))
# the query parks inside the driver (on the gate) with the connection
# checked out and mid-protocol
(def qf (ev/go (fn [] (with-db pc (db/query {:select [:*] :from "users"})))
               nil csup))
(ev/sleep 0.02)
(assert (= 1 ((pool/stats pc) :in-use)) "the query holds its connection")
(ev/cancel qf :timed-out)
(ev/take csup)
(def sc (pool/stats pc))
(assert (= 1 (stc :closed)) "the cancelled connection was closed, not returned")
(assert (zero? (sc :created)) "and its pool slot was freed")
(assert (zero? (sc :idle)) "nothing dirty was left idle")
(assert (zero? (sc :in-use)) "and nothing was left in use")
# the pool is fully usable afterwards: a fresh checkout opens a new
# connection and completes
(ev/give gate :go)
(with-db pc
  (assert (empty? (db/query {:select [:*] :from "users"}))
          "the pool serves a fresh query after the cancel"))

# -- H5: ev/go inherits the db dyns; db/detached severs them -------------

(def [pd _] (setup))
(with-db pd
  (db/with-conn
    # a child fiber that inherits the parent's connection dyn is refused
    # rather than allowed to race the parent on one connection
    (def bad-sup (ev/chan 1))
    (ev/go (fn [] (db/query {:select [:*] :from "shared"})) nil bad-sup)
    (def [bad-status _] (ev/take bad-sup))
    (assert (= :error bad-status)
            "a child sharing the inherited connection is refused")
    # db/detached gives the child its own checkout, which succeeds
    (def ok-sup (ev/chan 1))
    (ev/go (fn [] (db/detached (db/query {:select [:*] :from "own"}))) nil ok-sup)
    (def [ok-status _] (ev/take ok-sup))
    (assert (= :ok ok-status)
            "a detached child checks out a connection of its own")))

(print "state-test: ok")
