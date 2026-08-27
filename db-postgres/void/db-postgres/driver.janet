### void/db-postgres/driver — the :void/db-driver contract over async
### libpq (SPEC.md §5.10, ROADMAP 2.2, ADR-0011).
###
### The contract itself is void/db/driver: a dictionary of
### :dialect/:connect/:close/:execute plus the optional keys a database
### can honour. Postgres can honour all of them — prepared statements,
### real transactions with isolation levels, savepoints, RETURNING —
### so unlike the sqlite reference driver almost nothing here falls
### back to generated SQL.
###
### Nothing in this file imports void/db. A driver depends on the
### *contract*, not on the kernel, and the kernel runs the value
### through `driver/normalize`.
###
### What :connect hands the pool is a HANDLE, not a PGconn, and that is
### the one structural decision worth explaining. A Postgres connection
### dies for reasons that have nothing to do with the statement that
### hit it: the server restarts, a DBA terminates the backend, a
### network path drops, a pooler recycles the session. void/db's pool
### does not ping and only discards an entry when a transaction fails
### (see void/db/pool), so a driver whose connections die on the wire
### would poison the pool permanently — every checkout handing back the
### same corpse. The handle is the fix: it owns the conninfo and the
### prepared-statement catalogue, and it opens a new connection when it
### finds the old one dead.
###
### Silently, but never dangerously. A reconnect is allowed only
### *before* a statement is sent, only when the connection is already
### gone, and never inside a transaction — where dropping the session
### would discard writes the caller believes are pending. The rules
### are, in full:
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
### :begin/:commit/:rollback of the contract, which is what `db/with-tx`
### uses. A BEGIN sent as raw SQL is a statement like any other and the
### driver cannot see it; that is the reason to open transactions
### through `with-tx` rather than by hand.
###
### The catalogue is what makes the reconnect invisible one level up:
### the pool caches sql -> statement name per entry, so a replacement
### connection has to be able to answer to the names already handed
### out. ./conn's `new-session` holds them, the new connection adopts
### it, and a name the fresh session does not know yet is prepared
### again on first use (the 26000 path in `conn/execute-prepared`).

(import ./config :as config)
(import ./conn :as conn)
(import ./libpq :as pq)

(def dialect
  "Builder dialect this driver speaks — $1, $2 placeholders (registered
  by void/db/builder)."
  :postgres)

# -- transactions --------------------------------------------------------

(def isolation-levels
  ``The :isolation values `db/with-tx` may ask for. READ UNCOMMITTED is
  accepted and behaves as READ COMMITTED — that is Postgres' own
  documented answer, not a substitution made here.``
  {:read-uncommitted "READ UNCOMMITTED"
   :read-committed "READ COMMITTED"
   :repeatable-read "REPEATABLE READ"
   :serializable "SERIALIZABLE"})

(defn begin-sql
  ``The BEGIN for an :isolation argument. A keyword names the level:

      (db/with-tx {:isolation :serializable} ...)

  and a dictionary adds the two modifiers that are not levels:

      (db/with-tx {:isolation {:level :repeatable-read :read-only true}} ...)
      (db/with-tx {:isolation {:level :serializable :deferrable true}} ...)

  DEFERRABLE only means anything for a read-only serializable
  transaction — it waits for a snapshot that cannot fail with 40001,
  which is what makes long analytical reads survivable.``
  [isolation &opt default-level]
  (def spec (if (dictionary? isolation) isolation {:level isolation}))
  (def level (or (get spec :level) default-level))
  (def parts @["BEGIN"])
  (when level
    (array/push parts
                (string "ISOLATION LEVEL "
                        (or (get isolation-levels level)
                            (errorf "postgres: unknown isolation level %q (known: %s)"
                                    level
                                    (string/join
                                      (map |(string/format "%q" $)
                                           (sorted (keys isolation-levels)))
                                      " "))))))
  (when-let [ro (get spec :read-only)]
    (array/push parts (if ro "READ ONLY" "READ WRITE")))
  (when (get spec :deferrable) (array/push parts "DEFERRABLE"))
  (string/join parts " "))

# -- the handle ----------------------------------------------------------

(defn- open-connection [h]
  (conn/open (h :conninfo)
             (merge (h :open-opts) {:session (h :session)})))

(defn handle
  ``A pooled connection: the conninfo it is made of, the live PGconn,
  the prepared-statement catalogue that outlives it, and whether a
  transaction is open on it.``
  [conninfo &opt opts]
  (default opts {})
  (def h @{:conninfo conninfo
           :open-opts opts
           :session (conn/new-session)
           :conn nil
           :in-tx false
           :generation 0
           :reconnect (not= false (get opts :reconnect))})
  (put h :conn (open-connection h))
  h)

(defn live?
  "Is this handle's connection currently usable?"
  [h]
  (and (h :conn) (conn/live? (h :conn)) true))

(defn reconnect!
  ``Replace the handle's connection, adopting its statement catalogue.
  Used by `ensure!`; exposed because a health check that finds a dead
  connection has the same repair to make.``
  [h]
  (when-let [old (h :conn)]
    (protect (conn/close old)))
  (put h :conn nil)
  (put h :conn (open-connection h))
  (put h :generation (inc (h :generation)))
  (put h :in-tx false)
  (h :conn))

