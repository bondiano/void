### void/db-sqlite/driver — the :void/db-driver contract over
### janet-lang/sqlite3 (SPEC.md §5.10, ROADMAP 2.2).
###
### This is the reference implementation of the driver contract (see
### void/db/driver): a plain dictionary of :dialect/:connect/:close/
### :execute plus the optional keys sqlite can honour. Nothing here
### imports void/db — a driver depends on the *contract*, not on the
### kernel, and the kernel runs the value through `driver/normalize`
### to fill in the documented fallbacks.
###
### What sqlite gives us and what it does not:
###
###   * `sqlite3/eval` compiles, binds and steps one statement. The
###     janet binding exposes no prepare/step pair, so :prepare and
###     :execute-prepared are absent and every statement goes through
###     :execute — sqlite's own statement cache is what saves the
###     recompile.
###   * `sqlite3/eval` prepares *all* statements of a multi-statement
###     string before running any of them, so DDL followed by a
###     statement that depends on it fails, and parameters cannot be
###     spread over several statements. One statement per call: the
###     builder emits one, and a migration that needs several passes
###     them as an array of strings.
###   * Rows come back as tables with keyword column keys — the shape
###     the contract asks for. A NULL column is *absent* from the row
###     (a janet table cannot hold nil), which reads the same through
###     `get` but means a scalar SELECT of NULL yields an empty row.
###   * The affected-row count is `changes()`, one extra statement
###     after a write (in-process, no round trip). It is meaningful
###     for INSERT/UPDATE/DELETE only — after DDL sqlite reports
###     whatever the previous write touched.
###   * Every call is synchronous C: a query blocks the whole ev loop
###     until sqlite returns. That is the deal with an embedded
###     database and it is why `void/db-postgres` (2.2) exists; it
###     also means two fibers are never inside sqlite at once, so the
###     only real concurrency is between statements.
###   * URI filenames are off (SQLITE_USE_URI is a compile-time
###     option the binding does not set), so an in-memory database
###     cannot be shared between connections at all. A pool over
###     ":memory:" therefore gets ONE connection, handed out to every
###     checkout — see `make` and the size check in ../init.

(import sqlite3)

(def dialect
  "Builder dialect this driver speaks (registered by void/db/builder)."
  :sqlite)

(def default-path
  ``What :connect opens when nothing is configured. A file, not
  ":memory:": an in-memory database is one connection wide (see
  `memory-path?`), and a zero-config boot should give a pool that
  works. The directory matches void/db's "db/migrations".``
  "db/void.sqlite3")

# -- paths ---------------------------------------------------------------

(defn memory-path?
  ``True for the paths sqlite keeps out of a shared file: ":memory:"
  and the empty string (a private temporary database). Both are
  *per connection* — two connections to ":memory:" are two different
  empty databases, and this binding cannot say otherwise: URI
  filenames (`file:name?mode=memory&cache=shared`) need sqlite built
  with SQLITE_USE_URI, and janet-lang/sqlite3 is not, so such a path
  is taken literally and becomes a file with a very odd name. Hence
  `check-path!` below and the single shared connection `make` hands
  out for these paths.``
  [path]
  (def s (string path))
  (or (= ":memory:" s) (= "" s)))

(defn check-path!
  ``Refuse a path this binding would silently misread: a URI, which
  `sqlite3_open` takes for a filename because URI processing is a
  compile-time option it was not built with.``
  [path]
  (when (string/has-prefix? "file:" (string path))
    (errorf (string "sqlite: %s is a URI, and janet-lang/sqlite3 opens it as a "
                    "literal filename (no SQLITE_USE_URI) — pass a plain path, "
                    "or \":memory:\" with [:db :pool :size] 1")
            path))
  path)

(defn ensure-directory!
  ``Create the parent directory of a database file, so a configured
  path does not have to be preceded by an mkdir (void/db's
  `migrate/create!` does the same for the migrations directory).``
  [path]
  (def parts (string/split "/" (string path)))
  (when (> (length parts) 1)
    (var acc (if (string/has-prefix? "/" path) "" "."))
    (each part (slice parts 0 -2)
      (unless (empty? part)
        (set acc (string acc "/" part))
        (os/mkdir acc))))
  path)

