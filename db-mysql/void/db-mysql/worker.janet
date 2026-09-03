### void/db-mysql/worker — one connection, on a thread of its own.
###
### This file is the half of the driver that never runs on the ev
### loop. `serve` is an `ev/thread` body: it opens the client library
### in its own VM, connects, and then answers commands off a threaded
### channel until it is told to stop. The MYSQL* it owns is created
### here and dies here — it is never marshalled, never shared, and
### never touched by two threads, which is the whole reason the thread
### exists.
###
### Why a thread at all: libmysqlclient is synchronous. There is no
### `mysql_send_query` to park on a descriptor with, the way
### void/db-postgres parks on libpq's through void/fdwait, so a query
### issued on the loop stops every fiber in the process for as long as
### the server takes. `void/crypto/kdf` measured what that looks like
### for 25 ms of hashing; a slow query is worse and unbounded.
###
### The contract with the other side (./conn) is two threaded channels
### and plain data on both:
###
###     main VM  --[:execute sql params opts]-->  worker
###     main VM  <--[:answer {:rows ... :count ...}]-- worker
###
### Everything crossing is a string, a number, a keyword or a
### dictionary of those — an ffi pointer is exactly what cannot be
### marshalled into another VM, which is why ./libmysql is opened here
### rather than handed over.
###
### `:answer` and `:failed`, rather than the `:ok`/`:error` this would
### otherwise be spelled with, because the answer channel is also the
### thread's supervisor (./conn explains why it has to be) and janet
### spells a supervisor message `[:ok chan fiber]` / `[:error msg
### fiber]`. Two tags nothing else uses is what keeps "the statement
### failed" and "the thread died" from being the same message.
###
### The commands, in full:
###
###   [:execute sql params opts]  run one statement, decode the rows
###   [:ping]                     mysql_ping
###   [:info]                     server version, thread id, charset
###   [:close]                    close the connection and end the loop
###
### and every answer is [:answer value] or [:failed {:message :code
### :sqlstate :lost}] — `:lost` is the bit ./driver needs, because a
### connection that died is a different situation from a statement
### that failed.

(import ./libmysql :as my)
(import ./types :as types)

# -- errors --------------------------------------------------------------

(def- u64-max
  "(unsigned long)-1, which is how the C API spells \"that failed\" in
  a function whose successful answers are all lengths or counts."
  (int/u64 "18446744073709551615"))

(defn- error-of
  ``The connection's current error as the dictionary that crosses the
  channel. `context` says what was being attempted, since a bare
  "Lost connection to MySQL server" does not.``
  [conn context]
  (def code (my/mysql_errno conn))
  {:message (my/mysql_error conn)
   :code code
   :sqlstate (my/mysql_sqlstate conn)
   :context context
   :lost (my/connection-lost? code)})

(defn- fail [conn context]
  (error (error-of conn context)))

(defn- u64->number
  "A my_ulonglong count as a janet number, or an int/u64 past 2^53."
  [n]
  (if (< n (int/u64 9007199254740992)) (scan-number (string n)) n))

# -- escaping ------------------------------------------------------------

(defn escaper
  ``The library's own `mysql_real_escape_string`, bound to one
  connection: (fn [bytes]
  escaped), with no surrounding quotes — ./types adds those.

  Bound to the connection and not written by hand because it is the
  connection that knows the character set, and a multi-byte charset
  (GBK, Big5, SJIS) is where an escaper that does not gets it wrong:
  a byte that is a backslash on its own is the tail of a legitimate
  character there, and doubling it corrupts the value rather than
  protecting it.``
  [conn]
  (fn escape [bytes]
    (def n (length bytes))
    # the C API's contract: `to` must hold 2n + 1 bytes worst case
    (def out (buffer/new-filled (+ 1 (* 2 n))))
    (def written (my/mysql_real_escape_string conn out bytes n))
    (when (= written u64-max)
      # MySQL 8 answers this way under NO_BACKSLASH_ESCAPES. `connect!`
      # refuses that mode outright, so reaching here means it was
      # turned on mid-session
      (fail conn "escaping a parameter"))
    (string/slice out 0 (u64->number written))))

