### void/db-postgres/conn — one Postgres connection on the ev loop
### (ADR-0011, SPEC.md Appendix A).
###
### libpq has a complete non-blocking API: PQconnectStart/PQconnectPoll
### to connect, PQsendQuery* / PQflush to send, PQconsumeInput /
### PQisBusy / PQgetResult to receive. What it needs in return is
### somebody to tell it when its socket is ready — and that is
### void/fdwait. The result is a driver that never blocks the loop and
### needs no thread pool: N fibers issuing N queries on N connections
### are N concurrent queries on one OS thread.
###
### The three loops are all the same shape, and all of them park in
### fdwait rather than spin:
###
###   connect   PQconnectStart, then PQconnectPoll until OK, waiting in
###             the direction it asks for (the socket can *change*
###             mid-connect on a multi-host cluster — hence refresh!)
###   send      PQflush until it reports 0, waiting on :both: writable
###             means we can push more, readable means the server is
###             talking and we must consume it or the two of us
###             deadlock, each waiting for the other to read
###   receive   PQisBusy? wait readable, PQconsumeInput, ask again;
###             then PQgetResult until NULL — always until NULL, or
###             the connection is left mid-protocol
###
### One fiber at a time per connection. That is not a limitation of
### this driver but of the protocol: a PGconn carries one query and
### one result stream, which is exactly why there is a pool above it.
### The one operation that is safe from another fiber is `cancel!` —
### it opens its own socket.
###
### What is deliberately not here: COPY (a different protocol path),
### LISTEN on a pooled connection (see ./listener — a notification
### would arrive on whichever connection happened to run the LISTEN),
### and the binary result format (./types explains why text).

(import void/fdwait)
(import ./libpq :as pq)
(import ./types :as types)

# -- errors --------------------------------------------------------------

(defn- text [s]
  (when s (let [t (string/trim s)] (unless (empty? t) t))))

(defn- diag [res field]
  (text (pq/cstr (pq/PQresultErrorField res (get pq/diag-fields field)))))

(defn result-error
  ``The structured error behind a failed result. Postgres says far
  more than "it did not work" — the SQLSTATE is what a caller
  branches on (23505 is a duplicate key, 40001 a serialization
  failure worth retrying), and the constraint and column names are
  what turns a failure into a message for a form field.

  :message leads with the primary text and carries the SQLSTATE, so
  the value reads correctly wherever it is printed as a string.``
  [res &opt sql]
  (def message (or (diag res :message)
                   (text (pq/PQresultErrorMessage res))
                   "postgres reported an error with no message"))
  (def state (diag res :sqlstate))
  (freeze
    {:db/error :postgres
     :message (string "postgres: " message
                      (when state (string " [" state "]")))
     :sqlstate state
     :severity (diag res :severity)
     :detail (diag res :detail)
     :hint (diag res :hint)
     :position (when-let [p (diag res :position)] (scan-number p))
     :schema (diag res :schema)
     :table (diag res :table)
     :column (diag res :column)
     :datatype (diag res :datatype)
     :constraint (diag res :constraint)
     :where (diag res :where)
     :sql sql}))

(defn sqlstate
  "The SQLSTATE of an error raised by this driver, or nil."
  [e]
  (when (dictionary? e) (get e :sqlstate)))

(defn- fail!
  ``A connection-level failure: whatever libpq last complained about.
  The connection is marked broken — libpq's state after a protocol
  error is not something to keep using, and the driver replaces it
  before the next statement.``
  [c what &opt sql]
  (put c :broken true)
  (def msg (or (text (pq/PQerrorMessage (c :pg))) "connection lost"))
  (error (freeze {:db/error :postgres
                  :message (string "postgres: " what ": " msg)
                  :fatal true
                  :sql sql})))

(defn- readiness!
  "Wait in one direction, turning a hangup into the connection error
  it is."
  [c dir &opt what]
  (def outcome (fdwait/await (c :fds) dir))
  (unless (fdwait/ready? outcome)
    (fail! c (string (or what "waiting for the server") " (" outcome ")")))
  outcome)