(defn- ensure!
  ``The connection to run the next statement on. A dead one is replaced
  outside a transaction and refused inside it — `what` says which
  statement was about to run, so the message names the casualty.``
  [h &opt what]
  (cond
    (live? h) (h :conn)

    (h :in-tx)
    (errorf (string "postgres: the connection was lost inside a transaction%s "
                    "— the transaction is gone and nothing after it ran")
            (if what (string " (" what ")") ""))

    (not (h :reconnect))
    (error "postgres: the connection is closed and [:db-postgres :reconnect] is false")

    (reconnect! h)))

(defn close-handle
  "Close a handle's connection. Safe twice."
  [h]
  (when-let [c (h :conn)]
    (put h :conn nil)
    (conn/close c))
  nil)

# -- the driver value ----------------------------------------------------

(defn make
  ``Build the :void/db-driver value. opts:

    :conninfo    what libpq opens (see ./config, which builds one)
    :connect-timeout  seconds for the whole handshake
    :decode      ./types options for every result ({:json false ...})
    :prepared    use the prepared-statement pair (default true). false
                 leaves the pair off the driver, and the kernel then
                 sends every statement through :execute — which is the
                 setting a transaction-pooling pgbouncer needs, since
                 a prepared statement lives in a session it will not
                 give you back
    :reconnect   replace a connection that died (default true; see the
                 header for exactly when that is allowed)
    :tx-mode     default isolation level for `db/with-tx` without one
                 (nil = the server's default_transaction_isolation)

  The kernel normalizes the result, which fills in the fallbacks this
  driver does not need.``
  [&opt opts]
  (default opts {})
  (def conninfo (get opts :conninfo ""))
  (def prepared? (not= false (get opts :prepared)))
  (def tx-mode (get opts :tx-mode))
  (def open-opts
    {:connect-timeout (get opts :connect-timeout)
     :decode (get opts :decode {})
     :reconnect (not= false (get opts :reconnect))})

  (defn run [h sql params &opt o]
    (conn/execute (ensure! h sql) sql params))

  (defn raw [h sql]
    (conn/execute (ensure! h sql) sql []))

  (def base
    @{:name :postgres
      :dialect dialect
      # every INSERT ... RETURNING hands the stored row back, so the
      # entity layer never re-reads by insert id
      :returning true
      :conninfo conninfo

      :connect (fn pg-connect [] (handle conninfo open-opts))
      :close (fn pg-close [h] (close-handle h))
      :execute (fn pg-execute [h sql params &opt o] (run h sql params o))
      :ping (fn pg-ping [h] (conn/ping (ensure! h "ping")))

      :begin
      (fn pg-begin [h &opt isolation]
        (def sql (begin-sql isolation tx-mode))
        (def res (conn/execute (ensure! h sql) sql []))
        (put h :in-tx true)
        res)

      :commit
      (fn pg-commit [h]
        # a lost session did not commit, and saying so is the whole
        # difference between "your write is durable" and "it is not"
        (unless (live? h)
          (put h :in-tx false)
          (error "postgres: the connection was lost before COMMIT — the transaction did not commit"))
        (def res (conn/execute (h :conn) "COMMIT" []))
        (put h :in-tx false)
        res)

      :rollback
      (fn pg-rollback [h]
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
      (fn pg-savepoint [h n] (raw h (string "SAVEPOINT " n)))
      :release-savepoint
      (fn pg-release [h n] (raw h (string "RELEASE SAVEPOINT " n)))
      :rollback-to-savepoint
      (fn pg-rollback-to [h n] (raw h (string "ROLLBACK TO SAVEPOINT " n)))

      # -- beyond the contract, for callers that ask for Postgres by
      # -- name (see ../init, which re-exports these)

      :stream
      (fn pg-stream [h sql params f] (conn/stream (ensure! h sql) sql params f))

      :pipelined
      (fn pg-pipelined [h statements]
        (conn/pipelined (ensure! h "pipeline") statements))

      :cancel!
      (fn pg-cancel [h] (when (live? h) (conn/cancel! (h :conn))))

      :connection-info
      (fn pg-connection-info [h]
        (if (live? h)
          (let [c (h :conn)]
            {:server-version (conn/server-version c)
             :backend-pid (conn/backend-pid c)
             :transaction (conn/transaction-status c)
             :generation (h :generation)
             :prepared (length (get-in h [:session :stmts]))})
          {:generation (h :generation) :transaction :closed}))})

  (when prepared?
    (put base :prepare
         (fn pg-prepare [h sql] (conn/prepare (ensure! h sql) sql)))
    (put base :execute-prepared
         (fn pg-execute-prepared [h name params &opt o]
           (conn/execute-prepared (ensure! h name) name params))))
  base)

# -- what the plugin needs to know about the library ---------------------

(defn capabilities
  ``What the loaded libpq can do, for the log line at boot and the
  component's health: {:libpq [major minor] :pipeline bool :cancel
  bool}. `pipeline` is libpq 14+, the non-blocking `cancel` poll loop
  is 17+ (older libpq still cancels, through the one call in this
  driver that can block the loop — see conn/cancel!).``
  []
  {:libpq (pq/version)
   :path pq/library-path
   :pipeline (pq/supports? :pipeline)
   :cancel (pq/supports? :cancel)})

(defn from-config
  ``The driver for a [:db-postgres] config slice — `config/conninfo`
  plus the behaviour keys, in one call.``
  [cfg0]
  (def cfg (merge config/defaults (or cfg0 {})))
  (make {:conninfo (config/conninfo cfg)
         :connect-timeout (get cfg :connect-timeout)
         :decode (config/decode-opts cfg)
         :prepared (get cfg :prepared)
         :reconnect (get cfg :reconnect)
         :tx-mode (get cfg :tx-mode)}))
