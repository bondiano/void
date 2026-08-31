(import ../test-support/paths)
(import ../test-support/server)
(import void/core/log :as log)
(import void/db :as db)
(import void/db-mysql/conn :as conn)
(import void/db-mysql/driver :as mysql)

(log/set-level! "void.db" :error)

# Everything here needs a real backend: this is the file that says the
# driver actually drives MySQL, as opposed to building the right specs
# (test/config-test) or the right literals (test/types-test).

(if-not (server/available?)
  (do (server/skip "db-mysql driver")
      (os/exit 0)))

(def cfg (server/config))
(def drv (db/normalize-driver (mysql/from-config cfg)))

(defn- exec [h sql &opt params]
  ((drv :execute) h sql (or params []) {:kind :write}))

(def h ((drv :connect)))
(defer ((drv :close) h)

  # -- the thread is real, and it is off the loop ------------------------
  #
  # The claim ADR-0033 is built on, asserted rather than described: a
  # query blocks the fiber that issued it and nothing else. Without the
  # worker thread this is where the ticker would stop.

  (var ticks 0)
  (var ticking true)
  # a flag rather than `ev/cancel`: cancelling a parked fiber prints
  # its stack trace, and a passing suite should say nothing
  (def ticker (ev/go (fn ticker [] (while ticking (ev/sleep 0.002) (++ ticks)))))
  (def t0 (os/clock :monotonic))
  (exec h "SELECT SLEEP(0.4) AS s")
  (def elapsed (- (os/clock :monotonic) t0))
  (assert (>= elapsed 0.35) "the query really did take that long")
  (assert (> ticks 20)
          (string/format
            (string "the ev loop kept running during a %.2fs query (%d ticks) "
                    "— this is the whole of ADR-0033")
            elapsed ticks))
  (set ticking false)

  # and two connections are two threads, so two queries overlap
  (def h2 ((drv :connect)))
  (defer ((drv :close) h2)
    (def t1 (os/clock :monotonic))
    (def a (ev/go (fn [] (exec h "SELECT SLEEP(0.4) AS a"))))
    (def b (ev/go (fn [] (exec h2 "SELECT SLEEP(0.4) AS b"))))
    (while (or (not= :dead (fiber/status a)) (not= :dead (fiber/status b)))
      (ev/sleep 0.01))
    (assert (< (- (os/clock :monotonic) t1) 0.7)
            "two 0.4s queries on two connections take 0.4s, not 0.8s"))

  # -- statements --------------------------------------------------------

  (assert (deep= @[@{:n 1}] (get (exec h "SELECT 1 AS n") :rows))
          "a row is a table with keyword column keys — the contract's shape")
  (assert (= 42 (get-in (exec h "SELECT ? + ? AS n" [40 2]) [:rows 0 :n]))
          "parameters are rendered as literals, and arithmetic still works")
  (assert (empty? (get-in (exec h "SELECT ? AS t" [nil]) [:rows 0]))
          "a NULL column is absent from the row, which reads the same through `get`")

  (assert (= 3 (get (exec h "SELECT 1 AS i UNION SELECT 2 UNION SELECT 3") :count))
          "a select counts its rows")

  # the one that matters: a value is a value, never syntax
  (def injected "'; DROP TABLE nonexistent; -- ")
  (assert (= injected (get-in (exec h "SELECT ? AS v" [injected]) [:rows 0 :v]))
          "a statement-shaped parameter comes back as the string it was")

  (assert (= "o'brien" (get-in (exec h "SELECT ? AS v" ["o'brien"]) [:rows 0 :v]))
          "and so does a quote, through the connection's own escaper")
  (assert (= "é中" (get-in (exec h "SELECT ? AS v" ["é中"]) [:rows 0 :v]))
          "utf8mb4 by default, so multi-byte text survives the round trip")

  # -- a table -----------------------------------------------------------

  (def table (server/table-name "drv"))
  (defer (exec h (string "DROP TABLE IF EXISTS `" table "`"))
    (exec h (string "CREATE TABLE `" table "` ("
                    "id int auto_increment PRIMARY KEY,"
                    "name varchar(64) UNIQUE,"
                    "n int DEFAULT 7,"
                    "live boolean DEFAULT TRUE,"
                    "note text,"
                    "amount decimal(12,2) DEFAULT 0,"
                    "big bigint DEFAULT 0,"
                    "raw varbinary(16)) ENGINE=InnoDB"))

    (def inserted (exec h (string "INSERT INTO `" table "` (name) VALUES (?)") ["a"]))
    (assert (= 1 (inserted :count)) "an INSERT counts the rows it wrote")
    (assert (pos? (inserted :insert-id))
            "and carries its insert id, which is how the entity layer finds the row")
    (assert (= (inserted :insert-id) ((drv :insert-id) h inserted))
            (string "the driver's :insert-id reads it off that same result: "
                    "mysql_insert_id is per connection and per statement, and "
                    "asking for it later would get somebody else's row"))

    (def row (first (get (exec h (string "SELECT * FROM `" table "` WHERE id = ?")
                              [(inserted :insert-id)])
                         :rows)))
    (assert (= "a" (row :name)))
    (assert (= 7 (row :n)) "a column default is the server's, and it applied")
    (assert (= true (row :live)) "a BOOLEAN is TINYINT(1), and comes back a boolean")
    (assert (= "0.00" (row :amount)) "DECIMAL stays exact, as a string")
    (assert (nil? (row :note)) "an unset nullable column is absent")

    # the reason CLIENT_FOUND_ROWS is set (see worker/connect!)
    (assert (= 1 (get (exec h (string "UPDATE `" table "` SET n = 8 WHERE name = ?") ["a"])
                      :count))
            "an UPDATE counts what it touched")
    (assert (= 1 (get (exec h (string "UPDATE `" table "` SET n = 8 WHERE name = ?") ["a"])
                      :count))
            (string "and counts the rows it MATCHED, not the rows whose values "
                    "changed — without CLIENT_FOUND_ROWS this second, identical "
                    "UPDATE would answer 0, and 0 is how every caller spells "
                    "\"not found\""))

    (assert (= 0 (get (exec h (string "UPDATE `" table "` SET n = 9 WHERE name = ?") ["nobody"])
                      :count))
            "while a row that really is not there is still 0")

    # binary in, binary out
    (exec h (string "UPDATE `" table "` SET raw = ? WHERE name = ?")
          [(buffer "\xff\x00\xfe") "a"])
    (def back (get-in (exec h (string "SELECT raw FROM `" table "` WHERE name = ?") ["a"])
                      [:rows 0 :raw]))
    (assert (= 3 (length back)) "a NUL inside a blob is a byte, not a terminator")
    (assert (= 0 (back 1)))

    # -- errors ----------------------------------------------------------

    (def [ok err] (protect (exec h (string "INSERT INTO `" table "` (name) VALUES (?)") ["a"])))
    (assert (not ok) "a unique violation is an error")
    (assert (= 1062 (conn/errno err))
            "carrying MySQL's own error number, so a caller can branch on it")
    (assert (= "23000" (conn/sqlstate err)) "and its SQLSTATE")
    (assert (string/find "Duplicate" (string err)) "and the server's own text")

    # the error names the statement with its placeholders still in it,
    # never the rendered one: a failed INSERT must not carry the value
    # it was inserting into a log or a report
    (exec h (string "INSERT INTO `" table "` (name) VALUES (?)")
          ["a-very-secret-value"])
    (def [ok2 secret-err]
      (protect (exec h (string "INSERT INTO `" table "` (name) VALUES (?)")
                     ["a-very-secret-value"])))
    (assert (not ok2) "the second one collides")
    (def info (conn/error-info secret-err))
    (assert (string/find "VALUES (?)" (get info :context ""))
            "the context is the statement as it was written")
    (assert (not (string/find "a-very-secret-value" (get info :context "")))
            (string "and the parameter is not in it — the rendered statement "
                    "would have carried every value the write was making"))
    # what the SERVER says is the server's business: ER_DUP_ENTRY quotes
    # the offending value by design, and every MySQL client shows it.
    # The driver adds nothing to that and takes nothing away
    (assert (string/find "a-very-secret-value" (string secret-err))
            "while the server's own message still says what collided")

    (assert (not (first (protect (exec h "SELECT * FROM `no_such_table_here`"))))
            "a missing table is an error and not an empty result")
    (assert (not (first (protect (exec h "SELECT 1 AS"))))
            "and so is a syntax error")

    (assert (deep= @[@{:n 1}] (get (exec h "SELECT 1 AS n") :rows))
            (string "and the connection still works afterwards — a failed "
                    "statement is not a failed connection, which is the "
                    "distinction the pool depends on"))

    # -- transactions ----------------------------------------------------

    ((drv :begin) h)
    (exec h (string "INSERT INTO `" table "` (name) VALUES (?)") ["rolled-back"])
    ((drv :rollback) h)
    (assert (zero? (get-in (exec h (string "SELECT count(*) AS c FROM `" table
                                           "` WHERE name = ?") ["rolled-back"])
                           [:rows 0 :c]))
            (string "a rolled-back INSERT left nothing behind — InnoDB, and "
                    "a real transaction"))

    ((drv :begin) h)
    (exec h (string "INSERT INTO `" table "` (name) VALUES (?)") ["committed"])
    ((drv :commit) h)
    (assert (= 1 (get-in (exec h (string "SELECT count(*) AS c FROM `" table
                                         "` WHERE name = ?") ["committed"])
                         [:rows 0 :c])))

    ((drv :begin) h {:level :serializable})
    ((drv :commit) h)

    ((drv :begin) h {:level :repeatable-read :read-only true})
    ((drv :commit) h)

    (assert (not (first (protect ((drv :begin) h :no-such-level))))
            "an isolation level that does not exist is named, not sent")

    # savepoints, which MySQL has natively
    ((drv :begin) h)
    (exec h (string "INSERT INTO `" table "` (name) VALUES (?)") ["outer"])
    ((drv :savepoint) h "sp1")
    (exec h (string "INSERT INTO `" table "` (name) VALUES (?)") ["inner"])
    ((drv :rollback-to-savepoint) h "sp1")
    ((drv :commit) h)
    (assert (= 1 (get-in (exec h (string "SELECT count(*) AS c FROM `" table
                                         "` WHERE name = ?") ["outer"])
                         [:rows 0 :c]))
            "the outer INSERT survived the savepoint rollback")
    (assert (zero? (get-in (exec h (string "SELECT count(*) AS c FROM `" table
                                           "` WHERE name = ?") ["inner"])
                           [:rows 0 :c]))
            "and the inner one did not"))

  # -- the connection knows what it is -----------------------------------

  (def info ((drv :connection-info) h))
  (assert (indexed? (info :server-version)) "the server version is [major minor patch]")
  (assert (= 3 (length (info :server-version))))
  (assert (string? (info :charset)))
  (assert (= :idle (info :transaction)))

  (assert ((drv :ping) h) "ping answers on a live connection")

  # -- one fiber at a time -----------------------------------------------
  #
  # The channels carry no request ids, so two fibers on one connection
  # would read each other's answers. The pool never does this; going
  # around it has to be an error rather than a swapped result set.

  (def slow (ev/go (fn [] (protect (exec h "SELECT SLEEP(0.3) AS s")))))
  (ev/sleep 0.05)
  (def [ok err] (protect (exec h "SELECT 1 AS n")))
  (assert (not ok) "a second fiber on the same connection is refused")
  (assert (string/find "two fibers" (string err)))
  (while (not= :dead (fiber/status slow)) (ev/sleep 0.01)))

