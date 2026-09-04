### void/db/driver — the :void/db-driver contract.
###
### A driver is a plain dictionary produced by a driver component's
### :start (the component declares :provides [:void/db-driver], so the
### config picks the implementation and the kernel never names it).
### Required keys:
###
###   :dialect  builder dialect name (:sqlite, :postgres, ...)
###   :connect  (fn [] conn)            — one raw connection
###   :close    (fn [conn])
###   :execute  (fn [conn sql params opts] result)
###
### `result` is {:rows [row ...] :count n}: rows are dictionaries with
### keyword column keys, :count the affected-row count for writes.
### opts carries per-call hints — currently {:kind :select|:write}.
###
### Optional keys, each with a documented fallback so a minimal driver
### stays a four-liner:
###
###   :prepare / :execute-prepared  prepared-statement cache (falls back
###                                 to :execute)
###   :begin / :commit / :rollback  transaction control (falls back to
###                                 plain SQL through :execute)
###   :savepoint / :release-savepoint / :rollback-to-savepoint
###                                 nested transactions (falls back to
###                                 SAVEPOINT SQL)
###   :ping                         liveness check for pooled entries
###   :insert-id                    (fn [conn result] id) — last insert
###                                 id where RETURNING is unavailable
###   :reusable?                    (fn [conn] bool) — is the connection
###                                 safe to return to the pool, or was an
###                                 operation left mid-protocol (a
###                                 cancelled query, an undrained result
###                                 stream)? Falls back to always-yes: a
###                                 synchronous driver has no such state.
###
### plus the flag :returning — true when INSERT ... RETURNING gives the
### stored row back (the entity layer re-reads by insert id otherwise).
###
### **Errors.** A statement that fails raises a dictionary:
###
###   {:db/error <driver name>   ; :postgres, :mysql, :sqlite, ...
###    :message  "..."           ; the server's text, as it said it
###    :sqlstate "23505"}        ; the SQLSTATE — the key a caller branches on
###
### plus whatever the driver knows (:code, :constraint, :detail, :sql).
### A driver whose engine has no SQLSTATE (sqlite) synthesizes one of
### the same class from what it does know; a driver that raised a bare
### string still works and classifies as :void.db/error. The kernel's
### execution funnel (state/execute-sql) turns every one of them into
### an error envelope (void/core/errors) whose kind is decided by the
### SQLSTATE class — `classify` below — so jobs-db asks
### `(errors/kind? e :void.db/unique-violation)` on every engine and
### never reads a message. The driver's dictionary rides along under
### :data, :sqlstate beside it.
###
### `normalize` validates a driver and fills the fallbacks in, so the
### rest of the kernel can call every key unconditionally.

(import void/core/errors :as errors)
(import void/db/builder :as builder)

# -- the error form ------------------------------------------------------

(each [kind info]
  [[:void.db/error {:doc "a statement failed and nothing below was more specific; :data {:sqlstate :driver :driver-error}"}]
   [:void.db/unique-violation {:status 409 :doc "an INSERT or UPDATE hit a unique index (SQLSTATE 23505, mysql 1062)"}]
   [:void.db/foreign-key-violation {:status 409 :doc "a row referenced something that is not there, or is still referenced (23503)"}]
   [:void.db/not-null-violation {:status 422 :doc "a NOT NULL column was given nothing (23502)"}]
   [:void.db/check-violation {:status 422 :doc "a CHECK constraint refused the row (23514)"}]
   [:void.db/constraint-violation {:status 409 :doc "another integrity constraint (class 23)"}]
   [:void.db/serialization-failure {:doc "the transaction lost a serialization race and is worth retrying whole (40001)"}]
   [:void.db/deadlock {:doc "the engine broke a deadlock by killing this transaction (40P01, mysql 1213)"}]
   [:void.db/connection {:status 503 :doc "the connection is gone, or could not be made (class 08)"}]
   [:void.db/syntax {:doc "the SQL was wrong, or named something the schema does not have (class 42)"}]
   [:void.db/data {:status 422 :doc "a value did not fit its column (class 22)"}]
   [:void.db/timeout {:status 503 :doc "the statement was cancelled or waited too long for a lock (57014, 55P03, mysql 1205)"}]
   [:void.db/transaction {:doc "BEGIN, COMMIT or ROLLBACK itself failed; the connection was discarded"}]
   [:void.db/pool-timeout {:status 503 :doc "no connection became free within [:db :pool :checkout-timeout]"}]
   [:void.db/not-found {:status 404 :doc "entity/find! found no row; :data {:entity :id}"}]]
  (errors/define! kind info))

(def- mysql-codes
  "MySQL says 23000 for every integrity violation; the errno tells them
  apart, and a few of its states are not SQLSTATEs at all (HY000)."
  {1062 :void.db/unique-violation
   1451 :void.db/foreign-key-violation
   1452 :void.db/foreign-key-violation
   1048 :void.db/not-null-violation
   3819 :void.db/check-violation
   1213 :void.db/deadlock
   1205 :void.db/timeout
   2006 :void.db/connection
   2013 :void.db/connection
   1064 :void.db/syntax
   1146 :void.db/syntax})