# -- results -------------------------------------------------------------

(defn- fields-of [res n]
  (seq [i :range [0 n]]
    (my/field (my/mysql_fetch_field_direct res i))))

(defn- read-rows
  ``Every row of a stored result, as tables with keyword column keys.
  A NULL column is *absent* from its row rather than nil — a janet
  table cannot hold nil, and it is the shape void/db-sqlite and
  void/db-postgres both report.``
  [res opts]
  (def n (my/mysql_num_fields res))
  (def fields (fields-of res n))
  (def names (map |(keyword ($ :name)) fields))
  (def decoders (map |(types/decoder-for $ opts) fields))
  (def rows @[])
  (var row (my/mysql_fetch_row res))
  (while row
    (def lengths (my/mysql_fetch_lengths res))
    (def t @{})
    (for i 0 n
      (when-let [cell (my/cell-ptr row i)]
        (put t (in names i)
             ((in decoders i) (my/bytes-at cell (my/cell-ulong lengths i))))))
    (array/push rows t)
    (set row (my/mysql_fetch_row res)))
  rows)

(defn- drain!
  ``Consume and discard any further result sets. Nothing this driver
  sends can produce one — CLIENT_MULTI_STATEMENTS is deliberately
  never set (see libmysql/client-flags) — but `CALL some_procedure()`
  produces several regardless, and a connection left holding them
  answers CR_COMMANDS_OUT_OF_SYNC to the *next* statement. Draining
  costs one call on the common path and keeps the pooled connection
  usable on the uncommon one.``
  [conn]
  (var more true)
  (while more
    (def rc (my/mysql_next_result conn))
    (cond
      (zero? rc)
      (when-let [res (my/mysql_store_result conn)] (my/mysql_free_result res))
      (neg? rc) (set more false)
      (fail conn "reading the rest of a multi-result statement"))))

(defn- execute-one
  ``Run one statement on this connection and collect its answer.

  `sql` is what the server is sent — parameters already rendered into
  it — and `context` is the statement as the caller wrote it, with the
  placeholders still in. Two arguments and not one because `context`
  is what travels on an error, and an error that carried the rendered
  statement would carry the parameter values with it: the password
  being hashed, the token being stored. void/db's own logging keeps
  the two apart for every driver (`:sql` with the placeholders,
  `:params` beside it); this keeps the driver's errors on the same
  footing.``
  [conn sql context opts]
  (unless (zero? (my/mysql_real_query conn sql (length sql)))
    (fail conn context))
  (def res (my/mysql_store_result conn))
  (defer (when res (my/mysql_free_result res))
    (cond
      res
      (let [rows (read-rows res opts)]
        (drain! conn)
        {:rows rows :count (length rows)})

      # no result set is either a write or an error, and
      # mysql_field_count is the only thing that tells them apart
      (pos? (my/mysql_field_count conn))
      (fail conn context)

      (let [affected (my/mysql_affected_rows conn)]
        (when (= affected u64-max) (fail conn context))
        (drain! conn)
        {:rows []
         :count (u64->number affected)
         :insert-id (u64->number (my/mysql_insert_id conn))}))))

# -- connecting ----------------------------------------------------------

(defn- set-uint-option! [conn option value]
  (def cell (buffer/new-filled 4))
  (ffi/write :uint value cell 0)
  (my/mysql_options conn option cell))

