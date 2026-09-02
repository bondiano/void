### void/db/driver — the :void/db-driver contract (SPEC.md §5.9).
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
### `normalize` validates a driver and fills the fallbacks in, so the
### rest of the kernel can call every key unconditionally.

(import void/db/builder :as builder)

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