# -- connecting ----------------------------------------------------------

(defn new-session
  ``A prepared-statement catalogue: name -> sql, plus the counter the
  names are minted from. It belongs to the *session* rather than to
  the PGconn, so a replacement connection can adopt it and re-prepare
  under the names its caller already holds.``
  []
  @{:stmts @{} :next 0})

(defn- with-deadline
  ``Run (f) under a wall-clock limit, in a supervised CHILD task —
  never `ev/with-deadline` on the caller, which cancels its root
  task; for a request fiber that is the whole request (ADR-0015, and
  the same reason void/db's pool spells its checkout timeout out this
  way).``
  [seconds f on-timeout]
  (if (or (nil? seconds) (not (pos? seconds)))
    (f)
    (do
      (def slot @{})
      (def sup (ev/chan 1))
      (def task (ev/go (fn deadline-body []
                         (put slot :value (f))
                         (put slot :done true))
                       nil sup))
      (ev/deadline seconds task task)
      (def [status fiber] (ev/take sup))
      (cond
        (slot :done) (slot :value)
        (= :error status) (error (fiber/last-value fiber))
        (on-timeout)))))

(defn- poll-connect
  ``PQconnectPoll until the handshake is done. The first call is made
  as if the previous one had returned PGRES_POLLING_WRITING, which is
  what libpq's own documented loop does.``
  [c]
  (var dir :write)
  (forever
    # a multi-host conninfo moves to the next address by opening a new
    # socket, so the descriptor under the watchers can change
    (fdwait/refresh! (c :fds) (pq/PQsocket (c :pg)))
    (readiness! c dir "connecting")
    (def status (pq/PQconnectPoll (c :pg)))
    (cond
      (= status pq/POLLING-OK) (break)
      (= status pq/POLLING-READING) (set dir :read)
      (= status pq/POLLING-WRITING) (set dir :write)
      (fail! c "connect"))))

(defn open
  ``Open one connection. `conninfo` is a libpq connection string (see
  ./config, which builds one); opts:

    :connect-timeout  seconds for the whole handshake — TCP, TLS and
                      authentication. libpq's own connect_timeout
                      keyword covers the socket only.
    :decode           passed to ./types for every result
    :session          a `new-session` catalogue to adopt instead of a
                      fresh one — how a replacement connection inherits
                      the prepared statements of the one it replaces
                      (see ./driver, which reconnects under the pool)

  Note the one blocking step nobody can remove: PQconnectStart
  resolves the host name before it returns. For a hostname behind a
  slow DNS server that is a stall on the loop — part of why the pool
  opens connections lazily and then keeps them.``
  [conninfo &opt opts]
  (default opts {})
  (def raw (pq/PQconnectStart conninfo))
  (unless raw (error "postgres: PQconnectStart returned NULL (out of memory)"))
  (def c @{:pg raw
           :fds (fdwait/pair (pq/PQsocket raw))
           :session (get opts :session (new-session))
           :broken false
           :closed false
           :in-tx false
           :conninfo conninfo
           :opts opts
           :decode (get opts :decode {})
           :notifications @[]
           # true between a send and the NULL that ends its results: a
           # statement left mid-protocol (a cancelled query, a decoder or
           # a stream callback that threw) must not go back to the pool,
           # or the next query reads this one's rows (see `reusable?`)
           :in-exchange false})
  (when (= pq/CONNECTION-BAD (pq/PQstatus raw))
    (def msg (or (text (pq/PQerrorMessage raw)) "bad connection parameters"))
    (pq/PQfinish raw)
    (put c :pg nil)
    (errorf "postgres: cannot start connecting: %s" msg))
  (def [ok err]
    (protect
      (with-deadline (get opts :connect-timeout)
                     (fn [] (poll-connect c))
                     (fn [] (errorf "postgres: connecting timed out after %.1fs"
                                    (get opts :connect-timeout))))))
  (unless ok
    (fdwait/release! (c :fds))
    (pq/PQfinish (c :pg))
    (put c :pg nil)
    (error err))
  # from here on libpq buffers instead of blocking on a full socket —
  # which is what makes PQflush a loop rather than a formality
  (pq/PQsetnonblocking (c :pg) 1)
  c)

