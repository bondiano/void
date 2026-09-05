# The suite every `:db` bus backend has to pass, whichever engine is
# underneath.
#
# void/bus-db is one implementation with two wake-up paths and two
# spellings of a monotonic column (see void/bus/db): sqlite polls and
# declares `integer primary key autoincrement`, Postgres is woken by
# `pg_notify` and declares `bigserial`. Everything else — the cursor
# per group, the lease, the stuck counter, the pruning — is the same
# code, and it is this file, so that "it works on sqlite" and "it works
# on Postgres" are the same sentence checked twice.
#
# Run with `db/pool-dyn` bound to a pool over the engine under test and
# the tables already created.

(import void/bus/backend :as backend)
(import void/bus/codec :as codec)
(import void/bus/db :as busdb)
(import void/bus/router :as router)
(import void/bus/state :as state)

(defn- check [label ok msg]
  (unless ok
    (errorf "%s: %s" label msg))
  ok)

(defn- broker [b &opt cfg]
  (state/make b (codec/normalize codec/json)
              (merge @{:group :default
                       :dedup {:enabled false}
                       :poison {:enabled false}
                       :retry {:enabled false}}
                     (or cfg {}))))

(defn run!
  ``Run the suite against a fresh `:db` backend. `settle` is how long
  one pass needs on this engine — a poll interval on sqlite, a
  notification round trip on Postgres.``
  [label &opt opts]
  (default opts {})
  (def settle (get opts :settle 0.3))
  (def store-opts
    (merge @{:poll-interval 0.05 :notify true :stuck-interval 0.05 :stuck-max 0.2}
           (get opts :store {})))
  (defn wait [&opt n] (ev/sleep (* (or n 1) settle)))

  # every handler this suite declares, and nothing left behind for the
  # next call
  (each n (router/defined) (router/forget! n))

  (def b (backend/normalize (busdb/store store-opts)))

  (check label (backend/at-least-once? b) "the db backend promises at-least-once")
  (check label (backend/durable? b) "and durability, which is why the outbox accepts it")
  (check label (backend/shared? b) "and that several processes see the same log")
  (check label (= :per-group (get-in b [:guarantees :ordering]))
         "and ordering within a group")

  # -- publish, then consume from the beginning of the log --------------
  #
  # A cursor starts at 0, so a consumer that joins after the fact still
  # gets what was published — the difference from the in-process
  # backend that a durable log is *for*.

  (def seen @[])
  (router/define! :collect {:topic :t/*} {:fn (fn [m] (array/push seen (m :payload)))})

  (def br (broker b))
  (with-dyns [state/broker-dyn br]
    (state/publish :t/one {:n 1})
    (state/publish :t/two {:n 2})
    (state/start-consumers! br)
    (wait 2)
    (check label (= 2 (length seen)) "a consumer reads the log from the beginning")
    (check label (= 1 (get-in seen [0 "n"])) "in publish order")
    (check label (= 2 (get-in seen [1 "n"])) "in publish order")

    (state/publish :t/three {:n 3})
    (wait 2)
    (check label (= 3 (length seen)) "and keeps up with what arrives after")
    (state/stop-consumers! br))

  # -- the cursor survives the consumer --------------------------------

  (def resumed @[])
  (router/forget! :collect)
  (router/define! :resume {:topic :t/*} {:fn (fn [m] (array/push resumed (m :payload)))})
  (def br2 (broker b))
  (with-dyns [state/broker-dyn br2]
    (state/start-consumers! br2)
    (wait 2)
    (check label (empty? resumed)
           "a restarted consumer resumes at its cursor rather than replaying the log")
    (state/publish :t/four {:n 4})
    (wait 2)
    (check label (= 1 (length resumed)) "and picks up from there")
    (state/stop-consumers! br2))

  # -- fan-out: a second group sees everything -------------------------

  (def audit @[])
  (router/forget! :resume)
  (router/define! :audit-all {:topic :* :group :audit}
                  {:fn (fn [m] (array/push audit (m :topic)))})
  (def br3 (broker b))
  (with-dyns [state/broker-dyn br3]
    (state/start-consumers! br3)
    (wait 3)
    (check label (>= (length audit) 4)
           "a new group reads the whole log — fan-out is the difference from a queue")
    (state/stop-consumers! br3))

  # -- at-least-once: a failure holds the cursor -----------------------

  (def attempts @[])
  (each n (router/defined) (router/forget! n))
  (var fail? true)
  (router/define! :flaky {:topic :f/one}
                  {:fn (fn [m]
                         (array/push attempts (get-in m [:meta :redelivery] 0))
                         (when fail? (error "not yet")))})
  (def br4 (broker b {:group :flaky}))
  (with-dyns [state/broker-dyn br4]
    (state/publish :f/one {:n 1})
    (state/publish :f/one {:n 2})
    (state/start-consumers! br4)
    (wait 4)
    (check label (>= (length attempts) 2)
           "a message whose handler threw comes back")
    (check label (pos? (last attempts))
           "and comes back knowing how often it has been tried")
    (check label (= 0 (first attempts)) "the first delivery is not a redelivery")

    (set fail? false)
    (wait 4)
    (def after (length attempts))
    (wait 2)
    (check label (= after (length attempts))
           "once it succeeds the cursor moves past it and it stops coming back")
    (state/stop-consumers! br4))

  # -- one reader per group, by lease ----------------------------------

  (def counted @{})
  (each n (router/defined) (router/forget! n))
  (router/define! :count-once {:topic :once/one :group :leased}
                  {:fn (fn [m] (put counted (get-in m [:payload "n"])
                                    (inc (get counted (get-in m [:payload "n"]) 0))))})
  (def br5 (broker b {:group :leased}))
  (def br6 (broker b {:group :leased}))
  (with-dyns [state/broker-dyn br5]
    (state/start-consumers! br5)
    (with-dyns [state/broker-dyn br6]
      (state/start-consumers! br6))
    (with-dyns [state/broker-dyn br5] (state/publish :once/one {:n 1}))
    (wait 4)
    (check label (= 1 (get counted 1 0))
           "two consumers of one group deliver the message once between them")
    (with-dyns [state/broker-dyn br6] (state/stop-consumers! br6))
    (state/stop-consumers! br5))

  # -- the outbox ------------------------------------------------------

  (check label (function? (b :outbox-write!)) "the db backend carries an outbox writer")

  (printf "%s: db bus backend conformance OK" label)
  true)
