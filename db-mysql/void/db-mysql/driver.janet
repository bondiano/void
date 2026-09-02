### void/db-mysql/driver — the :void/db-driver contract over
### libmysqlclient (ADR-0033, SPEC.md §5.10).
###
### The contract itself is void/db/driver: a dictionary of
### :dialect/:connect/:close/:execute plus the optional keys a database
### can honour. Nothing in this file imports void/db — a driver depends
### on the *contract*, not on the kernel, and the kernel runs the value
### through `driver/normalize`.
###
### What MySQL can honour of it, and what it cannot:
###
###   transactions       yes, with real isolation levels and READ ONLY
###   savepoints         yes, natively
###   RETURNING          NO. MySQL has no such clause (MariaDB 10.5 has
###                      one, and relying on it would make the two
###                      engines different databases), so :returning is
###                      false and :insert-id is how void/db's entity
###                      layer finds the row it just wrote
###   prepared statements NO — see ADR-0033. Reaching `mysql_stmt_*`
###                      means laying out MYSQL_BIND, whose tail MySQL
###                      and MariaDB have diverged on, and a wrong
###                      struct layout is a segfault rather than an
###                      error. The pair is left off the driver and the
###                      kernel sends everything through :execute
###
### What :connect hands the pool is a HANDLE and not a connection, for
### the reason void/db-postgres gives and one more of its own. The
### shared reason: a connection dies for causes that have nothing to do
### with the statement that hit it — the server restarts, a DBA kills
### the thread, a proxy recycles the session — and void/db's pool does
### not ping, so a driver whose connections die on the wire would
### poison the pool permanently. MySQL's own is `wait_timeout`, which
### is 8 hours by default and closes an idle pooled connection without
### telling anyone; a pool at low traffic meets it every night.
###
### The handle owns the spec and opens a new connection, on a new
### worker thread, when it finds the old one gone. Silently, but never
### dangerously — the rules are void/db-postgres's, and they are the
### rules because of what each one prevents:
###
###   outside a transaction   dead connection -> reconnect, run the
###                           statement on the new one
###   inside a transaction    dead connection -> raise. The transaction
###                           is gone and pretending otherwise would
###                           silently split it in two
###   COMMIT on a dead one    raise. It did not commit
###   ROLLBACK on a dead one  succeed. A lost session has already
###                           rolled back, and this is what lets the
###                           original error reach the caller instead
###                           of a rollback failure on top of it
###
### "Inside a transaction" means one this driver was told about — the
### :begin/:commit/:rollback of the contract, which is what
### `db/with-tx` uses. A START TRANSACTION sent as raw SQL is a
### statement like any other and the driver cannot see it; that is the
### reason to open transactions through `with-tx` rather than by hand.

(import ./config :as config)
(import ./conn :as conn)

(def dialect
  "Builder dialect this driver speaks — backtick identifiers, `?`
  placeholders (registered by void/db/builder)."
  :mysql)

# -- transactions --------------------------------------------------------

(def isolation-levels
  ``The :isolation values `db/with-tx` may ask for. All four are real
  here: unlike Postgres, MySQL's InnoDB implements READ UNCOMMITTED
  as itself rather than as READ COMMITTED, and its default is
  REPEATABLE READ.``
  {:read-uncommitted "READ UNCOMMITTED"
   :read-committed "READ COMMITTED"
   :repeatable-read "REPEATABLE READ"
   :serializable "SERIALIZABLE"})

(defn begin-statements
  ``The statements that open a transaction, in order.

  Two of them, where Postgres needs one: MySQL sets the level with a
  separate `SET TRANSACTION`, which — with neither SESSION nor GLOBAL
  — applies to the very next transaction and then stops applying,
  which is exactly the scope `db/with-tx` wants.

      (db/with-tx {:isolation :serializable} ...)
      (db/with-tx {:isolation {:level :repeatable-read :read-only true}} ...)

  READ ONLY is worth asking for on a read: InnoDB skips setting up a
  transaction id for one, which is the cheapest optimization a report
  can get.``
  [isolation &opt default-level]
  (def spec (if (dictionary? isolation) isolation {:level isolation}))
  (def level (or (get spec :level) default-level))
  (def out @[])
  (when level
    (array/push out
                (string "SET TRANSACTION ISOLATION LEVEL "
                        (or (get isolation-levels level)
                            (errorf "mysql: unknown isolation level %q (known: %s)"
                                    level
                                    (string/join
                                      (map |(string/format "%q" $)
                                           (sorted (keys isolation-levels)))
                                      " "))))))
  (def start @["START TRANSACTION"])
  (when-let [ro (get spec :read-only)]
    (array/push start (if ro "READ ONLY" "READ WRITE")))
  (array/push out (string/join start " "))
  out)

# -- the handle ----------------------------------------------------------

(defn handle
  ``A pooled connection: the spec it is made of, the live worker, and
  whether a transaction is open on it.``
  [spec &opt opts]
  (default opts {})
  (def h @{:spec spec
           :conn nil
           :in-tx false
           :generation 0
           :reconnect (not= false (get opts :reconnect))})
  (put h :conn (conn/open spec))
  h)

(defn live?
  "Is this handle's connection currently usable?"
  [h]
  (and (h :conn) (conn/live? (h :conn)) true))