(defn classify
  ``The error kind for a driver's `{:sqlstate ... :code ...}` — by the
  SQLSTATE, with MySQL's errno breaking the ties its 23000 leaves.``
  [e]
  (def code (get e :code))
  (def state (string (or (get e :sqlstate) "")))
  (def class (if (>= (length state) 2) (string/slice state 0 2) ""))
  (or (when (and (= :mysql (get e :db/error)) (int? code)) (get mysql-codes code))
      (case state
        "23505" :void.db/unique-violation
        "23503" :void.db/foreign-key-violation
        "23502" :void.db/not-null-violation
        "23514" :void.db/check-violation
        "40001" :void.db/serialization-failure
        "40P01" :void.db/deadlock
        "57014" :void.db/timeout
        "55P03" :void.db/timeout
        nil)
      (case class
        "23" :void.db/constraint-violation
        "08" :void.db/connection
        "42" :void.db/syntax
        "22" :void.db/data
        "40" :void.db/serialization-failure
        "57" :void.db/timeout
        nil)
      :void.db/error))

(defn wrap-error
  ``The error envelope for whatever a driver raised: its dictionary
  classified by SQLSTATE (the dictionary itself, :sqlstate, :code,
  :constraint and the driver's name in :data), a bare string as
  :void.db/error with the string for a message. An envelope already
  is one and passes through.``
  [e &opt sql]
  (cond
    (errors/error? e) e
    (dictionary? e)
    (errors/make (classify e)
                 (string (get e :message "the driver reported an error"))
                 {:driver (get e :db/error)
                  :sqlstate (get e :sqlstate)
                  :code (get e :code)
                  :constraint (get e :constraint)
                  :sql (or sql (get e :sql))
                  :driver-error e})
    (errors/make :void.db/error (if (bytes? e) (string e) (describe e))
                 {:sql sql :driver-error e})))

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(def- required [:connect :close :execute])

(def- optional
  [:prepare :execute-prepared :begin :commit :rollback
   :savepoint :release-savepoint :rollback-to-savepoint
   :ping :insert-id :reusable?])

(defn normalize
  ``Validate a driver dictionary and fill in the documented fallbacks.
  Returns a frozen driver value; throws with the offending key on any
  contract violation.``
  [drv]
  (unless (dictionary? drv)
    (errorf "db driver must be a dictionary, got %q" drv))
  (def name (get drv :name :anonymous))
  (def dialect (get drv :dialect))
  (unless (keyword? dialect)
    (errorf "db driver %q: :dialect must be a keyword, got %q" name dialect))
  # fails fast with the list of registered dialects
  (builder/dialect dialect)
  (each k required
    (unless (callable? (get drv k))
      (errorf "db driver %q: %q must be a function, got %q" name k (get drv k))))
  (each k optional
    (when-let [f (get drv k)]
      (unless (callable? f)
        (errorf "db driver %q: %q must be a function, got %q" name k f))))
  (unless (nil? (get drv :returning))
    (unless (boolean? (get drv :returning))
      (errorf "db driver %q: :returning must be a boolean, got %q"
              name (get drv :returning))))
  (def execute (drv :execute))
  (defn raw [conn sql]
    (execute conn sql [] {:kind :write}))
  (freeze
    (merge
      @{:name name
        :returning false
        :prepare nil
        :execute-prepared nil
        :ping nil
        :insert-id nil
        # a synchronous driver is never mid-protocol: a cancel can only
        # land at an ev yield, and it has none inside a statement
        :reusable? (fn reusable [conn] true)
        :begin (fn begin [conn &opt isolation]
                 (when isolation
                   (errorf "db driver %q has no :begin — (db/with-tx {:isolation %q} ...) needs driver support"
                           name isolation))
                 (raw conn "BEGIN"))
        :commit (fn commit [conn] (raw conn "COMMIT"))
        :rollback (fn rollback [conn] (raw conn "ROLLBACK"))
        :savepoint (fn savepoint [conn n] (raw conn (string "SAVEPOINT " n)))
        :release-savepoint
        (fn release [conn n] (raw conn (string "RELEASE SAVEPOINT " n)))
        :rollback-to-savepoint
        (fn rollback-to [conn n] (raw conn (string "ROLLBACK TO SAVEPOINT " n)))}
      drv)))

(defn supports-prepared?
  "True when the driver implements the prepared-statement pair."
  [drv]
  (and (drv :prepare) (drv :execute-prepared) true))

(defn reusable?
  ``Is `conn` safe to return to the pool — no operation left
  mid-protocol? The kernel asks before every checkin and discards a
  connection that says no (see void/db/pool, void/db/state).``
  [drv conn]
  ((drv :reusable?) conn))

(defn result
  "Build a driver result — sugar for driver authors:
  (driver/result rows) / (driver/result rows {:count 3})."
  [rows &opt extra]
  (default extra {})
  (merge @{:rows (or rows []) :count (get extra :count (length (or rows [])))}
         extra))