# -- a lost connection ---------------------------------------------------
#
# The pool does not ping and only discards an entry when a transaction
# fails, so a driver whose connections die on the wire would poison it
# permanently. The handle is the fix (see ./driver's header), and this
# is it working: the server is told to kill the session, and the next
# statement runs on a replacement.

(def victim ((drv :connect)))
(defer ((drv :close) victim)
  (def killer ((drv :connect)))
  (defer ((drv :close) killer)
    (def thread-id (get ((drv :connection-info) victim) :thread-id))
    (def generation (get ((drv :connection-info) victim) :generation))
    (exec killer (string "KILL " thread-id))
    # the victim finds out when it next speaks
    (protect (exec victim "SELECT 1 AS n"))
    (def revived (exec victim "SELECT 1 AS n"))
    (assert (= 1 (get-in revived [:rows 0 :n]))
            "a killed session is replaced and the next statement runs")
    (assert (> (get ((drv :connection-info) victim) :generation) generation)
            "on a new connection, which the handle counts")
    (assert (not= thread-id (get ((drv :connection-info) victim) :thread-id))
            "and a new server-side session")))

# a lost connection inside a transaction is refused rather than papered
# over: the transaction is gone and pretending otherwise would split it
(def in-tx ((drv :connect)))
(defer ((drv :close) in-tx)
  (def killer ((drv :connect)))
  (defer ((drv :close) killer)
    ((drv :begin) in-tx)
    (exec killer (string "KILL " (get ((drv :connection-info) in-tx) :thread-id)))
    (protect (exec in-tx "SELECT 1 AS n"))
    (def [ok err] (protect (exec in-tx "SELECT 1 AS n")))
    (assert (not ok) "a connection lost inside a transaction is not replaced")
    (assert (string/find "inside a transaction" (string err)))
    # and a ROLLBACK on it succeeds, so the original error is what reaches
    # the caller instead of a rollback failure on top of it
    (assert (first (protect ((drv :rollback) in-tx)))
            "while ROLLBACK succeeds — the lost session already rolled back")))

(print "db-mysql driver-test ok")
