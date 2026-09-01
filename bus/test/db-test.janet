(import ../test-support/paths)
(import ../test-support/conformance :as conformance)
(import void/core/log :as log)
(import void/db/driver :as driver)
(import void/db/pool :as pool)
(import void/db/state :as db)
(import void/db-sqlite/driver :as sqlite)
(import void/test :as test)
(import void/bus :as bus)
(import void/bus/backend :as backend)
(import void/bus/codec :as codec)
(import void/bus/db :as busdb)
(import void/bus/router :as router)
(import void/bus/state :as state)

(each ns ["void.db" "void.db.query" "void.bus" "void.bus.db"]
  (log/set-level! ns :fatal))

# The db backend is tested against the reference driver — sqlite, which
# is also the engine *without* LISTEN/NOTIFY, so what runs here is the
# polling path. The Postgres one (a `pg_notify` on the inserting
# connection, a consumer parked on the listener) is different code for
# the same contract, and it runs the same conformance suite in
# test/db-postgres-test.janet when VOID_TEST_PG names a server.

(def sandbox (string (os/cwd) "/.tmp-bus-db-" (os/time) "-" (os/getpid)))
(os/mkdir sandbox)

(defn- rimraf [path]
  (case (os/stat path :mode)
    :directory (do (each f (os/dir path) (rimraf (string path "/" f)))
                   (os/rmdir path))
    nil nil
    (os/rm path)))

(def p (pool/make (driver/normalize (sqlite/make {:path (string sandbox "/bus.sqlite3")}))
                  {:size 4}))

(defer (do (pool/close-all! p) (rimraf sandbox))
  (with-dyns [db/pool-dyn p]
    (db/with-conn (busdb/create-tables!))

    # -- the schema ----------------------------------------------------

    (def statements (busdb/ddl :sqlite))
    (assert (>= (length statements) 7)
            "the ddl covers the log, its indexes, the cursors, the leases and the outbox")
    (assert (some |(string/find "autoincrement" $) statements)
            "on sqlite the log's sequence is an autoincrementing integer")
    (assert (some |(string/find "bigserial" $) (busdb/ddl :postgres))
            "and on Postgres a bigserial — the one thing SQL does not agree on")
    (assert (some |(string/find "forwarded_at IS NULL" $) statements)
            "the outbox index is partial: it is the size of the backlog, not of the history")
    (assert (not (first (protect (busdb/ddl :oracle))))
            "an engine with no known spelling is refused with its name, not guessed at")

    (db/with-conn (busdb/create-tables!))
    (assert true "creating the tables twice is not an error")

    # -- the contract ---------------------------------------------------

    (conformance/run! "sqlite" {:settle 0.25})

    # -- the outbox: exit criterion 2 of wave 3 -------------------------
    #
    # The full statement of it is in test/outbox-test.janet; here is the
    # half that belongs to the backend — the row lands in the caller's
    # transaction, and the forwarder is what turns it into a message.

    (def b (backend/normalize (busdb/store {:poll-interval 0.05})))
    (def br (state/make b (codec/normalize codec/json)
                        {:group :outbox-test :dedup {:enabled false}
                         :poison {:enabled false} :retry {:enabled false}}))
    (put br :outbox (b :outbox-write!))

    (each n (router/defined) (router/forget! n))
    (def delivered @[])
    (router/define! :outbox-consumer {:topic :ob/*}
                    {:fn (fn [m] (array/push delivered (m :payload)))})

    (with-dyns [state/broker-dyn br]
      (state/start-consumers! br)
      (ev/sleep 0.2)

      (db/with-tx (state/publish-tx! :ob/one {:n 1}))
      (assert (= 1 (db/with-conn ((b :outbox-count))))
              "a committed publish-tx! is a row the forwarder still owes")
      (ev/sleep 0.3)
      (assert (empty? delivered)
              "and nothing is on the bus until the forwarder runs — which is the point")

      (assert (= 1 (busdb/forward-once! b 10)))
      (ev/sleep 0.3)
      (assert (= 1 (length delivered)) "the forwarder publishes what committed")
      (assert (zero? (db/with-conn ((b :outbox-count))))
              "and marks it, so a second pass does not republish it")
      (assert (zero? (busdb/forward-once! b 10)))

      # -- pruning ------------------------------------------------------

      (def before (db/with-conn
                    (get (first (db/query ["SELECT count(*) AS n FROM void_bus" []])) :n)))
      (assert (pos? before))
      (state/stop-consumers! br))

    # keep-for 0 prunes everything the cursors have already passed; a
    # message no group has read yet is never pruned, whatever its age
    (def pruner (backend/normalize (busdb/store {:keep-for 0.001})))
    (def brp (state/make pruner (codec/normalize codec/json) {:group :none}))
    (with-dyns [state/broker-dyn brp] (state/publish :later/one {:n 1}))
    (ev/sleep 0.05)

    (def kept
      (db/with-conn
        (get (first (db/query ["SELECT count(*) AS n FROM void_bus" []])) :n)))
    (assert (pos? kept))

    (print "void/bus-db backend tests OK")))

# -- the plugin, booted the way an application composes it ---------------

(def boot-sandbox (string (os/cwd) "/.tmp-bus-plugin-" (os/time) "-" (os/getpid)))
(os/mkdir boot-sandbox)

(def handled @[])
(router/define! :booted {:topic :booted/one}
                {:fn (fn [m] (array/push handled (m :payload)))})

(def boot
  (test/start!
    {:plugins ["void/db/init" "void/db-sqlite/init" "void/bus/init" "void/bus/db"]
     :profile :test
     :config {:env @{}
              :cli {:log {:level :error}
                    :db {:driver :db.sqlite/driver}
                    :db-sqlite {:path (string boot-sandbox "/app.sqlite3")}
                    :bus {:backend :db :group :booted
                          :dedup {:enabled false} :poison {:enabled false}}
                    :bus-db {:poll-interval 0.05 :forwarder {:interval 0.02}}}}}))

(defer (do (test/stop! boot) (rimraf boot-sandbox))
  (def br state/current-broker)
  (assert (= :db (get-in br [:backend :name])))
  (assert (bus/outbox-writer br)
          "the outbox writer is the backend's own, so it is there whether or not the :after-start hooks ran — which a CLI subset boot does not")
  (assert (get (bus/stats) :outbox) "and `void bus stats` says so")

  # the forwarder component is running, so publish-tx! needs no help
  (db/with-tx (bus/publish-tx! :booted/one {:n 1}))
  (ev/sleep 0.5)
  (assert (= 1 (length handled))
          "a message written in a transaction reaches a consumer without anyone draining by hand")

  (assert (deep= @[:booted] (sorted (keys (br :consumers)))))
  (assert (some |(string/find "void_bus" $) (busdb/ddl :sqlite))
          "and `void bus-db ddl` prints what the schema component created"))

(print "void/bus-db tests OK")