# -- pragmas -------------------------------------------------------------

(def- word-peg
  (peg/compile ~(* (some (+ (range "az" "AZ" "09") (set "_"))) -1)))

(def- value-peg
  (peg/compile ~(* (some (+ (range "az" "AZ" "09") (set "_-."))) -1)))

(defn pragma-sql
  ``One PRAGMA statement. sqlite binds no parameters inside a PRAGMA,
  so both halves are rendered — and therefore restricted to word
  characters: the config is trusted, but a typo must not be able to
  turn into a second statement. Kebab spelling is accepted on both
  sides (:journal-mode :wal -> PRAGMA journal_mode = WAL).

  Only the spelling is checked here — sqlite silently ignores a pragma
  it does not know and an unknown value for one it does, so a typo in
  [:db-sqlite :pragmas] costs nothing and does nothing.``
  [name value]
  (def n (string/replace-all "-" "_" (string name)))
  (unless (peg/match word-peg n)
    (errorf "sqlite: %q is not a pragma name" name))
  (def v
    (cond
      (boolean? value) (if value "ON" "OFF")
      (number? value) (string value)
      (bytes? value)
      (let [s (string/ascii-upper (string/replace-all "-" "_" (string value)))]
        (unless (peg/match value-peg s)
          (errorf "sqlite: pragma %s cannot take %q" n value))
        s)
      (errorf "sqlite: pragma %s cannot take %q" n value)))
  (string "PRAGMA " n " = " v))

# -- connections ---------------------------------------------------------

(defn- err-str [e]
  (if (string? e) e (describe e)))

(defn open
  ``Open one connection and apply `pragmas` — [[name value] ...], in
  order — to it. A half-open handle is closed before the failure is
  reported, and both the path and the offending pragma are named.``
  [path &opt pragmas]
  (default pragmas [])
  (check-path! path)
  (def [ok conn] (protect (sqlite3/open path)))
  (unless ok
    (errorf "sqlite: cannot open %s: %s" path (err-str conn)))
  (each [name value] pragmas
    (def sql (pragma-sql name value))
    (def [pok e] (protect (sqlite3/eval conn sql)))
    (unless pok
      (protect (sqlite3/close conn))
      (errorf "sqlite %s: %s failed: %s" path sql (err-str e))))
  conn)

(defn close-connection
  "Close a connection — what the component's :stop calls on the one it
  holds itself, past the driver's own :close."
  [conn]
  (sqlite3/close conn))

(defn file-of
  ``The file backing a connection's main database, "" when it has none
  (in memory, or a private temporary database). The honest answer to
  \"did that path really stay out of the filesystem\".``
  [conn]
  (get (first (sqlite3/eval conn "PRAGMA database_list")) :file ""))

(defn version
  "The sqlite library version behind a connection, as a string."
  [conn]
  (get (first (sqlite3/eval conn "SELECT sqlite_version() AS v")) :v "0"))

(defn supports-returning?
  ``Whether a version string is new enough for INSERT ... RETURNING
  (sqlite 3.35, 2021-03). Without it the entity layer re-reads the
  inserted row by `last_insert_rowid`.``
  [ver]
  (def parts (map scan-number (string/split "." (string ver))))
  (def major (get parts 0 0))
  (def minor (get parts 1 0))
  (or (> major 3) (and (= 3 major) (>= minor 35))))

# -- transactions --------------------------------------------------------

(def tx-modes
  ``BEGIN flavours, keyed by the :isolation of `db/with-tx`.
  :immediate is the default: a deferred transaction that reads first
  and writes later has to upgrade its lock, and under a pool that is
  the classic SQLITE_BUSY deadlock — taking the write lock up front
  turns it into an ordinary wait. :serializable is accepted so
  portable code can ask for what sqlite already guarantees.``
  {:deferred "DEFERRED"
   :immediate "IMMEDIATE"
   :exclusive "EXCLUSIVE"
   :serializable "EXCLUSIVE"})

# -- execution -----------------------------------------------------------