(defn- probe-layout!
  ``Prove that this library lays a MYSQL_FIELD out where ./libmysql
  says it does, before any caller depends on it.

  The offsets there are MySQL's and MariaDB's shared head, read
  through a pointer the library owns. They have not moved in a
  decade, and a driver with no compile step still cannot *know* that
  — so one statement at connect asks. `name` sits at offset 0 in
  every version there has ever been, which makes it the honest
  witness: if it reads back, this is a MYSQL_FIELD; if the type code
  is also an integer type, the rest of the head is where it should
  be. Getting this wrong costs a boot error naming the library
  instead of a segfault on the first query.``
  [conn]
  (def probe "void_layout_probe")
  (def sql (string "SELECT 1 AS " probe))
  (unless (zero? (my/mysql_real_query conn sql (length sql)))
    (fail conn "probing the result layout"))
  (def res (my/mysql_store_result conn))
  (unless res (fail conn "probing the result layout"))
  (defer (my/mysql_free_result res)
    (def fld (my/field (my/mysql_fetch_field_direct res 0)))
    (unless (= probe (get fld :name))
      (errorf (string "mysql: %s does not lay out MYSQL_FIELD the way this "
                      "driver reads it (the column came back named %q, not "
                      "%q) — this is a client library void/db-mysql has not "
                      "seen; please report it with the library version")
              (or my/library-path "the client library") (get fld :name) probe))
    (unless (index-of (get fld :type) [:long :longlong :int24 :short :tiny])
      (errorf (string "mysql: %s reports `SELECT 1` as a %q column, so the "
                      "MYSQL_FIELD type offset this driver reads is wrong for "
                      "it — please report it with the library version")
              (or my/library-path "the client library") (get fld :type)))))

(defn- scalar
  "The one value of a one-row, one-column statement, as text."
  [conn sql]
  (unless (zero? (my/mysql_real_query conn sql (length sql)))
    (fail conn sql))
  (def res (my/mysql_store_result conn))
  (unless res (fail conn sql))
  (defer (my/mysql_free_result res)
    (def row (my/mysql_fetch_row res))
    (when row
      (when-let [cell (my/cell-ptr row 0)]
        (my/bytes-at cell (my/cell-ulong (my/mysql_fetch_lengths res) 0))))))

(defn- check-escaping!
  ``Refuse NO_BACKSLASH_ESCAPES rather than work around it.

  Under that sql_mode a backslash is an ordinary character, and the
  escaping this driver's parameters rely on is the one thing that
  changes meaning with it. MySQL 8's `mysql_real_escape_string`
  answers -1 in that mode rather than guess; MariaDB's silently
  switches to doubling quotes only. Neither is a footing to bind
  parameters on, and the session that has it set is nearly always a
  server-wide sql_mode nobody meant to apply here.``
  [conn]
  (def mode (or (scalar conn "SELECT @@SESSION.sql_mode") ""))
  (when (string/find "NO_BACKSLASH_ESCAPES" mode)
    (errorf (string "mysql: this session runs with NO_BACKSLASH_ESCAPES, and "
                    "void/db-mysql binds parameters by escaping them — remove "
                    "it from the server's sql_mode, or from this connection's "
                    "with [:db-mysql :init-command] \"SET SESSION sql_mode = ...\""))))

