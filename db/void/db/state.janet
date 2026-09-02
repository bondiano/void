### void/db/state — the runtime: current pool, dyn-scoped connections,
### statement execution and transactions (SPEC.md §5.9, ADR-0009).
###
### A checkout lives in a dyn (:void.db/conn), so every call inside
### `with-conn` — repository, builder statements, raw SQL — shares one
### connection and the checkout is returned when the scope exits, on
### the error path too. `with-tx` is the same idea with explicit
### boundaries: the outermost scope drives BEGIN/COMMIT/ROLLBACK, an
### inner one takes a SAVEPOINT (nesting is real, not silently merged),
### and nothing flushes behind your back — there is no Unit of Work
### (ADR-0009).
###
### Execution is the single funnel every statement passes through:
### format-by-dialect, prepared-statement reuse where the driver has
### them, timing into the pool metrics and a :debug log line carrying
### sql/params/duration. void/obs (wave 3) hangs its instrumentation on
### the same funnel.

(import void/core/log :as log)
(import ./builder :as builder)
(import ./driver :as driver)
(import ./pool :as pool)

(def log-ns
  "Log namespace of the query funnel — spelled out, since the
  file-derived default would carry the install path."
  "void.db.query")

(def conn-dyn
  "Dynamic binding: the checked-out connection entry of this fiber."
  :void.db/conn)

(def pool-dyn
  "Dynamic binding: pool override — set it to run a scope against a
  pool other than the started :db/pool component (tests, tooling)."
  :void.db/pool)

(def tx-dyn
  "Dynamic binding: {:depth n} inside `with-tx`."
  :void.db/tx)

(var current-pool
  "The pool of the running :db/pool component (set by its :start). One
  per process, like plugin/current-boot."
  nil)

(defn active-pool
  "The pool this fiber runs against: the `pool-dyn` override, else the
  started component's pool."
  []
  (or (dyn pool-dyn)
      current-pool
      (error "void/db is not started — no :db/pool component (or bind the pool-dyn dynamic)")))

(defn driver
  "The driver behind the active pool."
  []
  (pool/driver-of (active-pool)))

(defn in-transaction?
  "True inside a `with-tx` scope."
  []
  # a real tx-dyn is a {:depth n} table; `detached` binds it to false to
  # sever the parent's transaction across an ev/go, so test truthiness,
  # not just non-nil
  (truthy? (dyn tx-dyn)))

# -- connection scope ----------------------------------------------------

(defn with-conn*
  ``Run (f entry) with a connection checked out into `conn-dyn`.
  Re-entrant: an already-bound connection (an enclosing scope or a
  transaction) is reused and not returned early.

  WARNING: a fiber started with `ev/go` inside this scope inherits
  `conn-dyn` and would share this connection — two fibers on one
  connection is the protocol error the pool exists to prevent. Run such
  a fiber inside `(db/detached ...)`, which severs the inherited db
  bindings; using the connection from another fiber is refused
  (`execute-sql` checks the owner).``
  [f]
  (if-let [entry (dyn conn-dyn)]
    (f entry)
    (do
      (def p (active-pool))
      (def entry (pool/checkout p))
      # the task that checked the connection out is the only one allowed
      # to run statements on it (see the ev/go warning above). fiber/root,
      # not fiber/current: the identity has to survive the inline child
      # fibers that with-dyns/defer/protect run the body in, yet differ
      # across ev/go tasks — which is exactly the task root
      (put entry :owner (fiber/root))
      # on any exit — a normal return, an error, or a fiber cancelled
      # mid-query — a connection the driver reports as left mid-protocol
      # (a cancelled query, an undrained result stream) is discarded, not
      # handed to the next owner to read the previous one's result
      (defer (do (unless (driver/reusable? (pool/driver-of p) (entry :conn))
                   (pool/discard! entry))
                 (pool/checkin p entry))
        (with-dyns [conn-dyn entry]
          (f entry))))))

