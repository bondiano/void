(import ../test-support/paths)
(import ../test-support/postgres :as pg)
(import void/core/log :as log)
(import void/db/driver :as driver)
(import void/db/pool :as pool)
(import void/db/state :as db)
(import void/db-sqlite/driver :as sqlite)
(import void/bus/backend :as backend)
(import void/bus/codec :as codec)
(import void/bus/db :as busdb)
(import void/bus/memory :as memory)
(import void/bus/router :as router)
(import void/bus/state :as state)

(each ns ["void.db" "void.db.query" "void.bus" "void.bus.db"]
  (log/set-level! ns :fatal))

# Exit criterion 2 of wave 3, in one file: **a message published
# through the outbox is not lost, and is not published when the
# transaction that wrote it rolls back.**
#
# The two halves are the same claim from either side, and neither is
# provable by looking at the code: the first needs a forwarder that
# runs after the commit, the second needs a rollback that takes a row
# with it. Both run on every engine the backend supports — sqlite
# always, Postgres when VOID_TEST_PG names a server, because a
# transaction is exactly the thing two engines are entitled to disagree
# about.

(def sandbox (string (os/cwd) "/.tmp-bus-outbox-" (os/time) "-" (os/getpid)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(defn- pending [b]
  (db/with-conn ((b :outbox-count))))

(defn- log-size [table]
  (db/with-conn
    (get (first (db/query [(string "SELECT count(*) AS n FROM " table) []])) :n 0)))

(defn run-suite! [label table settle]
  (def b (backend/normalize (busdb/store {:table table :poll-interval 0.05})))
  (def delivered @[])
  (each n (router/defined) (router/forget! n))
  (router/define! :outbox-consumer {:topic :money/*}
                  {:fn (fn [m] (array/push delivered (m :payload)))})

  (def br (state/make b (codec/normalize codec/json)
                      {:group (keyword "outbox-" label)
                       :dedup {:enabled true :window 300}
                       :poison {:enabled false} :retry {:enabled false}}))
  (put br :outbox (b :outbox-write!))

  (with-dyns [state/broker-dyn br]
    (state/start-consumers! br)
    (ev/sleep settle)

    # -- it is not published while the transaction is open -------------

    (var seen-inside nil)
    (db/with-tx
      (state/publish-tx! :money/debited {:account "a" :amount 10})
      (set seen-inside (length delivered)))
    (assert (zero? seen-inside)
            (string label ": nothing is on the bus while the transaction is still open"))

    # -- it is not lost -------------------------------------------------

    (assert (= 1 (pending b))
            (string label ": a committed publish-tx! is a row the forwarder owes"))
    (def f (busdb/start-forwarder! (busdb/make-forwarder b {:interval 0.02 :batch 10})))
    (ev/sleep (* 4 settle))
    (busdb/stop-forwarder! f)
    (assert (zero? (pending b))
            (string label ": the forwarder drains what committed"))
    (assert (= 1 (length delivered))
            (string label ": and the message reaches a consumer — it is not lost"))
    (assert (= 10 (get-in delivered [0 "amount"])))

    # -- it is not published when the transaction rolls back -----------

    (array/clear delivered)

    (assert (nil? (db/with-tx
                    (state/publish-tx! :money/debited {:account "b" :amount 20})
                    (db/rollback!)))
            (string label ": an explicit rollback returns nil"))
    (assert (zero? (pending b))
            (string label ": and takes the outbox row with it"))

    (def [ok _]
      (protect (db/with-tx
                 (state/publish-tx! :money/debited {:account "c" :amount 30})
                 (error "the business rule said no"))))
    (assert (not ok) (string label ": the error propagates"))
    (assert (zero? (pending b))
            (string label ": and an aborted transaction publishes nothing"))

    (def f2 (busdb/start-forwarder! (busdb/make-forwarder b {:interval 0.02 :batch 10})))
    (ev/sleep (* 4 settle))
    (busdb/stop-forwarder! f2)
    (assert (empty? delivered)
            (string label ": a message whose transaction rolled back never reaches a consumer"))

    # -- the window the outbox does leave: a duplicate, not a loss -----
    #
    # A forwarder that published and died before marking the row
    # republishes on its next pass. That is the direction to fail in,
    # and with this backend the *log itself* closes it: the insert is
    # `ON CONFLICT (id) DO NOTHING`, so the republished message is the
    # same row and no consumer sees it twice. The dedup middleware —
    # on for this broker — is the same answer one layer up, for a
    # backend whose log cannot recognise an id it has already stored.

    (db/with-tx (state/publish-tx! :money/credited {:account "d" :amount 40}))
    (def row (first (db/with-conn ((b :outbox-pending) 1))))
    (def env @{:id (get row :id) :topic (keyword (get row :topic))
               :body (get row :body) :meta-body (get row :meta)})
    ((b :publish!) env)                     # published...
    (ev/sleep (* 2 settle))                 # ...and the process dies here
    (assert (= 1 (length delivered)))
    (assert (= 1 (pending b))
            (string label ": the row is still owed, because nothing marked it"))

    (busdb/forward-once! b 10)              # the next pass republishes
    (ev/sleep (* 2 settle))
    (assert (= 1 (length delivered))
            (string label ": the republished message is the same row, and is handled once"))
    (assert (zero? (pending b)))

    (state/stop-consumers! br))
  (printf "%s: outbox OK (log %d)" label (log-size table))
  true)

# -- sqlite ---------------------------------------------------------------

(def p (pool/make (driver/normalize (sqlite/make {:path (string sandbox "/bus.sqlite3")}))
                  {:size 4}))

(defer (do (pool/close-all! p) (rimraf sandbox))
  (with-dyns [db/pool-dyn p]
    (db/with-conn (busdb/create-tables!))
    (run-suite! "sqlite" "void_bus" 0.1)

    # -- what the outbox refuses --------------------------------------

    (def b (backend/normalize (busdb/store {})))
    (def br (state/make b (codec/normalize codec/json) {:group :x}))
    (put br :outbox (b :outbox-write!))
    (with-dyns [state/broker-dyn br]
      (def [ok err] (protect (state/publish-tx! :money/debited {})))
      (assert (not ok) "publish-tx! outside a transaction is an error")
      (assert (string/find "with-tx" (string err))
              "and it names the form that is missing"))

    (def heap (backend/normalize (memory/store (memory/make {}))))
    (def [ok2 err2] (protect (backend/require-durable! heap "the transactional outbox")))
    (assert (not ok2)
            "an outbox in front of a transport that forgets is refused at start")
    (assert (string/find "void/bus-db" (string err2))
            "naming the plugin that makes it possible")

    (def no-outbox (state/make heap (codec/normalize codec/json) {:group :y}))
    (with-dyns [state/broker-dyn no-outbox]
      (def [ok3 err3] (protect (state/publish-tx! :money/debited {})))
      (assert (not ok3) "and without a writer publish-tx! refuses rather than publishing plainly")
      (assert (string/find "void/bus-db" (string err3))))))

# -- Postgres, when there is one -----------------------------------------
#
# A transaction is exactly the thing two engines may disagree about, so
# the claim is checked against both rather than reasoned about.

(if (pg/available?)
  (let [pgp (pool/make (pg/driver) {:size 4})
        tbl (string "void_bus_ob_" (os/getpid))]
    (defer (do
             (with-dyns [db/pool-dyn pgp]
               (db/with-conn
                 (each t [tbl (string tbl "_cursors") (string tbl "_leases")
                          (string tbl "_outbox")]
                   (protect (db/execute-sql (string "DROP TABLE IF EXISTS " t) []
                                            {:kind :write :prepared false})))))
             (pool/close-all! pgp))
      (with-dyns [db/pool-dyn pgp]
        (db/with-conn (busdb/create-tables! tbl))
        (run-suite! "postgres" tbl 0.2))))
  (pg/skip "void/bus-db outbox on Postgres"))

(print "void/bus outbox tests OK")
