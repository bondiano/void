### void/db/conformance/driver — the :void/db-driver conformance suite.
###
### One set of assertions, run against every driver there is. The
### contract (void/db/driver) says a driver is four functions and a
### dialect, that the kernel fills the rest in, and that a failing
### statement classifies into the same `:void.db/*` kind on every
### engine. A suite that only ever ran against sqlite would be a suite
### that never checked the claim — so this file holds the assertions,
### and each driver's own test hands it a driver:
###
###     (import void/db/conformance/driver :as conformance)
###     (conformance/run! "sqlite" (sqlite/make {:path file}))
###
### It ships with void/db, not with the tests, so a driver written
### outside this repository runs the same suite against the same
### kernel it will be plugged into.
###
### Everything here goes through the kernel — `db/run`, `db/with-tx`,
### the pool — because that is the path an application takes: the
### builder renders for the driver's dialect, the funnel wraps the
### driver's error into an envelope, the pool asks `:reusable?` on
### every checkin. A driver that passes its own raw tests and fails
### here has satisfied its own idea of the contract, not the kernel's.
###
### What it does NOT test is what an engine does not share: isolation
### levels, streaming, pipelining, reconnection. Those live in the
### driver's own suite, next to the engine that has them.

(import void/core/errors :as errors)
(import ../builder :as builder)
(import ../driver :as driver)
(import ../pool :as pool)
(import ../state :as db)

# -- what the suite believes about types ---------------------------------
#
# Three engines, three type systems, one claim: what a migration
# declares through the builder's type names round-trips through
# `db/run` on every one of them. Where the engines differ the contract
# names the allowed forms rather than picking a winner:
#
#   :bool      true/false — or 1/0 on an engine with no boolean type
#              (sqlite stores an integer and the driver cannot know
#              the column meant a boolean)
#   :numeric   exact: either a string the engine formats ("10.50") or
#              a number equal to the value when it fits a double
#   :json      accepts JSON text as the parameter; reads back as the
#              decoded value or as the text (sqlite has no json type)
#   :bytes     a buffer in, the same bytes out — NUL included
#   :timestamp text in, the same text out — janet has no date type
#              and the engine's formatting of a wall-clock value is
#              lossless
#   NULL       absent from the row, never present as nil

(defn- bool-of
  "The boolean a stored :bool column reads back as, whatever its spelling."
  [v]
  (case v true true false false 1 true 0 false
    (errorf "a :bool column read back as %q — expected true/false or 1/0" v)))

(def- json-text "{\"a\":1,\"b\":[1,2,3],\"c\":\"x\"}")

(defn- holds-json?
  ``Does a :json column hold the document — decoded by the driver
  (postgres, mysql), or as the text that went in (sqlite)?``
  [v]
  (if (bytes? v)
    (= json-text (string v))
    (and (dictionary? v)
         (= 1 (get v "a"))
         (deep= @[1 2 3] (get v "b"))
         (= "x" (get v "c")))))

(defn- number-of [v]
  (if (number? v) v (scan-number (string v))))

(defn- kind-of
  "Run `f` expecting it to raise; the error's kind (and the envelope)."
  [f]
  (def [ok e] (protect (f)))
  (when ok (error "expected the statement to fail, and it did not"))
  [(errors/kind e) e])