(defn close
  "Close a connection. Safe to call twice; safe on a broken one."
  [c]
  (unless (c :closed)
    (put c :closed true)
    (fdwait/release! (c :fds))
    (when (c :pg) (pq/PQfinish (c :pg)))
    (put c :pg nil))
  nil)

(defn live?
  "Is this connection usable — not closed, not broken, and libpq still
  calls it OK?"
  [c]
  (and (not (c :closed))
       (not (c :broken))
       (c :pg)
       (= pq/CONNECTION-OK (pq/PQstatus (c :pg)))
       true))

# -- sending and receiving -----------------------------------------------

(defn- flush!
  ``Push the outgoing buffer out. In non-blocking mode PQflush leaves
  what did not fit for next time, so this is a loop — and it waits on
  :both deliberately: were it to wait only for writability it would
  deadlock against a server that stopped reading because its own
  output buffer filled up and we are not draining it.``
  [c &opt sql]
  (forever
    (def r (pq/PQflush (c :pg)))
    (cond
      (zero? r) (break)
      (neg? r) (fail! c "sending" sql)
      (let [dir (fdwait/await (c :fds) :both)]
        (unless (fdwait/ready? dir) (fail! c (string "sending (" dir ")") sql))
        (when (= :read dir)
          (unless (= 1 (pq/PQconsumeInput (c :pg)))
            (fail! c "sending" sql)))))))

(defn- send! [c thunk &opt sql]
  (unless (live? c)
    (fail! c "sending on a closed connection" sql))
  # from here the connection carries an unfinished exchange until its
  # results are drained to NULL; a `collect`/`stream` clears it, and
  # anything that unwinds before then leaves it set on purpose
  (put c :in-exchange true)
  (unless (= 1 (thunk))
    (fail! c "sending" sql))
  nil)

(defn reusable?
  ``Safe to return to the pool? A connection left mid-protocol — a
  cancelled query, a decoder or a `stream` callback that threw before
  the results were drained — is not: the next query on it would read
  the abandoned one's rows.``
  [c]
  (and (live? c) (not (c :in-exchange)) true))

(defn- next-result
  "Park this fiber (not the loop) until libpq has a whole result, or
  the stream ends. nil means: no more results for this statement."
  [c &opt sql]
  (while (= 1 (pq/PQisBusy (c :pg)))
    (readiness! c :read "reading the result")
    (unless (= 1 (pq/PQconsumeInput (c :pg)))
      (fail! c "reading the result" sql)))
  (pq/PQgetResult (c :pg)))

(defn- drain-notifications!
  "Move whatever asynchronous notifications libpq has buffered onto
  the connection. Postgres delivers them alongside query results, so
  this belongs after every receive."
  [c]
  (forever
    (def ptr (pq/PQnotifies (c :pg)))
    (unless ptr (break))
    (array/push (c :notifications) (pq/notification ptr))
    (pq/PQfreemem ptr))
  (c :notifications))

(defn take-notifications!
  "Take and clear the notifications this connection has collected."
  [c]
  (def out (c :notifications))
  (put c :notifications @[])
  out)

