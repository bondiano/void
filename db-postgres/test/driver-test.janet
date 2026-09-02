(import ../test-support/paths)
(import ../test-support/server)
(import void/core/log :as log)
(import void/db :as db)
(import void/db/pool :as pool)
(import void/db/state :as state)
(import void/db-postgres/conn :as conn)
(import void/db-postgres/driver :as postgres)
(import void/db-postgres/libpq :as libpq)

(log/set-level! "void.db" :error)
# the cancel test drives a query to its error path on purpose
(log/set-level! "void.db.query" :fatal)

# Everything here needs a real backend: this is the file that says the
# driver actually drives Postgres, as opposed to building the right
# strings (test/config-test) or the right values (test/types-test).

(if-not (server/available?)
  (do (server/skip "db-postgres driver")
      (os/exit 0)))

(libpq/load!)
(def cfg (server/config {:application-name "void-driver-test"}))
(def drv (db/normalize-driver (postgres/from-config cfg)))

(defn- exec [h sql &opt params]
  ((drv :execute) h sql (or params []) {:kind :write}))

(def h ((drv :connect)))
(defer ((drv :close) h)

  # -- statements --------------------------------------------------------

  (assert (deep= @[@{:n 1}] (get (exec h "SELECT 1 AS n") :rows))
          "a row is a table with keyword column keys — the contract's shape")
  (assert (= 42 (get-in (exec h "SELECT $1::int + $2::int AS n" [40 2]) [:rows 0 :n]))
          "parameters are sent out of band, as $1/$2")
  (assert (empty? (get-in (exec h "SELECT $1::text AS t" [nil]) [:rows 0]))
          "a NULL column is absent from the row, which reads the same through `get`")

  (assert (= 3 (get (exec h "SELECT generate_series(1,3) AS i") :count))
          "a select counts its rows")

  (def table (string "void_drv_" (os/time)))
  (defer (exec h (string "DROP TABLE IF EXISTS " table))
    (exec h (string "CREATE TABLE " table
                    " (id serial primary key, name text UNIQUE, n int DEFAULT 7)"))

    (def inserted (exec h (string "INSERT INTO " table " (name) VALUES ($1) RETURNING *")
                        ["a"]))
    (assert (= 1 (inserted :count)) "an INSERT counts the rows it wrote")
    (assert (= 7 (get-in inserted [:rows 0 :n]))
            "and RETURNING hands the stored row back, defaults included — which is why :returning is true")

    (assert (= 1 (get (exec h (string "UPDATE " table " SET n = 8 WHERE name = $1") ["a"])
                      :count))
            "an UPDATE counts what it touched")

    # -- errors ----------------------------------------------------------

    (def [ok err] (protect (exec h (string "INSERT INTO " table " (name) VALUES ($1)") ["a"])))
    (assert (not ok) "a constraint violation is an error")
    (assert (= "23505" (conn/sqlstate err))
            "carrying the SQLSTATE a caller branches on, not just a message")
    (assert (= "ERROR" (get err :severity)))
    (assert (= table (get err :table)) "the table it happened in")
    (assert (string/find "_name_key" (get err :constraint))
            "and the constraint, which is what turns it into a message for a form field")
    (assert (string/find "23505" (get err :message))
            "the message reads correctly on its own too")

    (assert (= 1 (get-in (exec h (string "SELECT count(*) AS n FROM " table)) [:rows 0 :n]))
            "and the connection is usable straight afterwards")

    # -- prepared statements ---------------------------------------------

    (def stmt ((drv :prepare) h (string "SELECT n FROM " table " WHERE name = $1")))
    (assert (string? stmt) "prepare hands back a statement name")
    (assert (= 8 (get-in ((drv :execute-prepared) h stmt ["a"] {}) [:rows 0 :n])))
    (assert (= 8 (get-in ((drv :execute-prepared) h stmt ["a"] {}) [:rows 0 :n]))
            "reusable, which is the point of the pool caching the name")

    # the recovery that makes a cached name survive a session it no
    # longer belongs to
    (exec h "DEALLOCATE ALL")
    (assert (= 8 (get-in ((drv :execute-prepared) h stmt ["a"] {}) [:rows 0 :n]))
            "a name the session forgot is prepared again from the catalogue and retried")

    # -- transactions ------------------------------------------------------

    ((drv :begin) h)
    (exec h (string "INSERT INTO " table " (name) VALUES ('rolled-back')"))
    ((drv :rollback) h)
    (assert (= 1 (get-in (exec h (string "SELECT count(*) AS n FROM " table)) [:rows 0 :n]))
            "a rollback rolls back")

    ((drv :begin) h)
    (exec h (string "INSERT INTO " table " (name) VALUES ('committed')"))
    ((drv :commit) h)
    (assert (= 2 (get-in (exec h (string "SELECT count(*) AS n FROM " table)) [:rows 0 :n]))
            "and a commit commits")

    ((drv :begin) h {:level :repeatable-read :read-only true})
    (assert (= "repeatable read"
               (get-in (exec h "SELECT current_setting('transaction_isolation') AS v")
                       [:rows 0 :v]))
            "an isolation level asked for is an isolation level the server is in")
    (def [rok] (protect (exec h (string "INSERT INTO " table " (name) VALUES ('nope')"))))
    (assert (not rok) "and READ ONLY means it")
    ((drv :rollback) h)

    ((drv :begin) h)
    ((drv :savepoint) h "sp1")
    (exec h (string "INSERT INTO " table " (name) VALUES ('sp')"))
    ((drv :rollback-to-savepoint) h "sp1")
    (exec h (string "INSERT INTO " table " (name) VALUES ('after-sp')"))
    ((drv :commit) h)
    (assert (= 3 (get-in (exec h (string "SELECT count(*) AS n FROM " table)) [:rows 0 :n]))
            "a savepoint rolls back its own part and nothing else")

    # -- streaming ---------------------------------------------------------

    (var seen @[])
    (def n ((drv :stream) h "SELECT generate_series(1,5) AS i" []
            (fn [row] (array/push seen (row :i)))))
    (assert (= 5 n) "single-row mode reports how many rows it saw")
    (assert (deep= @[1 2 3 4 5] seen) "and hands them over one at a time, in order")
    (assert (= 3 (get (exec h "SELECT generate_series(1,3) AS i") :count))
            "leaving the connection to behave normally afterwards")

    # -- pipeline ----------------------------------------------------------

    (when (libpq/supports? :pipeline)
      (def results ((drv :pipelined) h [["SELECT 1 AS a" []]
                                        ["SELECT $1::int AS b" [7]]
                                        [(string "SELECT count(*) AS c FROM " table) []]]))
      (assert (= 3 (length results)) "one result per statement")
      (assert (= 1 (get-in results [0 :rows 0 :a])) "in the order they were sent")
      (assert (= 7 (get-in results [1 :rows 0 :b])))
      (assert (= 3 (get-in results [2 :rows 0 :c])))

      (def [pok perr]
        (protect ((drv :pipelined) h [["SELECT 1 AS a" []]
                                      ["SELECT undefined_column" []]
                                      ["SELECT 3 AS c" []]])))
      (assert (not pok) "a failed statement fails the pipeline")
      (assert (= 1 (get perr :index)) "naming which one it was")
      (assert (= 1 (length (get perr :results)))
              "and handing back what was collected before it")
      (assert (= 1 (get-in (exec h "SELECT 1 AS n") [:rows 0 :n]))
              "the connection is drained and usable again"))

    # -- reconnect ---------------------------------------------------------

    # the reason :connect hands out a handle rather than a PGconn: the
    # pool neither pings nor discards, so a connection killed under it
    # would otherwise be handed out forever
    (def before ((drv :connection-info) h))
    (def victim (before :backend-pid))
    (def killer ((drv :connect)))
    (defer ((drv :close) killer)
      (exec killer "SELECT pg_terminate_backend($1)" [victim]))
    # the first statement on the dead connection may or may not notice
    # before libpq does; either way the one after it works
    (protect (exec h "SELECT 1"))
    (assert (= 1 (get-in (exec h "SELECT 1 AS n") [:rows 0 :n]))
            "a terminated backend is replaced rather than handed out again")
    (def after ((drv :connection-info) h))
    (assert (not= victim (after :backend-pid)) "by a different backend")
    (assert (= (inc (before :generation)) (after :generation))
            "and the handle counts the replacement, so it is visible rather than silent")

    (assert (= 8 (get-in ((drv :execute-prepared) h stmt ["a"] {}) [:rows 0 :n]))
            "a statement prepared on the connection that died still works on its replacement")

    # a transaction is never silently reconnected: it would split the
    # caller's work in two and report success
    ((drv :begin) h)
    (def in-tx-pid (get ((drv :connection-info) h) :backend-pid))
    (def killer2 ((drv :connect)))
    (defer ((drv :close) killer2)
      (exec killer2 "SELECT pg_terminate_backend($1)" [in-tx-pid]))
    (protect (exec h "SELECT 1"))
    (def [tok terr] (protect (exec h "SELECT 1")))
    (assert (not tok) "a connection lost inside a transaction is an error, not a reconnect")
    (assert (string/find "transaction" (if (string? terr) terr (get terr :message "")))
            "that says the transaction is gone")
    ((drv :rollback) h)
    (assert (= 1 (get-in (exec h "SELECT 1 AS n") [:rows 0 :n]))
            "and ROLLBACK on the corpse succeeds, so the handle is usable again"))

  # -- concurrency ---------------------------------------------------------

  # the claim of ADR-0011, measured: N queries that each sleep on the
  # server, from one OS thread, take one sleep and not N
  (def sleepers 4)
  (def nap 0.4)
  (def handles (seq [_ :range [0 sleepers]] ((drv :connect))))
  (defer (each x handles ((drv :close) x))
    (var ticks 0)
    (def ticker (ev/go (fn [] (repeat 20 (ev/sleep 0.02) (++ ticks)))))
    (def t0 (os/clock :monotonic))
    (def done @[])
    (each x handles
      (ev/go (fn [] (exec x "SELECT pg_sleep($1)" [nap]) (array/push done x))))
    (while (< (length done) sleepers) (ev/sleep 0.01))
    (def elapsed (- (os/clock :monotonic) t0))
    (assert (< elapsed (* 2 nap))
            (string/format "%d queries ran concurrently on one thread (%.3fs, one sleep is %.1fs)"
                           sleepers elapsed nap))
    (assert (>= ticks 10)
            (string "and the ev loop stayed free the whole time, got " ticks " ticks")))

  # -- cancellation --------------------------------------------------------

  # a fiber parked on a long query, cancelled from another one: the
  # request goes over a socket of its own, which is what makes it safe
  (def slow ((drv :connect)))
  (defer ((drv :close) slow)
    (var outcome :still-running)
    (ev/go (fn []
             (def [ok err] (protect (exec slow "SELECT pg_sleep(30)")))
             (set outcome (if ok :finished (conn/sqlstate err)))))
    (ev/sleep 0.15)
    ((drv :cancel!) slow)
    (def t0 (os/clock :monotonic))
    (while (and (= :still-running outcome)
                (< (- (os/clock :monotonic) t0) 5))
      (ev/sleep 0.02))
    (assert (= "57014" outcome)
            (string/format "the cancelled query came back as query_canceled, got %q" outcome))
    (assert (= 1 (get-in (exec slow "SELECT 1 AS n") [:rows 0 :n]))
            "and the connection survives its own cancellation")))