(defn run!
  ``Assert that `drv0` behaves like a `:void/db-driver` when plugged into
  the kernel. `name` names the engine in the failure messages, because
  "a duplicate key did not classify" is a different bug in each of
  them.

  The suite makes its own table (`void_conformance_<pid>`) and drops it
  on the way out; the database it runs in is otherwise untouched, so
  it can share one with a package's other suites.

  opts:
    :sleep-sql  a statement that takes a few seconds on this engine
                ("SELECT pg_sleep(5)", "SELECT SLEEP(5)") — enables the
                cancellation section, which asserts that a query
                cancelled mid-flight leaves the pool a fresh
                connection rather than a poisoned one. Left out on an
                engine with no way to sleep (sqlite) or a driver that
                cannot be interrupted.``
  [name drv0 &opt opts]
  (default opts {})
  (def drv (driver/normalize drv0))
  (defn note [msg] (string name ": " msg))
  (def table (string "void_conformance_" (os/getpid)))
  (def p (pool/make drv {:size 2 :checkout-timeout 5}))

  (defn drop-table! []
    (db/run {:drop-table table :if-exists true} {:prepared false}))

  (defer (do (with-dyns [db/pool-dyn p] (drop-table!))
             (pool/close-all! p))
    (with-dyns [db/pool-dyn p]

      # -- the shape ---------------------------------------------------

      (assert (keyword? (drv :dialect)) (note "a driver names its dialect"))
      (assert (= (drv :dialect) ((db/driver) :dialect))
              (note "and the pool serves that driver"))
      (each k [:connect :close :execute :begin :commit :rollback
               :savepoint :release-savepoint :rollback-to-savepoint :reusable?]
        (assert (function? (drv k))
                (note (string k " is callable after normalize — the kernel never checks"))))

      # -- DDL through the builder -------------------------------------

      (drop-table!)
      (db/run {:create-table table
               :columns [[:id :serial {:primary-key true}]
                         [:email :string {:null false :unique true}]
                         [:admin :bool]
                         [:note :text]
                         [:amount [:raw "numeric(12,2)"]]
                         [:big :bigint]
                         [:ratio :double]
                         [:doc :json]
                         [:raw :bytes]
                         [:at :timestamp]]}
              {:prepared false})
      # the two statements are the assertion: a table declared in the
      # builder's type names compiles on this engine, or they raised.
      # The index goes on :at, not :note — :text is the column no
      # engine promises to index (MySQL wants a prefix length), and the
      # suite asserts what every driver must do, not what one refuses
      (db/run {:create-index (string table "_at_idx") :on table :columns [:at]}
              {:prepared false})

      # -- DML through the builder -------------------------------------

      (def ins (db/run {:insert table :values {:email "a@b.c" :admin true :note "one"}}))
      (assert (= 1 (ins :count)) (note "an insert reports one affected row"))
      (db/execute! {:insert table :values {:email "d@e.f" :admin false}})

      (def rows (db/query {:select [:id :email :admin] :from table :order-by [:id]}))
      (assert (= 2 (length rows)) (note "a select returns its rows"))
      (assert (= "a@b.c" (get (first rows) :email))
              (note "as dictionaries with keyword column keys"))
      (assert (number? (get (first rows) :id)) (note "and a :serial key numbered itself"))
      (assert (= true (bool-of (get (first rows) :admin))) (note "true stored as true"))
      (assert (= false (bool-of (get (get rows 1) :admin))) (note "false stored as false"))

      (assert (= 2 (db/execute! {:update table :set {:note "all"}}))
              (note "an update counts the rows it touched"))
      (assert (= 2 (db/value {:select [[:raw "count(*) AS n"]] :from table}))
              (note "db/value reads a scalar"))
      (assert (= 1 (db/execute! {:delete table :where [:= :email "d@e.f"]}))
              (note "a delete counts the rows it removed"))
      (assert (nil? (db/one {:select [:id] :from table :where [:= :email "d@e.f"]}))
              (note "and the row is gone"))

      # -- parameters and NULL -----------------------------------------

      (db/execute! {:insert table :values {:email "nul@x.y" :note builder/null}})
      (def nul (db/one {:select [:email :note] :from table :where [:= :email "nul@x.y"]}))
      (assert (= "nul@x.y" (nul :email)) (note "a parameter binds by position"))
      (assert (not (in nul :note))
              (note "a NULL column is absent from the row — a janet table cannot hold nil"))
      (assert (nil? (get nul :note)) (note "so reading it gives nil"))

      # -- RETURNING, or its fallback ----------------------------------
      #
      # the entity layer needs the stored row back: RETURNING where the
      # engine has it, :insert-id where it does not. One of the two
      # must work, and the id it names must find the row.
      (def new-id
        (if (drv :returning)
          (do
            (def r (db/run {:insert table :values {:email "ret@x.y"} :returning [:id]}))
            (assert (= 1 (length (r :rows))) (note ":returning true gives the row back"))
            (get (first (r :rows)) :id))
          (db/with-conn
            (def r (db/run {:insert table :values {:email "ret@x.y"}}))
            (def id ((drv :insert-id) (get (dyn db/conn-dyn) :conn) r))
            (assert id (note "without RETURNING, :insert-id knows the new key"))
            id)))
      (assert (= "ret@x.y"
                 (get (db/one {:select [:email] :from table :where [:= :id new-id]}) :email))
              (note "and the id names the stored row"))

      # -- prepared statements, or their fallback ----------------------
      #
      # the kernel prefers the prepared pair when a driver has one and
      # routes through :execute otherwise; the answer is the same both
      # ways and the pool counts the query either way
      (def q0 (get (pool/stats p) :queries))
      (def stmt {:select [:email] :from table :where [:= :email "ret@x.y"]})
      (def via-cache (db/query stmt))
      (def via-plain (db/query stmt {:prepared false}))
      (assert (deep= via-cache via-plain)
              (note (if (driver/supports-prepared? drv)
                      "a prepared statement and a plain one agree"
                      "with no prepared pair, :prepared false changes nothing")))
      (assert (= (+ 2 q0) (get (pool/stats p) :queries))
              (note "the pool counted both"))

      # -- transactions and savepoints ---------------------------------

      (db/with-tx
        (db/execute! {:insert table :values {:email "tx@commit"}}))
      (assert (db/one {:select [:id] :from table :where [:= :email "tx@commit"]})
              (note "a with-tx that returns commits"))

      (def [tok terr] (protect (db/with-tx
                                 (db/execute! {:insert table :values {:email "tx@error"}})
                                 (error "boom"))))
      (assert (not tok) (note "an error inside with-tx propagates"))
      (assert (nil? (db/one {:select [:id] :from table :where [:= :email "tx@error"]}))
              (note "and rolls the write back"))

      (db/with-tx
        (db/execute! {:insert table :values {:email "sp@kept"}})
        (db/with-tx
          (db/execute! {:insert table :values {:email "sp@dropped"}})
          (db/rollback!))
        (assert (db/in-transaction?) (note "the outer transaction survives an inner rollback!")))
      (assert (db/one {:select [:id] :from table :where [:= :email "sp@kept"]})
              (note "a nested with-tx is a savepoint: the outer write committed"))
      (assert (nil? (db/one {:select [:id] :from table :where [:= :email "sp@dropped"]}))
              (note "and the inner one rolled back alone"))

      (assert (nil? (db/with-tx (db/execute! {:insert table :values {:email "tx@quiet"}})
                                (db/rollback!)))
              (note "rollback! at the top level returns nil, not an error"))
      (assert (nil? (db/one {:select [:id] :from table :where [:= :email "tx@quiet"]}))
              (note "and nothing was written"))

      # -- errors classify the same everywhere -------------------------
      #
      # the whole point of the SQLSTATE in the driver's error form:
      # jobs-db asks `(errors/kind? e :void.db/unique-violation)` and
      # never reads a message, so every engine has to answer the same
      (def [dup-kind dup] (kind-of |(db/execute! {:insert table :values {:email "a@b.c"}})))
      (assert (= :void.db/unique-violation dup-kind)
              (note (string "a duplicate key is :void.db/unique-violation, got " dup-kind)))
      (assert (errors/kind? dup :void.db/unique-violation) (note "and kind? agrees"))
      (assert (= 409 (errors/status dup)) (note "with the conflict status"))
      (def data (errors/data dup))
      (assert (get data :sqlstate) (note "the SQLSTATE rides along under :data"))
      (assert (string/has-prefix? "23" (string (data :sqlstate)))
              (note "and is of the integrity class"))
      (assert (= (drv :name) (get data :driver)) (note "naming the driver"))
      (assert (string? (errors/message dup)) (note "with the engine's own message"))

      (def [null-kind] (kind-of |(db/execute! {:insert table :values {:email builder/null}})))
      (assert (= :void.db/not-null-violation null-kind)
              (note (string "a NULL into a NOT NULL column is :void.db/not-null-violation, got " null-kind)))

      (def [missing-kind] (kind-of |(db/query {:select [:id] :from "void_no_such_table_xyz"})))
      (assert (= :void.db/syntax missing-kind)
              (note (string "a missing table is :void.db/syntax, got " missing-kind)))

      (def [syntax-kind] (kind-of |(db/execute-sql "SELEC 1" [] {:prepared false})))
      (assert (= :void.db/syntax syntax-kind)
              (note (string "a malformed statement is :void.db/syntax, got " syntax-kind)))

      (assert (= 1 (db/value {:select [[:raw "count(*) AS n"]] :from table
                              :where [:= :email "a@b.c"]}))
              (note "the connection still answers after a failed statement"))

      (db/with-tx
        (def [ok] (protect (db/with-tx
                             (db/execute! {:insert table :values {:email "a@b.c"}}))))
        (assert (not ok) (note "a failing savepoint raises"))
        (db/execute! {:insert table :values {:email "after@dup"}}))
      (assert (db/one {:select [:id] :from table :where [:= :email "after@dup"]})
              (note "and the enclosing transaction goes on after it"))

      # -- :reusable? ----------------------------------------------------

      (db/with-conn
        (def entry (dyn db/conn-dyn))
        (db/query {:select [:id] :from table :limit 1})
        (assert (driver/reusable? drv (entry :conn))
                (note "a connection that finished a query is reusable"))
        (protect (db/query {:select [:id] :from "void_no_such_table_xyz"}))
        (assert (driver/reusable? drv (entry :conn))
                (note "and so is one whose statement failed — an error is not a half-read result")))
      (assert (zero? (get (pool/stats p) :in-use)) (note "with-conn returned it to the pool"))

      # -- the type contract -------------------------------------------

      (def raw-bytes @"\xff\x00\x01abc")
      (db/execute! {:insert table
                    :values {:email "types@x.y"
                             :amount "10.50"
                             :big 1099511627776
                             :ratio 2.5
                             :doc json-text
                             :raw raw-bytes
                             :at "2026-09-05 12:34:56"}})
      (def row (db/one {:select [:amount :big :ratio :doc :raw :at]
                            :from table :where [:= :email "types@x.y"]}))
      (assert (= 10.5 (number-of (row :amount)))
              (note (string "a :numeric reads back exact, got " (string/format "%q" (row :amount)))))
      (assert (= 1099511627776 (number-of (row :big)))
              (note "a :bigint past 32 bits reads back intact"))
      (assert (= 2.5 (row :ratio)) (note "a :double reads back as a number"))
      (assert (holds-json? (row :doc))
              (note (string "a :json column holds the document, got " (string/format "%q" (row :doc)))))
      (assert (bytes? (row :raw)) (note "a :bytes column reads back as bytes"))
      (assert (= (string raw-bytes) (string (row :raw)))
              (note "the same bytes, NUL included"))
      (assert (string/has-prefix? "2026-09-05 12:34:56" (string (row :at)))
              (note (string "a :timestamp reads back as the text that went in, got "
                            (string/format "%q" (row :at)))))

      # -- a query cancelled mid-flight ---------------------------------
      #
      # the fiber holding the only connection is cancelled while the
      # engine is still working. The pool must not hand the next caller
      # a connection with an unread result on it: :reusable? says no
      # and the entry is discarded
      (when-let [sleep-sql (get opts :sleep-sql)]
        (def p1 (pool/make drv {:size 1 :checkout-timeout 5}))
        (defer (pool/close-all! p1)
          (with-dyns [db/pool-dyn p1]
            (def sup (ev/chan 1))
            (def f (ev/go (fn [] (with-dyns [db/pool-dyn p1]
                                   (db/query [sleep-sql []])))
                          nil sup))
            (ev/sleep 0.2)
            (assert (= 1 (get (pool/stats p1) :in-use))
                    (note "the sleeping query holds the connection"))
            (ev/cancel f :timed-out)
            (ev/take sup)
            (def s (pool/stats p1))
            (assert (zero? (s :in-use)) (note "a cancelled query leaves nothing in use"))
            (assert (zero? (s :created))
                    (note "and the connection it was cancelled on was discarded, not pooled"))
            (assert (= 1 (db/value {:select [[:raw "count(*) AS n"]] :from table
                                    :where [:= :email "types@x.y"]}))
                    (note "the pool serves the next query on a fresh connection")))))))

  (printf "%s: db-driver conformance OK" name)
  true)