(defn connect!
  ``Open one connection from a plain-data `spec` (see ./config, which
  builds one) and return the MYSQL*. Everything that can be wrong
  with a configuration is wrong here, on a thread of its own, before
  the pool has been handed anything.``
  [spec]
  (def conn (my/mysql_init nil))
  (unless conn (error {:message "mysql_init failed — out of memory"
                       :code 0 :sqlstate "HY000" :lost false}))
  (var ok false)
  (defer (unless ok (my/mysql_close conn))
    (when-let [t (get spec :connect-timeout)]
      (set-uint-option! conn my/MYSQL-OPT-CONNECT-TIMEOUT (math/round t)))
    (when-let [t (get spec :read-timeout)]
      (set-uint-option! conn my/MYSQL-OPT-READ-TIMEOUT (math/round t)))
    (when-let [t (get spec :write-timeout)]
      (set-uint-option! conn my/MYSQL-OPT-WRITE-TIMEOUT (math/round t)))
    # the charset is set BEFORE connecting on purpose: it then applies
    # from the handshake on, so there is no window in which the
    # escaping above is operating on a charset nobody chose
    (my/mysql_options conn my/MYSQL-SET-CHARSET-NAME (get spec :charset "utf8mb4"))
    (when-let [c (get spec :init-command)]
      (my/mysql_options conn my/MYSQL-INIT-COMMAND c))
    (when-let [m (get spec :ssl-mode)]
      (set-uint-option! conn my/MYSQL-OPT-SSL-MODE
                        (or (get my/ssl-modes m)
                            (errorf "mysql: unknown :ssl-mode %q" m))))
    (each [k option] [[:ssl-ca my/MYSQL-OPT-SSL-CA]
                      [:ssl-cert my/MYSQL-OPT-SSL-CERT]
                      [:ssl-key my/MYSQL-OPT-SSL-KEY]]
      (when-let [v (get spec k)] (my/mysql_options conn option v)))

    (def flags
      # CLIENT_FOUND_ROWS makes an UPDATE report the rows it MATCHED
      # rather than the rows whose values changed. That is what
      # Postgres and sqlite both report, so it is what void/db's
      # entity layer means by :count — without it, updating a row to
      # the value it already holds answers 0, and "0 rows" is how
      # every caller spells "not found"
      (if (get spec :found-rows true) my/CLIENT-FOUND-ROWS 0))

    (def handle
      (my/mysql_real_connect conn
                             (get spec :host)
                             (get spec :user)
                             (get spec :password)
                             (get spec :database)
                             (get spec :port 0)
                             (get spec :socket)
                             flags))
    (unless handle (fail conn "connecting"))

    # what the connection is only becomes true after the handshake
    (probe-layout! conn)
    (check-escaping! conn)
    (set ok true)
    conn))

(defn info
  "What this connection is, for a log line and the component's health."
  [conn]
  {:server (my/mysql_get_server_info conn)
   :server-version (my/server-version conn)
   :client (my/mysql_get_client_info)
   :library my/library-path
   :host (my/mysql_get_host_info conn)
   :charset (my/mysql_character_set_name conn)
   :thread-id (u64->number (int/u64 (my/mysql_thread_id conn)))})

# -- the loop ------------------------------------------------------------

(defn serve
  ``The worker thread's body. `payload` is [req resp spec] — two
  threaded channels and the plain-data connection spec.

  The first thing on `resp` is the connect outcome, so the fiber that
  spawned this thread learns whether it has a connection before it
  hands one out. After that it is one answer per command, in order,
  forever — until [:close], or until the process ends and takes the
  thread with it.``
  [payload]
  (def [req resp spec] payload)
  (def opts (get spec :decode {}))
  (my/load! (get spec :library))
  # every thread that touches the library owes it a matching
  # mysql_thread_end, or the per-thread arena leaks for the life of
  # the process
  (my/mysql_thread_init)
  (defer (my/mysql_thread_end)
    (def [ok conn] (protect (connect! spec)))
    (unless ok
      (ev/give resp [:failed (if (dictionary? conn)
                               conn
                               {:message (string conn) :code 0 :lost false})])
      (break))
    (def escape (escaper conn))
    (ev/give resp [:answer (info conn)])

    (var running true)
    (while running
      (def command (ev/take req))
      # the channel closing is the main VM going away: let go of the
      # connection rather than park forever on a channel nobody holds
      (unless command
        (protect (my/mysql_close conn))
        (break))
      (def [ok value]
        (protect
          (match command
            [:execute sql params o]
            (execute-one conn (types/interpolate sql params escape) sql opts)

            [:ping]
            (if (zero? (my/mysql_ping conn)) true (fail conn "ping"))

            [:info] (info conn)

            [:close]
            (do (set running false) (my/mysql_close conn) true)

            (errorf "mysql worker: unknown command %q" command))))
      (ev/give resp
               (if ok
                 [:answer value]
                 [:failed (if (dictionary? value)
                            value
                            {:message (string value) :code 0 :lost false})])))))