# -- through the pool ------------------------------------------------------

# the same driver under void/db: the kernel's transactions, the
# prepared-statement cache and the entity layer's RETURNING path all
# run through the contract rather than through this file's `exec`

(def p (pool/make drv {:size 3 :checkout-timeout 5}))
(defer (pool/close-all! p)
  (with-dyns [state/pool-dyn p]
    (def table (string "void_pool_" (os/time)))
    (db/execute-sql (string "CREATE TABLE " table " (id serial primary key, name text)")
                    [] {:kind :write :prepared false})
    (defer (db/execute-sql (string "DROP TABLE IF EXISTS " table) []
                           {:kind :write :prepared false})

      (db/with-tx
        (db/execute-sql (string "INSERT INTO " table " (name) VALUES ($1)") ["kept"])
        (db/with-tx
          (db/execute-sql (string "INSERT INTO " table " (name) VALUES ($1)") ["dropped"])
          (db/rollback!)))
      (assert (deep= @["kept"]
                     (map |($ :name)
                          (db/query-sql [(string "SELECT name FROM " table " ORDER BY id") []])))
              "a nested with-tx is a savepoint: the inner one rolled back, the outer one committed")

      (def [ok] (protect (db/with-tx
                           (db/execute-sql (string "INSERT INTO " table " (name) VALUES ($1)") ["lost"])
                           (error "no"))))
      (assert (not ok))
      (assert (= 1 (db/value [(string "SELECT count(*) AS n FROM " table) []]))
              "an error rolls the transaction back and propagates")

      # every statement above went through the prepared pair, since the
      # driver has one and the kernel prefers it
      (assert (pos? (get (pool/stats p) :queries)) "the pool counted them")
      (assert (zero? (get (pool/stats p) :timeouts)) "and nothing waited past its deadline"))))