(defn detached*
  ``Run (f) with this fiber's db bindings (the checked-out connection
  and the open transaction) cleared. A fiber started with `ev/go`
  inherits the dyns of the fiber that spawned it, so a child started
  inside `with-conn`/`with-tx` would otherwise share the parent's
  connection; `detached` gives it a clean slate — its own checkout.``
  [f]
  # false, not nil: a fiber's dyn table chains to its parent's, so a nil
  # binding falls through to the inherited value; false overrides it and
  # still reads as "no connection / no transaction" (see with-conn*,
  # in-transaction?, run-tx)
  (with-dyns [conn-dyn false tx-dyn false] (f)))

(defmacro with-conn
  ``Run the body against one connection from the pool:

      (db/with-conn
        (db/query {:select [:*] :from "users"})
        (db/execute! {:update "users" :set {:seen-at now}}))

  Re-entrant, and implied by every single statement — reach for it
  when several statements must share a connection without being a
  transaction.``
  [& body]
  ~(,with-conn* (fn with-conn-body [_] ,;body)))

(defmacro detached
  ``Run the body with the db bindings cleared — for a fiber spawned with
  `ev/go` from inside a connection or transaction scope:

      (db/with-conn
        (ev/go (fn [] (db/detached
                        (db/query {:select [:*] :from "audit"})))))

  Without it the child inherits the parent's connection dyn and the two
  fibers race on one connection (which `execute-sql` refuses).``
  [& body]
  ~(,detached* (fn detached-body [] ,;body)))

# -- execution -----------------------------------------------------------

(defn- prepared-for [drv entry sql]
  (or (get-in entry [:stmts sql])
      (let [stmt ((drv :prepare) (entry :conn) sql)]
        (put-in entry [:stmts sql] stmt)
        stmt)))

(defn execute-sql
  ``Run raw SQL with positional parameters on the current connection
  (checking one out when none is bound). Returns the driver result
  {:rows [...] :count n}.

  opts: :kind (:select | :write, a hint drivers may use), :prepared
  (false disables the prepared-statement cache for this call).

  Parameter values reach the log only on the :debug line (and on a
  failure): keep them out of production sinks with the level, or with
  a :redact path if a query carries secrets.``
  [sql params &opt opts]
  (default opts {})
  (with-conn*
    (fn run-statement [entry]
      # the pool hands one connection to one fiber; a statement run from
      # a different fiber than checked it out means an ev/go child
      # inherited conn-dyn and is about to race the owner on the wire
      (when-let [owner (get entry :owner)]
        (unless (= owner (fiber/root))
          (error (string "db: connection used from a fiber other than the one "
                         "that checked it out — a fiber started with ev/go "
                         "inside with-conn/with-tx inherits :void.db/conn; run "
                         "it inside (db/detached ...)"))))
      (def p (active-pool))
      (def drv (pool/driver-of p))
      (def t0 (os/clock :monotonic))
      (def [ok res]
        (protect
          (if (and (driver/supports-prepared? drv)
                   (not= false (get opts :prepared)))
            ((drv :execute-prepared) (entry :conn) (prepared-for drv entry sql)
                                     params opts)
            ((drv :execute) (entry :conn) sql params opts))))
      (def us (math/round (* 1_000_000 (- (os/clock :monotonic) t0))))
      (pool/note-query! p us)
      (unless ok
        (log/error "db query failed" :ns log-ns
                   :sql sql :params params :us us
                   :err (if (string? res) res (describe res)))
        (error res))
      (log/debug "db query" :ns log-ns
                 :sql sql :params params :us us
                 :rows (length (get res :rows [])))
      res)))

(defn run
  ``Compile a statement map (see void/db/builder) for the driver's
  dialect and execute it. Returns the driver result.``
  [stmt &opt opts]
  (default opts {})
  (if (dictionary? stmt)
    (let [[sql params] (builder/format stmt ((driver) :dialect))]
      (execute-sql sql params
                   (merge @{:kind (if (get stmt :select) :select :write)} opts)))
    (errorf "db: expected a statement map, got %q" stmt)))

