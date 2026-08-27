(import ../test-support/paths)
(import ../test-support/server)
(import void/core/log :as log)
(import void/redis :as redis)
(import void/redis/config :as config)
(import void/redis/pubsub :as pubsub)
(import void/redis/codec :as codec)

(log/set-level! "void.redis" :error)
# this suite breaks a handler and drops a connection on purpose
(log/set-level! "void.redis.pubsub" :fatal)

(defn- wait-for
  "Poll a predicate for up to `seconds`, letting the loop run. A
  subscriber is another fiber, so a test has to give it a turn."
  [seconds pred]
  (var waited 0)
  (while (and (< waited seconds) (not (pred)))
    (ev/sleep 0.02)
    (+= waited 0.02))
  (pred))

(if-not (server/available?)
  (server/skip "pubsub-test")
  (server/with-client* "pubsub" {}
    (fn [_client]
      (def channel (string (server/prefix "pubsub") "events"))
      (def pattern (string (server/prefix "pubsub") "user:*"))
      (def l (pubsub/open (config/options {:url (server/url)}) {:codec codec/raw}))

      (defer (pubsub/stop! l)

        # -- nothing is opened until something subscribes --------------

        (pubsub/start! l)
        (assert (pubsub/running? l) "the reader is running")
        (assert (nil? (l :conn))
                "and has opened no connection — an application that never subscribes pays nothing")

        # -- a message arrives -----------------------------------------

        (def seen @[])
        (pubsub/subscribe! l channel (fn [m] (array/push seen m)))
        (assert (wait-for 2 |(l :conn)) "subscribing opens the connection")
        (assert (deep= @[channel] ((pubsub/subscriptions l) :channels)))

        # the publish goes through the pool, which is the point: a
        # subscribed connection cannot carry ordinary commands
        (assert (wait-for 2 (fn []
                              (redis/publish! channel "hello")
                              (pos? (length seen))))
                "a published message reaches the handler")
        (assert (= channel ((in seen 0) :channel)))
        (assert (= "hello" ((in seen 0) :payload)))

        # -- patterns ---------------------------------------------------

        (def pseen @[])
        (pubsub/psubscribe! l pattern (fn [m] (array/push pseen m)))
        (def user-channel (string (server/prefix "pubsub") "user:7"))
        (assert (wait-for 2 (fn []
                              (redis/publish! user-channel "signup")
                              (pos? (length pseen))))
                "a pattern subscription matches the channels it should")
        (assert (= pattern ((in pseen 0) :pattern)) "and says which pattern matched")
        (assert (= user-channel ((in pseen 0) :channel)) "as well as which channel")

        # -- one bad handler does not silence the rest ------------------

        (def after @[])
        (pubsub/subscribe! l channel (fn [_] (error "this handler is broken")))
        (pubsub/subscribe! l channel (fn [m] (array/push after m)))
        (assert (wait-for 2 (fn []
                              (redis/publish! channel "still here")
                              (pos? (length after))))
                "a handler that throws does not stop the one after it")
        (assert (pos? (get-in l [:stats :errors])) "and is counted")

        # -- unsubscribing ----------------------------------------------

        (def before (length seen))
        (pubsub/unsubscribe! l channel)
        (assert (empty? ((pubsub/subscriptions l) :channels)))
        (ev/sleep 0.1)
        (redis/publish! channel "nobody is listening")
        (ev/sleep 0.2)
        (assert (= before (length seen)) "an unsubscribed channel delivers nothing")

        # -- reconnecting resubscribes ----------------------------------
        #
        # A redis connection carries no subscription across a socket,
        # so a replacement for one has to be told again what it wanted.

        (def revived @[])
        (pubsub/subscribe! l channel (fn [m] (array/push revived m)))
        (assert (wait-for 2 |(l :conn)))
        (:close ((l :conn) :stream))
        (assert (wait-for 5 (fn []
                              (protect (redis/publish! channel "after the drop"))
                              (pos? (length revived))))
                "after the connection drops the subscription comes back with it")
        (assert (pos? (get-in l [:stats :reconnects])) "and the reconnect is counted")

        (printf "pubsub-test: ok")))))