(defn- bindable? [v]
  # sqlite binds nil, booleans, numbers and anything byte-like
  # (strings, buffers, and keywords/symbols by their name)
  (or (nil? v) (boolean? v) (number? v) (bytes? v)))

(defn- unbindable
  "[index value] of the first parameter sqlite cannot bind, or nil."
  [params]
  (var found nil)
  (eachp [i v] (or params [])
    (when (and (nil? found) (not (bindable? v)))
      (set found [i v])))
  found)

(defn- run
  ``One statement on one connection. sqlite's own error is what
  propagates — the execution funnel in void/db/state logs the SQL and
  the parameters alongside it — except for the opaque "invalid sql
  value", which is worth turning into the parameter that caused it.``
  [conn sql params]
  (def [ok res] (protect (sqlite3/eval conn sql (or params []))))
  (when ok (break res))
  (when (string/find "invalid sql value" (err-str res))
    (when-let [[i v] (unbindable params)]
      (errorf "sqlite: parameter %d is %q, which has no SQL type — pass a number, string, buffer, boolean or nil"
              (inc i) v)))
  (error res))

(defn- changed
  "Rows the last INSERT/UPDATE/DELETE on this connection touched."
  [conn]
  (get (first (sqlite3/eval conn "SELECT changes() AS n")) :n 0))

(defn make
  ``Build the :void/db-driver value. opts:

    :path       what `sqlite3/open` receives
    :pragmas    [[name value] ...] applied to every new connection
    :tx-mode    default BEGIN flavour, see `tx-modes` (:immediate)
    :returning  does this sqlite have INSERT ... RETURNING
    :shared     one connection to hand to every checkout instead of
                opening more — how an in-memory database is served,
                since it cannot be reached from a second connection
                (`memory-path?`). :close leaves it alone; whoever
                passed it in owns it.

  The kernel normalizes the result (`db/normalize-driver`), which
  fills in the prepared-statement fallbacks this driver does not
  implement.``
  [&opt opts]
  (default opts {})
  (def path (get opts :path default-path))
  (def shared (get opts :shared))
  (def pragmas (get opts :pragmas []))
  (def default-mode (get opts :tx-mode :immediate))
  (defn begin-sql [isolation]
    (def mode (or isolation default-mode))
    (string "BEGIN "
            (or (get tx-modes mode)
                (errorf "sqlite: unknown transaction mode %q (known: %s)"
                        mode
                        (string/join (map |(string/format "%q" $)
                                          (sorted (keys tx-modes)))
                                     " ")))))
  @{:name :sqlite
    :dialect dialect
    :path path
    :returning (truthy? (get opts :returning))

    :connect (fn sqlite-connect [] (or shared (open path pragmas)))
    :close (fn sqlite-close [conn]
             # the shared connection outlives every checkout: closing
             # it here would drop an in-memory database mid-run
             (unless (= conn shared) (sqlite3/close conn)))

    :execute
    (fn sqlite-execute [conn sql params &opt o]
      (def rows (run conn sql params))
      (if (= :select (get o :kind))
        {:rows rows :count (length rows)}
        # a write — or a raw statement that did not say, where the
        # affected count is the only answer worth having. Right for
        # RETURNING too: the rows come back and changes() still counts.
        {:rows rows :count (changed conn)}))

    :ping (fn sqlite-ping [conn] (run conn "SELECT 1" []) true)
    :insert-id (fn sqlite-insert-id [conn _] (sqlite3/last-insert-rowid conn))

    :begin (fn sqlite-begin [conn &opt isolation]
             (run conn (begin-sql isolation) []))
    :commit (fn sqlite-commit [conn] (run conn "COMMIT" []))
    :rollback (fn sqlite-rollback [conn] (run conn "ROLLBACK" []))
    :savepoint (fn sqlite-savepoint [conn n]
                 (run conn (string "SAVEPOINT " n) []))
    :release-savepoint (fn sqlite-release [conn n]
                         (run conn (string "RELEASE SAVEPOINT " n) []))
    :rollback-to-savepoint (fn sqlite-rollback-to [conn n]
                             (run conn (string "ROLLBACK TO SAVEPOINT " n) []))})