(defn wait-for-input
  ``Park this fiber until the server sends something on an otherwise
  idle connection, then return the asynchronous notifications that
  arrived — how a LISTENer waits (see ./listener). The array can be
  empty: what woke us may have been anything else the backend chose to
  send, and a caller who wants a notification waits again.

  nil means the wait was interrupted rather than satisfied: either
  `interrupt!` from another fiber or the descriptor going away. `live?`
  tells the two apart, and only one of them is bad news.

  Only for a connection with no statement in flight. A query in
  progress consumes its own input, and two fibers reading one PGconn
  is the protocol error it looks like.``
  [c]
  (def outcome (fdwait/await (c :fds) :read))
  (cond
    (not (fdwait/ready? outcome)) nil
    (not (= 1 (pq/PQconsumeInput (c :pg))))
    (fail! c "waiting for a notification")
    (do (drain-notifications! c)
        (take-notifications! c))))

(defn interrupt!
  ``Wake a fiber parked in `wait-for-input` on this connection, from
  another one. The watchers are dropped — which is what the parked
  fiber notices — and recreated on the next wait; the socket and the
  session are untouched, so the connection stays usable.

  This is how a listener is told that its set of channels changed
  without a second fiber ever touching the PGconn.``
  [c]
  (fdwait/release! (c :fds))
  nil)

# -- results -------------------------------------------------------------

(defn- row-count
  ``The number a write should report. PQcmdTuples is the affected-row
  count for INSERT/UPDATE/DELETE — including INSERT ... RETURNING,
  where the rows come back *and* the count is right — and empty for a
  SELECT, where the rows are the count.``
  [res rows]
  (def tuples (text (pq/PQcmdTuples res)))
  (if tuples (or (scan-number tuples) 0) rows))

(defn- result-rows [res decode]
  (def ncols (pq/PQnfields res))
  (def nrows (pq/PQntuples res))
  # names and decoders once per result, not once per cell
  (def names (seq [i :range [0 ncols]] (keyword (pq/PQfname res i))))
  (def decoders
    (seq [i :range [0 ncols]] (types/decoder-for (pq/PQftype res i) decode)))
  (seq [r :range [0 nrows]]
    (def row @{})
    (for i 0 ncols
      # a NULL column is absent from the row rather than nil: a janet
      # table cannot hold nil, and `get` reads the two the same way
      (unless (= 1 (pq/PQgetisnull res r i))
        (put row (in names i) ((in decoders i) (pq/PQgetvalue res r i)))))
    row))

(defn- unsupported [status sql]
  (freeze {:db/error :postgres
           :message (cond
                      (or (= status pq/PGRES-COPY-IN)
                          (= status pq/PGRES-COPY-OUT)
                          (= status pq/PGRES-COPY-BOTH))
                      "postgres: COPY is not supported by this driver"

                      # not a failure of this statement: an earlier one
                      # in the pipeline failed and Postgres discards the
                      # rest until the sync point
                      (= status pq/PGRES-PIPELINE-ABORTED)
                      "postgres: skipped — an earlier statement in the pipeline failed"

                      (string "postgres: unexpected result status "
                              (pq/PQresStatus status)))
           :aborted (= status pq/PGRES-PIPELINE-ABORTED)
           :sql sql}))