(defn reconnect!
  ``Replace the handle's connection — and, with it, its worker thread.
  Used by `ensure!`; exposed because a health check that finds a dead
  connection has the same repair to make.``
  [h]
  (when-let [old (h :conn)]
    (protect (conn/close old)))
  (put h :conn nil)
  (put h :conn (conn/open (h :spec)))
  (put h :generation (inc (h :generation)))
  (put h :in-tx false)
  (h :conn))

(defn- ensure!
  ``The connection to run the next statement on. A dead one is
  replaced outside a transaction and refused inside it — `what` says
  which statement was about to run, so the message names the
  casualty.``
  [h &opt what]
  (cond
    (live? h) (h :conn)

    (h :in-tx)
    (errorf (string "mysql: the connection was lost inside a transaction%s — "
                    "the transaction is gone and nothing after it ran")
            (if what (string " (" what ")") ""))

    (not (h :reconnect))
    (error "mysql: the connection is closed and [:db-mysql :reconnect] is false")

    (reconnect! h)))

(defn close-handle
  "Close a handle's connection and end its thread. Safe twice."
  [h]
  (when-let [c (h :conn)]
    (put h :conn nil)
    (conn/close c))
  nil)

# -- the driver value ----------------------------------------------------

(defn make
  ``Build the :void/db-driver value. opts:

    :spec        the plain-data connection spec (see ./config)
    :reconnect   replace a connection that died (default true; see the
                 header for exactly when that is allowed)
    :tx-mode     default isolation level for `db/with-tx` without one
                 (nil = the server's transaction_isolation)

  The kernel normalizes the result, which fills in the
  prepared-statement fallbacks this driver does not implement.``
  [&opt opts]
  (default opts {})
  (def spec (get opts :spec {}))
  (def tx-mode (get opts :tx-mode))
  (def open-opts {:reconnect (not= false (get opts :reconnect))})

  (defn run [h sql params]
    (conn/execute (ensure! h sql) sql params))

  (defn raw [h sql]
    (conn/execute (ensure! h sql) sql []))

  @{:name :mysql
    :dialect dialect
    # MySQL has no RETURNING, so the entity layer re-reads the row it
    # inserted by :insert-id below
    :returning false
    :spec spec

    :connect (fn my-connect [] (handle spec open-opts))
    :close (fn my-close [h] (close-handle h))
    :execute (fn my-execute [h sql params &opt o] (run h sql params))
    :ping (fn my-ping [h] (conn/ping (ensure! h "ping")))
    # a query abandoned mid-flight (a cancel) leaves the worker's reply
    # on the channel; such a connection must not be pooled — the kernel
    # asks this on every checkin (see void/db/state)
    :reusable? (fn my-reusable [h] (and (h :conn) (conn/reusable? (h :conn)) true))

    # mysql_insert_id, carried out of the write that produced it: it
    # is per connection and per statement, and reading it later — with
    # a second query, on whatever connection the pool hands over — is
    # the classic way to get somebody else's row
    :insert-id (fn my-insert-id [_ result] (get result :insert-id))

    :begin
    (fn my-begin [h &opt isolation]
      (def stmts (begin-statements isolation tx-mode))
      # ensure! once, before the first statement — reconnecting between
      # SET TRANSACTION and START TRANSACTION would silently drop the
      # isolation level (it applies to the next transaction on the
      # connection that ran it), so both run on the one connection or
      # neither does. A connection that dies mid-sequence fails the begin
      # loudly (the second execute raises), never opens a transaction at
      # the server's default level
      (def c (ensure! h "begin"))
      (var res nil)
      (each sql stmts (set res (conn/execute c sql [])))
      (put h :in-tx true)
      res)

    :commit
    (fn my-commit [h]
      # a lost session did not commit, and saying so is the whole
      # difference between "your write is durable" and "it is not"
      (unless (live? h)
        (put h :in-tx false)
        (error "mysql: the connection was lost before COMMIT — the transaction did not commit"))
      (def res (conn/execute (h :conn) "COMMIT" []))
      (put h :in-tx false)
      res)

    :rollback
    (fn my-rollback [h]
      (if (live? h)
        (let [res (conn/execute (h :conn) "ROLLBACK" [])]
          (put h :in-tx false)
          res)
        # nothing to roll back: the server dropped the transaction
        # when it dropped the session. Succeeding here is what lets
        # the error that killed the connection reach the caller,
        # instead of a rollback failure reported on top of it
        (do (put h :in-tx false)
            {:rows [] :count 0})))

    :savepoint
    (fn my-savepoint [h n] (raw h (string "SAVEPOINT " n)))
    :release-savepoint
    (fn my-release [h n] (raw h (string "RELEASE SAVEPOINT " n)))
    :rollback-to-savepoint
    (fn my-rollback-to [h n] (raw h (string "ROLLBACK TO SAVEPOINT " n)))

    # -- beyond the contract, for callers that ask for MySQL by name
    # -- (see ../init, which re-exports these)

    :connection-info
    (fn my-connection-info [h]
      (if (live? h)
        (merge (conn/info (h :conn))
               {:generation (h :generation)
                :transaction (if (h :in-tx) :open :idle)})
        {:generation (h :generation) :transaction :closed}))})

(defn from-config
  ``The driver for a [:db-mysql] config slice — `config/spec` plus the
  behaviour keys, in one call.``
  [cfg0]
  # `fallbacks`, not `defaults`: the behaviour keys need a value, and
  # the slice they come from may only have said it inside a URL
  (def cfg (merge config/fallbacks (or cfg0 {})))
  (make {:spec (config/spec cfg0)
         :reconnect (get cfg :reconnect)
         :tx-mode (get cfg :tx-mode)}))
