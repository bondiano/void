(import ../test-support/paths)
(import ../test-support/server)
(import void/core/log :as log)
(import void/db-postgres/conn :as conn)
(import void/db-postgres/config :as config)
(import void/db-postgres/libpq :as libpq)
(import void/db-postgres/listener :as listener)

# the suite makes a handler fail on purpose; its log line is not news
(log/set-level! "void.db.postgres.listen" :fatal)

(if-not (server/available?)
  (do (server/skip "db-postgres listener")
      (os/exit 0)))

(libpq/load!)
(def conninfo (config/conninfo (server/config {:application-name "void-listener-test"})))

(defn- wait-for
  "Spin the loop until (f) is true, or give up after `limit` seconds."
  [f &opt limit]
  (default limit 5)
  (def t0 (os/clock :monotonic))
  (while (and (not (f)) (< (- (os/clock :monotonic) t0) limit))
    (ev/sleep 0.01))
  (f))

# A channel name per run: two suites against one database must not
# hear each other's notifications.
(def channel (string "void_test_" (os/time)))

(def l (listener/open conninfo))
(def sender (conn/open conninfo))

(defer (do (listener/stop! l) (conn/close sender))
  (listener/start! l)

  # -- idle ----------------------------------------------------------------

  (ev/sleep 0.05)
  (assert (empty? (listener/channels l)) "nothing is subscribed")
  (assert (not (get (listener/stats l) :connected))
          "so the listener holds no connection at all — a fiber costs less than a backend")

  # -- one subscription ----------------------------------------------------

  (def heard @[])
  (listener/subscribe! l channel (fn [n] (array/push heard n)))
  (assert (deep= @[channel] (listener/channels l)))
  (assert (wait-for |(get (listener/stats l) :connected))
          "subscribing wakes the listening fiber, which opens the connection and LISTENs")

  (listener/notify! sender channel "first")
  (assert (wait-for |(= 1 (length heard))) "a notification arrives")
  (def note (first heard))
  (assert (= channel (note :channel)))
  (assert (= "first" (note :payload)))
  (assert (pos? (note :pid)) "carrying the backend that sent it")

  # -- several -------------------------------------------------------------

  (each i (range 5) (listener/notify! sender channel (string i)))
  (assert (wait-for |(= 6 (length heard))) "and so does every one after it")
  (assert (deep= ["0" "1" "2" "3" "4"]
                 (tuple ;(map |($ :payload) (slice heard 1))))
          "in the order they were sent")

  # -- a payload is optional -----------------------------------------------

  (listener/notify! sender channel)
  (assert (wait-for |(= 7 (length heard))))
  (assert (= "" (get (last heard) :payload))
          "a notification with no payload arrives with an empty one — that is Postgres' spelling")

  # -- a second handler on the same channel --------------------------------

  (def also @[])
  (def second-handler (listener/subscribe! l channel (fn [n] (array/push also n))))
  (listener/notify! sender channel "both")
  (assert (wait-for |(= 1 (length also))) "every handler of a channel hears it")
  (assert (= 8 (length heard)))

  (listener/unsubscribe! l channel second-handler)
  (listener/notify! sender channel "one")
  (assert (wait-for |(= 9 (length heard))))
  (ev/sleep 0.05)
  (assert (= 1 (length also)) "and one removed hears nothing more")
  (assert (deep= @[channel] (listener/channels l))
          "while the channel itself stays subscribed — a handler left")

  # -- a handler that throws -----------------------------------------------

  (def after-bad @[])
  (listener/subscribe! l channel (fn [_] (error "handler is broken")))
  (listener/subscribe! l channel (fn [n] (array/push after-bad n)))
  (listener/notify! sender channel "survive")
  (assert (wait-for |(= 1 (length after-bad)))
          "a handler that throws does not silence the ones after it")
  (assert (pos? (get (listener/stats l) :errors)) "the failure is counted")
  (assert (wait-for |(= 10 (length heard))) "and the listener keeps listening")

  # -- unsubscribing entirely ----------------------------------------------

  (listener/unsubscribe! l channel)
  (assert (empty? (listener/channels l)))
  (assert (wait-for |(not (get (listener/stats l) :connected)))
          "with nothing left to hear, the listener gives its connection back")

  (def before (length heard))
  (listener/notify! sender channel "into the void")
  (ev/sleep 0.1)
  (assert (= before (length heard))
          "and a notification sent to nobody is gone — delivery is at-most-once, and that is Postgres'")

  # -- reconnect -----------------------------------------------------------

  (def again @[])
  (listener/subscribe! l channel (fn [n] (array/push again n)))
  (assert (wait-for |(get (listener/stats l) :connected)) "subscribing again reconnects")

  # kill the listener's own backend and check it comes back with its
  # subscription intact — the whole point of reconciling on every turn
  (def pid (conn/backend-pid (l :conn)))
  (conn/execute sender "SELECT pg_terminate_backend($1)" [pid])
  (assert (wait-for |(and (get (listener/stats l) :connected)
                          (not= pid (conn/backend-pid (l :conn))))
                    10)
          "a terminated listener connection is replaced")

  (listener/notify! sender channel "after the restart")
  (assert (wait-for |(pos? (length again)) 10)
          "and the LISTEN is reissued on the new session, so notifications keep arriving")
  (assert (= "after the restart" (get (last again) :payload)))

  # -- stopping ------------------------------------------------------------

  (listener/stop! l)
  (assert (wait-for |(not (get (listener/stats l) :running))))
  (assert (not (get (listener/stats l) :connected)) "stopping closes the connection"))

(print "db-postgres listener: ok")