(defn- collect
  ``Read every result of the statement(s) just sent, down to the NULL
  that ends them. Draining is not optional: an unread result leaves
  the connection mid-protocol, and the next query on it would read
  this one's rows.

  A parameterless send may be several statements, so the rows reported
  are the last statement's — with the first error kept and raised once
  everything has been drained.``
  [c &opt sql]
  (def decode (c :decode))
  (var err nil)
  (var rows @[])
  (var count 0)
  (var insert-oid nil)
  # rows of a result libpq is handing over one at a time. Single-row
  # mode is asked for per statement (`stream`), but libpq only clears
  # the request on the next *ordinary* send — a statement sent inside
  # pipeline mode inherits it — so this path is not exotic, it is what
  # `stream` followed by `pipelined` on one connection does. Collecting
  # the chunks makes the result the same either way, which is what
  # every caller of `collect` is entitled to assume.
  (var chunked @[])
  (forever
    (def res (next-result c sql))
    (unless res (break))
    (defer (pq/PQclear res)
      (def status (pq/PQresultStatus res))
      (cond
        (or (= status pq/PGRES-FATAL-ERROR)
            (= status pq/PGRES-BAD-RESPONSE))
        (unless err (set err (result-error res sql)))

        (= status pq/PGRES-SINGLE-TUPLE)
        (array/concat chunked (result-rows res decode))

        (or (= status pq/PGRES-TUPLES-OK)
            (= status pq/PGRES-COMMAND-OK)
            (= status pq/PGRES-EMPTY-QUERY))
        (do
          # the terminating result of a chunked stream carries no rows
          # of its own, so this is a concatenation, not a choice
          (def own (result-rows res decode))
          (set rows (if (empty? chunked) own (array/concat chunked own)))
          (set chunked @[])
          (set count (row-count res (length rows)))
          (set insert-oid (let [o (pq/PQoidValue res)] (when (pos? o) o))))

        (unless err (set err (unsupported status sql))))))
  (drain-notifications! c)
  # reached only after the results are drained to NULL — so the exchange
  # is complete even when we are about to raise a query error, and the
  # connection is clean to reuse. A cancel or a throw mid-loop never
  # reaches here, leaving :in-exchange set (see `reusable?`)
  (put c :in-exchange false)
  (when err (error err))
  {:rows rows :count count :insert-oid insert-oid})

# -- statements ----------------------------------------------------------

(defn- send-params
  ``Send one statement. Without parameters that is the simple
  protocol — which is also what lets a migration pass several
  statements in one string — unless `extended?` says otherwise:
  pipeline mode accepts the extended query protocol only
  ("PQsendQuery not allowed in pipeline mode"), and one statement per
  message is what pipelining means anyway.``
  [c sql params &opt extended?]
  (def encoded (types/encode-params params))
  (if (and (empty? encoded) (not extended?))
    (send! c (fn [] (pq/PQsendQuery (c :pg) sql)) sql)
    (let [[cells keepalive] (pq/cstr-array encoded)]
      (send! c
             (fn []
               (pq/PQsendQueryParams (c :pg) sql (length encoded)
                                     nil cells nil nil 0))
             sql)
      # the cells hold pointers into these strings, and libpq copies
      # them while sending: keeping the array reachable until here is
      # what says so to a reader (and to the GC)
      (length keepalive)))
  nil)

(defn execute
  "Run one statement (or, without parameters, several) and return
  {:rows [...] :count n}."
  [c sql &opt params]
  (send-params c sql params)
  (flush! c sql)
  (collect c sql))

(defn prepare
  ``Prepare `sql` on this connection and return the statement name.
  A prepared statement lives in the *session*, so the name is minted
  from the session catalogue and the SQL recorded beside it: a
  connection replaced under the pool inherits the catalogue and
  prepares the statement again under the same name (see
  `execute-prepared`), which is what keeps the pool's own sql -> name
  cache valid across a server restart.``
  [c sql]
  (def cat (c :session))
  (def n (inc (cat :next)))
  (put cat :next n)
  (def name (string "void_s" n))
  (send! c (fn [] (pq/PQsendPrepare (c :pg) name sql 0 nil)) sql)
  (flush! c sql)
  (collect c sql)
  (put (cat :stmts) name sql)
  name)

(def- invalid-statement-name "26000")

(defn execute-prepared
  ``Run a previously prepared statement. A statement name this session
  does not know (26000) is prepared again from the catalogue and
  retried once: the pool caches statement names per entry, and a
  connection replaced underneath it — a restarted server, a
  terminated backend, a DISCARD ALL from a pooler — would otherwise
  fail every cached statement for the rest of its life.``
  [c name &opt params]
  (defn run []
    (def encoded (types/encode-params params))
    (def [cells keepalive] (pq/cstr-array encoded))
    (send! c
           (fn []
             (pq/PQsendQueryPrepared (c :pg) name (length encoded)
                                     cells nil nil 0))
           name)
    (length keepalive)
    (flush! c name)
    (collect c name))
  (def [ok res] (protect (run)))
  (cond
    ok res

    (and (= invalid-statement-name (sqlstate res))
         (get-in c [:session :stmts name]))
    (let [sql (get-in c [:session :stmts name])]
      (send! c (fn [] (pq/PQsendPrepare (c :pg) name sql 0 nil)) sql)
      (flush! c sql)
      (collect c sql)
      (run))

    (error res)))

