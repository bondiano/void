(import ../test-support/paths)
(import void/db-sqlite/driver :as sqlite)
(import void/db/driver :as contract)
(import sqlite3)

# work in a throwaway directory; jpm test runs with cwd = db-sqlite/
(def sandbox (string (os/cwd) "/.tmp-driver-test-" (os/time)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(defer (rimraf sandbox)

  # -- paths -------------------------------------------------------------

  (assert (sqlite/memory-path? ":memory:") "the classic spelling")
  (assert (sqlite/memory-path? "") "the anonymous temporary database")
  (assert (not (sqlite/memory-path? "db/app.sqlite3")) "a file is a file")

  # a URI is a filename to this binding, and a database silently
  # written to a file called "file:x?mode=memory&cache=shared" is the
  # kind of surprise worth an error
  (def [uok uerr] (protect (sqlite/open "file:x?mode=memory&cache=shared")))
  (assert (not uok) "a URI path is refused")
  (assert (string/find "SQLITE_USE_URI" uerr) "with the reason")

  (sqlite/ensure-directory! (string sandbox "/nested/deeper/app.sqlite3"))
  (assert (= :directory (os/stat (string sandbox "/nested/deeper") :mode))
          "the parent directory of a database file is created for it")

  # -- pragmas -----------------------------------------------------------

  (assert (= "PRAGMA foreign_keys = ON" (sqlite/pragma-sql :foreign-keys true))
          "booleans render as ON/OFF, kebab as snake")
  (assert (= "PRAGMA foreign_keys = OFF" (sqlite/pragma-sql :foreign-keys false)))
  (assert (= "PRAGMA busy_timeout = 5000" (sqlite/pragma-sql :busy-timeout 5000)))
  (assert (= "PRAGMA journal_mode = WAL" (sqlite/pragma-sql :journal-mode :wal))
          "keyword values are spelled out in upper case")
  (each bad [["journal_mode; DROP TABLE users" :wal]
             [:journal-mode "wal; DROP TABLE users"]
             [:cache-size [1 2]]]
    (assert (not (first (protect (sqlite/pragma-sql ;bad))))
            (string/format "%q is refused, not rendered" bad)))

  # -- a connection with its pragmas -------------------------------------

  (def file (string sandbox "/app.sqlite3"))
  (def conn (sqlite/open file [[:busy_timeout 1000] [:foreign_keys true]
                               [:journal_mode :wal]]))
  (assert (= "wal" (get (first (sqlite3/eval conn "PRAGMA journal_mode")) :journal_mode))
          "the pragmas reached the connection")
  (assert (= 1 (get (first (sqlite3/eval conn "PRAGMA foreign_keys")) :foreign_keys)))

  (def [ok err] (protect (sqlite/open (string sandbox "/nope/app.sqlite3"))))
  (assert (not ok) "an unopenable path fails")
  (assert (string/find "nope/app.sqlite3" err) "and the error names it")

  (def [pok perr] (protect (sqlite/open file [[:encoding :foo]])))
  (assert (not pok) "a pragma sqlite rejects fails the connection")
  (assert (string/find "PRAGMA encoding = FOO" perr)
          "naming the statement that failed")

  # sqlite itself ignores a pragma it does not know, and an unknown
  # value for one it does — a typo in [:db-sqlite :pragmas] is silent,
  # which is worth knowing when a setting seems not to apply
  (def lenient (sqlite/open file [[:nonsense_pragma 1] [:journal-mode :not-a-mode]]))
  (assert (= "wal" (get (first (sqlite3/eval lenient "PRAGMA journal_mode")) :journal_mode))
          "the unknown journal mode was ignored, not applied")
  (sqlite3/close lenient)

  # -- version and RETURNING ---------------------------------------------

  (def ver (sqlite/version conn))
  (assert (string/has-prefix? "3." ver) (string "a version string, got " ver))
  (assert (sqlite/supports-returning? "3.35.0") "RETURNING landed in 3.35")
  (assert (sqlite/supports-returning? "3.53.3"))
  (assert (sqlite/supports-returning? "4.0.0"))
  (assert (not (sqlite/supports-returning? "3.34.1")) "and not before")
  (assert (not (sqlite/supports-returning? "0")) "an unreadable version is a no")

  (sqlite3/close conn)

  # -- the contract ------------------------------------------------------

  (def drv (contract/normalize (sqlite/make {:path file :returning true})))
  (assert (= :sqlite (drv :dialect)) "the builder dialect")
  (assert (not (contract/supports-prepared? drv))
          "the janet binding has no prepare/step — the kernel falls back to :execute")

  (def c ((drv :connect)))
  (defer ((drv :close) c)
    (defn exec [sql &opt params kind]
      ((drv :execute) c sql (or params []) {:kind (or kind :write)}))
    (defn rows [sql &opt params]
      (((drv :execute) c sql (or params []) {:kind :select}) :rows))

    (exec "CREATE TABLE users (id integer primary key, email text not null unique, admin int, note text)")

    # -- writes report the affected count, selects the row count --------
    (def ins (exec "INSERT INTO users (email, admin) VALUES (?, ?)" ["a@b.c" true]))
    (assert (= 1 (ins :count)) "one row inserted")
    (assert (= 1 ((drv :insert-id) c ins)) "and :insert-id knows its rowid")

    (exec "INSERT INTO users (email, admin) VALUES (?, ?)" ["d@e.f" false])
    (assert (= 2 ((exec "UPDATE users SET note = ?" ["hi"]) :count))
            "an UPDATE counts the rows it touched")
    (assert (= 2 (length (rows "SELECT * FROM users"))) "a SELECT counts its rows")
    (assert (= 2 ((first (rows "SELECT count(*) AS n FROM users")) :n)))

    # -- parameter binding -----------------------------------------------
    (def [u1 u2] (rows "SELECT * FROM users ORDER BY id"))
    (assert (= 1 (u1 :admin)) "a boolean binds as 1/0")
    (assert (= 0 (u2 :admin)))
    (assert (= "a@b.c" (u1 :email)) "and text as text")

    (exec "INSERT INTO users (email, note) VALUES (?, ?)" ["g@h.i" nil])
    (def u3 (first (rows "SELECT * FROM users WHERE email = ?" ["g@h.i"])))
    (assert (nil? (get u3 :note)) "a NULL column reads back as nil")
    (assert (not (in u3 :note))
            "— by being absent from the row, since a janet table cannot hold nil")

    (def [bok berr] (protect (exec "INSERT INTO users (email) VALUES (?)" [{:a 1}])))
    (assert (not bok) "an unbindable parameter fails")
    (assert (string/find "parameter 1" berr) "naming which one")

    # -- transactions ------------------------------------------------------
    ((drv :begin) c)
    (exec "INSERT INTO users (email) VALUES (?)" ["tx@rollback"])
    ((drv :rollback) c)
    (assert (empty? (rows "SELECT * FROM users WHERE email = ?" ["tx@rollback"]))
            "a rollback undoes the write")

    ((drv :begin) c :exclusive)
    (exec "INSERT INTO users (email) VALUES (?)" ["tx@commit"])
    ((drv :commit) c)
    (assert (= 1 (length (rows "SELECT * FROM users WHERE email = ?" ["tx@commit"])))
            "a commit keeps it, :isolation and all")

    (assert (not (first (protect ((drv :begin) c :snapshot))))
            "an isolation level sqlite has no BEGIN for is refused")

    # -- savepoints --------------------------------------------------------
    ((drv :begin) c)
    (exec "INSERT INTO users (email) VALUES (?)" ["outer@tx"])
    ((drv :savepoint) c "void_sp_1")
    (exec "INSERT INTO users (email) VALUES (?)" ["inner@tx"])
    ((drv :rollback-to-savepoint) c "void_sp_1")
    ((drv :release-savepoint) c "void_sp_1")
    ((drv :commit) c)
    (assert (= 1 (length (rows "SELECT * FROM users WHERE email = ?" ["outer@tx"])))
            "the outer write survived")
    (assert (empty? (rows "SELECT * FROM users WHERE email = ?" ["inner@tx"]))
            "the savepoint took the inner one back")

    # -- RETURNING ---------------------------------------------------------
    (def ret (exec "INSERT INTO users (email) VALUES (?) RETURNING *" ["r@s.t"]))
    (assert (= "r@s.t" ((first (ret :rows)) :email)) "RETURNING hands the row back")
    (assert (= 1 (ret :count)) "and the count still counts")

    (assert ((drv :ping) c) "a live connection pings"))

  # -- an in-memory database is one connection, not a pool of them --------

  # what sqlite really does without :shared: every connection is its
  # own empty database, which is why the plugin refuses a wider pool
  (def naive (contract/normalize (sqlite/make {:path ":memory:"})))
  (def n1 ((naive :connect)))
  (def n2 ((naive :connect)))
  (defer (do ((naive :close) n1) ((naive :close) n2))
    (assert (not= n1 n2) "two connect calls, two handles")
    (assert (= "" (sqlite/file-of n1)) "and nothing on disk behind them")
    ((naive :execute) n1 "CREATE TABLE t (n int)" [] {:kind :write})
    (assert (not (first (protect ((naive :execute) n2 "SELECT * FROM t" []
                                                  {:kind :select}))))
            "the second one cannot see the first one's schema"))

  # :shared is the answer the component uses: one connection, handed
  # to every checkout, and :close leaves it to whoever owns it
  (def keeper (sqlite/open ":memory:"))
  (def mem (contract/normalize (sqlite/make {:path ":memory:" :shared keeper})))
  (defer (sqlite/close-connection keeper)
    (def a ((mem :connect)))
    (def b ((mem :connect)))
    (assert (= a b keeper) "every checkout gets the one connection")
    ((mem :execute) a "CREATE TABLE t (n int)" [] {:kind :write})
    ((mem :execute) a "INSERT INTO t VALUES (?)" [7] {:kind :write})
    ((mem :close) b)
    (def seen (((mem :execute) a "SELECT * FROM t" [] {:kind :select}) :rows))
    (assert (= 7 ((first seen) :n))
            "and a checkin does not close the database out from under it")))

# -- the cooperative busy wait -------------------------------------------
#
# sqlite's own busy handler waits *inside* the C call and blocks the
# whole event loop for as long as it waits — several writers on one
# file turn into loop lag measured in seconds (wave 7 found it by
# clicking a register button). The driver waits in janet instead:
# retry + ev/sleep, so every other fiber keeps running. The ticker is
# the assertion that matters.

(do
  (def dir (string (or (os/getenv "TMPDIR") "/tmp") "/void-sqlite-busy-" (os/time)))
  (os/mkdir dir)
  (def path (string dir "/busy.sqlite3"))
  (def drv (contract/normalize (sqlite/make {:path path :busy-timeout 3000})))
  (def holder ((drv :connect)))
  (def waiter ((drv :connect)))
  (defer (do ((drv :close) holder) ((drv :close) waiter)
             (each f (os/dir dir) (os/rm (string dir "/" f)))
             (os/rmdir dir))
    ((drv :execute) holder "CREATE TABLE t (n int)" [] {:kind :write})
    ((drv :begin) holder)                       # the write lock is taken
    ((drv :execute) holder "INSERT INTO t VALUES (1)" [] {:kind :write})

    (var ticks 0)
    (def ticker (ev/go (fn [] (repeat 40 (ev/sleep 0.01) (++ ticks)))))

    (def released (ev/chan 1))
    (ev/go (fn release-later []
             (ev/sleep 0.15)
             ((drv :commit) holder)
             (ev/give released true)))

    # this BEGIN meets SQLITE_BUSY and waits cooperatively until the
    # holder commits — well inside the 3 s budget
    (def before (os/clock :monotonic))
    ((drv :begin) waiter)
    ((drv :execute) waiter "INSERT INTO t VALUES (2)" [] {:kind :write})
    ((drv :commit) waiter)
    (def waited (- (os/clock :monotonic) before))

    (ev/take released)
    (assert (>= waited 0.1) "the second writer really waited for the lock")
    (assert (>= ticks 8)
            (string/format "the loop kept running while it waited (ticks=%d)" ticks))
    (def seen (((drv :execute) waiter "SELECT count(*) AS c FROM t" []
                               {:kind :select}) :rows))
    (assert (= 2 ((first seen) :c)) "both writes landed, in lock order")

    # past the budget the busy error propagates, and quickly
    (def drv0 (contract/normalize (sqlite/make {:path path :busy-timeout 50})))
    (def h ((drv0 :connect)))
    (def w ((drv0 :connect)))
    (defer (do ((drv0 :close) h) ((drv0 :close) w))
      ((drv0 :begin) h)
      ((drv0 :execute) h "INSERT INTO t VALUES (3)" [] {:kind :write})
      (def [ok e] (protect ((drv0 :begin) w)))
      ((drv0 :rollback) h)
      (assert (not ok) "a budget of 50 ms is not forever")
      (assert (string/find "locked" (get e :message)) "and the error names the lock")
      (assert (= "55P03" (get e :sqlstate)) "with the SQLSTATE the kernel classifies as a timeout"))))

(print "driver-test: ok")