# -- reusable?: a connection left mid-protocol is discarded, not pooled --

(def rh ((drv :connect)))
(defer ((drv :close) rh)
  (exec rh "SELECT 1")
  (assert (conn/reusable? (rh :conn))
          "a completed query leaves the connection reusable")
  (def [eok] (protect (exec rh "SELECT * FROM void_no_such_table_xyz")))
  (assert (not eok) "a bad query raises")
  (assert (conn/reusable? (rh :conn))
          "its results are drained, so a query error keeps the connection reusable (no churn)")
  (def c (rh :conn))
  (def [sok] (protect (conn/stream c "SELECT generate_series(1,1000) AS i" []
                                   (fn [_] (error "boom")))))
  (assert (not sok) "a throwing stream callback surfaces")
  (assert (not (conn/reusable? c))
          "and leaves the connection mid-protocol — unusable, for the pool to discard (H6)"))

# -- a query cancelled mid-flight is discarded by the pool (H1) ----------

(def p2 (pool/make drv {:size 1 :checkout-timeout 5}))
(defer (pool/close-all! p2)
  (with-dyns [state/pool-dyn p2]
    (def qsup (ev/chan 1))
    (def qf (ev/go (fn [] (with-dyns [state/pool-dyn p2]
                            (db/query-sql ["SELECT pg_sleep(5)" []])))
                   nil qsup))
    (ev/sleep 0.2)
    (assert (= 1 (get (pool/stats p2) :in-use)) "the sleeping query holds the connection")
    (ev/cancel qf :timed-out)
    (ev/take qsup)
    (def s (pool/stats p2))
    (assert (zero? (s :created))
            "the connection cancelled mid-query was discarded, freeing its slot")
    (assert (zero? (s :in-use)) "and nothing was left in use")
    (assert (= 1 (db/value ["SELECT 1 AS n" []]))
            "the pool serves a fresh query on a new connection")))

(print "db-postgres driver: ok")