(defn stream
  ``Run a statement in single-row mode, calling (f row) for each row as
  it arrives, and return how many there were. libpq normally buffers
  the whole result before handing any of it over; single-row mode is
  how a million-row export stays a constant amount of memory.

  f runs while the query is still running, so it must not touch this
  connection.``
  [c sql params f]
  (send-params c sql params)
  # right after the send and before any PQgetResult: the only window
  # in which libpq accepts the mode
  (unless (= 1 (pq/PQsetSingleRowMode (c :pg)))
    (fail! c "requesting single-row mode" sql))
  (flush! c sql)
  (def decode (c :decode))
  (var err nil)
  (var n 0)
  (forever
    (def res (next-result c sql))
    (unless res (break))
    (defer (pq/PQclear res)
      (def status (pq/PQresultStatus res))
      (cond
        (= status pq/PGRES-SINGLE-TUPLE)
        (unless err
          (each row (result-rows res decode) (f row) (++ n)))

        (or (= status pq/PGRES-FATAL-ERROR) (= status pq/PGRES-BAD-RESPONSE))
        (unless err (set err (result-error res sql)))

        (or (= status pq/PGRES-TUPLES-OK) (= status pq/PGRES-COMMAND-OK))
        nil

        (unless err (set err (unsupported status sql))))))
  (drain-notifications! c)
  # drained to NULL — clean even if a decoder deferred an error into
  # `err`. A throw from `f` mid-stream unwinds before here, leaving the
  # connection mid-protocol so the pool discards it (see `reusable?`)
  (put c :in-exchange false)
  (when err (error err))
  n)

# -- pipeline mode -------------------------------------------------------

(defn pipelined
  ``Send several statements without waiting for each answer — one
  round trip instead of N. Postgres has had the protocol for it since
  forever; libpq exposed it in 14.

  `statements` are [sql params] pairs; the return is one
  {:rows :count} per statement, in order. A statement that fails
  aborts the rest of the pipeline (Postgres discards them until the
  sync point), and the error carries :index — which statement it was —
  plus the results collected before it.``
  [c statements]
  (unless (pq/supports? :pipeline)
    (errorf "postgres: pipeline mode needs libpq 14 or newer (this is %q)"
            (pq/version)))
  (when (empty? statements) (break []))
  (unless (= 1 (pq/PQenterPipelineMode (c :pg)))
    (fail! c "entering pipeline mode"))
  (def out @[])
  (var err nil)
  (defer
    # cleanup, so it runs even when a send / sync / flush above threw:
    # the sync result closes the pipeline and reading it is what keeps
    # the connection out of the mid-protocol state an undrained query
    # leaves — unless it is already broken, when draining is moot and
    # `reusable?` will discard it anyway
    (do
      (when (and (not (c :broken)) (not (c :closed)))
        (protect (while (when-let [r (next-result c)] (pq/PQclear r) true)))
        (put c :in-exchange false))
      (pq/PQexitPipelineMode (c :pg))
      nil)
    (each [sql params] statements
      (send-params c sql params true))
    (unless (= 1 (pq/PQpipelineSync (c :pg)))
      (fail! c "pipeline sync"))
    (flush! c)
    (eachp [i stmt] statements
      (def [ok res] (protect (collect c (first stmt))))
      (if ok
        (array/push out res)
        (unless err
          (set err (merge (if (dictionary? res) res {:message res})
                          {:index i :results (freeze out)}))))))
  (when err (error (freeze err)))
  out)

# -- cancellation --------------------------------------------------------