(defn query
  "Run a statement (or [sql params]) and return its rows."
  [stmt &opt opts]
  (def res
    (if (indexed? stmt)
      (execute-sql (first stmt) (get stmt 1 []) (merge @{:kind :select} (or opts {})))
      (run stmt opts)))
  (get res :rows []))

(defn one
  "Run a statement and return its first row, or nil. A :select gets
  :limit 1 unless it already caps itself."
  [stmt &opt opts]
  (def capped
    (if (and (dictionary? stmt) (get stmt :select) (nil? (get stmt :limit)))
      (merge stmt {:limit 1})
      stmt))
  (first (query capped opts)))

(defn value
  ``Run a single-column statement and return that column of the first
  row — for scalar selects like
  {:select [[:raw "count(*) AS n"]] :from "users"}.``
  [stmt &opt opts]
  (when-let [row (one stmt opts)]
    (if (dictionary? row)
      (let [ks (keys row)]
        (unless (= 1 (length ks))
          (errorf "db/value expects a single-column row, got columns %q" (sorted ks)))
        (get row (first ks)))
      (first row))))

(defn execute!
  "Run a write statement and return the affected-row count."
  [stmt &opt opts]
  (get (run stmt opts) :count 0))

# -- transactions --------------------------------------------------------

(def- rollback-signal :void.db/rollback)

(defn rollback!
  "Abort the innermost `with-tx` scope without an error: the
  transaction (or savepoint) rolls back and `with-tx` returns nil."
  []
  (unless (in-transaction?)
    (error "db/rollback! called outside a transaction"))
  (error rollback-signal))

(defn- rollback-signal? [e]
  (= rollback-signal e))

(defn- tx-error [entry what e]
  # a failed COMMIT/ROLLBACK leaves the connection in an unknown state:
  # never hand it back to the pool
  (pool/discard! entry)
  (errorf "db transaction %s failed: %s"
          what (if (string? e) e (describe e))))

(defn- run-tx [entry depth opts f]
  (def drv (driver))
  (def sp (when (pos? depth) (string "void_sp_" depth)))
  (if sp
    ((drv :savepoint) (entry :conn) sp)
    (let [[ok e] (protect ((drv :begin) (entry :conn) (get opts :isolation)))]
      (unless ok (tx-error entry "begin" e))))
  (def [ok res] (protect (with-dyns [tx-dyn {:depth depth}] (f))))
  (cond
    ok
    (do
      (def [cok ce]
        (protect (if sp
                   ((drv :release-savepoint) (entry :conn) sp)
                   ((drv :commit) (entry :conn)))))
      (unless cok (tx-error entry "commit" ce))
      res)

    (do
      (def [rok re]
        (protect (if sp
                   ((drv :rollback-to-savepoint) (entry :conn) sp)
                   ((drv :rollback) (entry :conn)))))
      (unless rok (tx-error entry "rollback" re))
      (if (rollback-signal? res) nil (error res)))))

(defn with-tx*
  ``Run (f) inside a transaction on one connection. Nested scopes take
  a savepoint. opts: :isolation (passed to the driver's :begin).``
  [opts f]
  (with-conn*
    (fn tx-scope [entry]
      (def depth (if-let [tx (dyn tx-dyn)] (inc (tx :depth)) 0))
      (run-tx entry depth opts f))))

(defmacro with-tx
  ``Run the body in a transaction — the only transaction boundary in
  void/db (ADR-0009: no Unit of Work, nothing flushes implicitly):

      (db/with-tx
        (db/insert! Order attrs)
        (db/update! User (u :id) {:balance new}))

      (db/with-tx {:isolation :serializable} ...)

  Nested `with-tx` scopes become savepoints. The body's value is the
  result; any error rolls back and propagates, and `(db/rollback!)`
  rolls back returning nil.``
  [& body]
  (def [opts forms]
    (if (and (> (length body) 1) (dictionary? (first body)))
      [(first body) (drop 1 body)]
      [{} body]))
  ~(,with-tx* ,opts (fn with-tx-body [] ,;forms)))
