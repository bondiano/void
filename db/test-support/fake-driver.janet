# A :void/db-driver that answers from a script instead of a database:
# every statement is recorded, and the responder (a function of sql and
# params) decides what comes back. It keeps the kernel's own tests
# honest about the SQL they cause — one batched IN per preload, a
# partial UPDATE from save!, BEGIN/SAVEPOINT/COMMIT order — without
# waiting for a real driver (void/db-sqlite).
#
# The mutable state lives outside the driver value, since
# driver/normalize freezes it.

(defn make
  ``[driver state]. opts:
    :dialect    builder dialect (default :ansi)
    :returning  does INSERT ... RETURNING give the row back
    :responder  (fn [sql params] result-or-nil)
    :gate       a channel every :execute parks on (ev/take) before
                answering — how a test simulates a slow query it can
                cancel mid-protocol. While parked the connection is
                marked :in-exchange, so a cancel there leaves it
                unusable and `:reusable?` reports so (H1).
    :fail-connect / :connect-hook for pool tests.``
  [&opt opts]
  (default opts {})
  (def st @{:log @[] :conns 0 :closed 0 :open @[]
            :responder (get opts :responder)})
  (def gate (get opts :gate))
  (def drv
    @{:name :fake
      :dialect (get opts :dialect :ansi)
      :returning (get opts :returning false)
      :connect (fn fake-connect []
                 (when-let [h (get opts :connect-hook)] (h st))
                 (put st :conns (inc (st :conns)))
                 (def conn @{:id (st :conns) :in-exchange false})
                 (array/push (st :open) conn)
                 conn)
      :close (fn fake-close [conn]
               (put st :closed (inc (st :closed)))
               (put conn :closed true))
      # a synchronous statement is never mid-protocol; a gated one is,
      # until it clears :in-exchange after the (simulated) reply
      :reusable? (fn fake-reusable [conn] (not (conn :in-exchange)))
      :execute (fn fake-execute [conn sql params &opt o]
                 (put conn :in-exchange true)
                 (when gate (ev/take gate))
                 (array/push (st :log) {:sql sql
                                        :params (tuple ;params)
                                        :conn (conn :id)})
                 (def result (or (when-let [r (st :responder)] (r sql params))
                                 @{:rows [] :count 0}))
                 (put conn :in-exchange false)
                 result)})
  [drv st])

(defn log
  "Every statement the driver saw, as {:sql :params :conn}."
  [st]
  (st :log))

(defn sqls
  "Just the SQL strings, in order."
  [st]
  (map |($ :sql) (st :log)))

(defn clear! [st]
  (array/clear (st :log))
  st)

(defn matching
  "Statements whose SQL contains a substring."
  [st needle]
  (filter |(string/find needle ($ :sql)) (st :log)))

(defn rows-responder
  ``A responder from a table of {sql-substring [rows...]} — the first
  matching entry answers, everything else comes back empty.``
  [spec]
  (fn respond [sql _]
    (var out nil)
    (eachp [needle rows] spec
      (when (and (nil? out) (string/find needle sql))
        (set out @{:rows rows :count (length rows)})))
    out))