(defn- cancel-error [handle]
  (or (text (pq/cstr (pq/PQcancelErrorMessage handle))) "unknown"))

(defn- cancel-modern [c]
  (def handle (pq/PQcancelCreate (c :pg)))
  (unless handle (error "postgres: PQcancelCreate returned NULL"))
  (defer (pq/PQcancelFinish handle)
    (unless (= 1 (pq/PQcancelStart handle))
      (errorf "postgres: cancel request failed: %s" (cancel-error handle)))
    (def fds (fdwait/pair (pq/PQcancelSocket handle)))
    (defer (fdwait/release! fds)
      (var dir :write)
      (forever
        (fdwait/refresh! fds (pq/PQcancelSocket handle))
        (unless (fdwait/ready? (fdwait/await fds dir))
          (error "postgres: the cancel connection hung up"))
        (def status (pq/PQcancelPoll handle))
        (cond
          (= status pq/POLLING-OK) (break)
          (= status pq/POLLING-READING) (set dir :read)
          (= status pq/POLLING-WRITING) (set dir :write)
          (errorf "postgres: cancel request failed: %s" (cancel-error handle))))))
  true)

(defn- cancel-legacy [c]
  # PQcancel opens a socket and writes the request synchronously. It is
  # one packet to a server we are already talking to, and it is the
  # only libpq call in this driver that can block the loop — for the
  # length of a TCP connect. libpq 17 replaced it with the poll loop
  # above, which is why this path is the fallback and not the design.
  (def handle (pq/PQgetCancel (c :pg)))
  (unless handle (error "postgres: PQgetCancel returned NULL"))
  (defer (pq/PQfreeCancel handle)
    (def errbuf (buffer/new-filled 256))
    (unless (= 1 (pq/PQcancel handle errbuf 256))
      (errorf "postgres: cancel request failed: %s"
              (string/trim (string (string/slice errbuf 0
                                                 (or (index-of 0 errbuf) 0))))))
    true))

(defn cancel!
  ``Ask the server to abort whatever this connection is running. The
  request goes over a socket of its own, so this is the one thing that
  may be called from a fiber other than the one parked on the query —
  which is the point: a watchdog cancels, the query fiber wakes with
  the error.

  Cancellation is a request, not a guarantee (a statement between
  check points may finish first), and it is not the first tool to
  reach for: a statement_timeout on the connection is enforced by the
  server without anybody having to watch.``
  [c]
  (unless (c :pg) (error "postgres: cannot cancel on a closed connection"))
  (if (pq/supports? :cancel) (cancel-modern c) (cancel-legacy c)))

# -- session facts -------------------------------------------------------

(defn server-version
  "The server's version as [major minor] — 160014 is 16.14; since
  Postgres 10 the second number is the minor release."
  [c]
  (def n (pq/PQserverVersion (c :pg)))
  [(div n 10000) (mod (div n 100) 100)])

(defn backend-pid
  "The server-side process id — what pg_stat_activity lists, and what
  a cancel from elsewhere would target."
  [c]
  (pq/PQbackendPID (c :pg)))

(defn parameter
  "A session parameter the server reported (server_version,
  standard_conforming_strings, TimeZone, ...)."
  [c name]
  (pq/cstr (pq/PQparameterStatus (c :pg) name)))

(defn transaction-status
  ``Where this connection stands: :idle, :active, :in-transaction,
  :in-error (a failed statement inside a transaction — everything
  until ROLLBACK will fail too) or :unknown.``
  [c]
  (def s (pq/PQtransactionStatus (c :pg)))
  (cond
    (= s pq/PQTRANS-IDLE) :idle
    (= s pq/PQTRANS-ACTIVE) :active
    (= s pq/PQTRANS-INTRANS) :in-transaction
    (= s pq/PQTRANS-INERROR) :in-error
    :unknown))

(defn ping
  "A round trip that proves the connection still works."
  [c]
  (execute c "SELECT 1")
  true)
