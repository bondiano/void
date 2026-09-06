### void/bus/conformance/backend — the `:void.bus/backend` conformance
### suite.
###
### One set of assertions, run against every transport there is. The
### contract (void/bus/backend) says a backend is four functions and a
### set of *declared* guarantees, and that everything above it reads the
### declaration rather than the transport's name: the router turns its
### own retries on under `:at-most-once`, the outbox refuses a backend
### that is not `:durable`. A suite that only ever ran against the db
### backend would be a suite that never checked the claim — so this file
### holds the assertions, and each transport's own test hands it a
### factory:
###
###     (import void/bus/conformance/backend :as conformance)
###     (conformance/run! "memory" (fn [] (memory/store (memory/make))))
###
### It ships with void/bus, not with the tests, so a backend written
### outside this repository runs the same suite against the same broker
### it will be plugged into.
###
### **A factory, not a backend.** `make-backend` returns a *fresh raw*
### backend on every call, because one of the questions here is what a
### second process sees, and the honest way to ask it is to build a
### second backend over the same log. The suite normalizes what it gets
### — `backend/normalize` filling the optional keys in is part of what
### is being checked — and closes every backend it made.
###
### **It branches on what the backend declares, never on its name.**
### Five sections run against everything: publish reaches a running
### consumer, a second group sees the same message, a group sees only
### the topics its handlers named, a handler that throws does not take
### the consumer with it, and `stop!` on a stopped consumer is not an
### error. The rest is conditional, and the condition is the
### declaration:
###
###   :durable          a message published before any consumer exists
###                     is delivered once one subscribes, and the cursor
###                     survives a consumer restart
###   not :durable      an unconsumed message is gone — there is no log
###                     to catch up with, which is what at-most-once in
###                     the heap means
###   :at-least-once    a message whose handler threw comes back,
###                     knowing how often it has been tried, and stops
###                     coming back once it succeeds
###   :shared with      two consumers of one group deliver a message
###   :per-group        once between them
###
### A backend that declares less runs fewer sections. That is not a
### weaker test: it is the contract, which is a promise the transport
### makes rather than a behaviour the suite hopes for.
###
### Everything goes through the broker (void/bus/state) rather than
### calling `:publish!` and `:consume!` by hand, because that is the
### path an application takes — the codec encodes, the router compiles
### a group, the middleware chain wraps the handler. A backend that
### passes its own raw tests and fails here has satisfied its own idea
### of the contract, not the broker's. The one exception is the `stop!`
### section, whose subject is the backend call itself.
###
### What it does NOT test is what one transport has and another does
### not: the SQL outbox, Kafka's partition keys, the in-process history
### ring. Those live in the backend's own suite, next to the thing that
### has them.
###
### The handler registry is global (void/bus/router) and this suite
### uses it, so it clears the registry on the way in and on the way
### out. A caller with handlers of its own declares them after the run.

(import ../backend :as backend)
(import ../codec :as codec)
(import ../router :as router)
(import ../state :as state)
(import void/core/util :as util)

(defn- forget-all! []
  (each n (router/defined) (router/forget! n)))

(defn- broker
  ``A broker over `b` with the middleware that would otherwise answer
  for the transport turned off: dedup, poison and retry are the
  router's decisions, and what is under test here is the backend's.``
  [b &opt cfg]
  (state/make b (codec/normalize codec/json)
              (merge @{:group :default
                       :dedup {:enabled false}
                       :poison {:enabled false}
                       :retry {:enabled false}}
                     (or cfg {}))))

(defn run!
  ``Assert that the backend `make-backend` builds behaves like a
  `:void.bus/backend`. `name` names the transport in the failure
  messages, because "a message arrived twice" is a different bug in
  each of them.

  `make-backend` is `(fn [] backend)` and is called more than once: it
  must hand back a fresh raw backend over the *same* log every time,
  the way a second process would open one. The suite normalizes each
  and closes it on the way out.

  opts:
    :settle  how long one pass takes on this transport — a poll
             interval, a notification round trip, a consumer group
             join. Every wait in the suite is a multiple of it: a
             negative assertion sleeps a few, a positive one polls up
             to forty.``
  [name make-backend &opt opts]
  (default opts {})
  (def settle (get opts :settle 0.3))
  (def patience (* 40 settle))
  (defn note [msg] (string name ": " msg))
  (defn wait [&opt n] (ev/sleep (* (or n 1) settle)))

  (def made @[])
  (defn fresh []
    (def b (backend/normalize (make-backend)))
    (array/push made b)
    b)

  (defn await
    ``Poll `pred` until it answers, or fail naming what never
    happened. A transport's latency is real and a fixed sleep long
    enough for the slowest of them would be the suite's running
    time.``
    [msg pred]
    (def deadline (+ (os/clock :monotonic) patience))
    (var ok (pred))
    (while (and (not ok) (< (os/clock :monotonic) deadline))
      (ev/sleep (min 0.05 (/ settle 4)))
      (set ok (pred)))
    (assert ok (note (string/format "%s — not within %.1f s" msg patience)))
    true)

  (def b (fresh))
  (def at-least-once? (backend/at-least-once? b))
  (def durable? (backend/durable? b))
  (def shared? (backend/shared? b))
  (def ordered? (= :per-group (get-in b [:guarantees :ordering])))

  (defer (do (forget-all!)
             (each x made (protect ((x :close)))))
    (forget-all!)

    # -- the shape, and what it declares ---------------------------------

    (assert (keyword? (b :name)) (note "a backend names itself"))
    (each k [:publish! :consume! :stop! :close :stats]
      (assert (util/callable? (b k))
              (note (string k " is callable after normalize — the broker never checks"))))
    (assert (index-of (get-in b [:guarantees :delivery]) backend/deliveries)
            (note "and declares a delivery guarantee the router knows"))
    (assert (index-of (get-in b [:guarantees :ordering]) backend/orderings)
            (note "and an ordering guarantee"))
    (each k [:durable :shared]
      (assert (boolean? (get-in b [:guarantees k]))
              (note (string k " is declared, not left to be discovered"))))

    # -- publish reaches a running consumer ------------------------------

    (def seen @[])
    (router/define! :conf-collect {:topic :conf/one :group :conf-basic}
                    {:fn (fn [m] (array/push seen (get-in m [:payload "n"])))})
    (def br (broker b {:group :conf-basic}))
    (with-dyns [state/broker-dyn br]
      (state/start-consumers! br)
      (each n [1 2 3] (state/publish :conf/one {:n n}))
      (await "a running consumer receives what is published" |(= 3 (length seen)))
      (if ordered?
        (assert (deep= @[1 2 3] seen)
                (note "in publish order, which is what :per-group promises"))
        (assert (deep= @[1 2 3] (sorted seen))
                (note "all of them, in whatever order :none allows")))
      (state/stop-consumers! br))

    # -- fan-out: every group sees the message ---------------------------
    #
    # The difference between a bus and a queue, and the only reason a
    # group is a name rather than a connection.

    (forget-all!)
    (def one @[])
    (def two @[])
    (router/define! :conf-fan-one {:topic :fan/one :group :conf-fan-1}
                    {:fn (fn [m] (array/push one (m :topic)))})
    (router/define! :conf-fan-two {:topic :fan/one :group :conf-fan-2}
                    {:fn (fn [m] (array/push two (m :topic)))})
    (def br-fan (broker b))
    (with-dyns [state/broker-dyn br-fan]
      (state/start-consumers! br-fan)
      (state/publish :fan/one {:n 1})
      (await "a second group sees the same message — fan-out is the difference from a queue"
             |(and (= 1 (length one)) (= 1 (length two))))
      (state/stop-consumers! br-fan))

    # -- a group sees the topics its handlers named ----------------------
    #
    # `:topics` is a hint a backend may narrow its read with and may
    # equally ignore; what is not optional is that the handler is not
    # called for a topic it never asked for.

    (forget-all!)
    (def wanted @[])
    (router/define! :conf-wanted {:topic :want/one :group :conf-filter}
                    {:fn (fn [m] (array/push wanted (m :topic)))})
    (def br-filter (broker b {:group :conf-filter}))
    (with-dyns [state/broker-dyn br-filter]
      (state/start-consumers! br-filter)
      (state/publish :other/one {:n 1})
      (state/publish :want/one {:n 2})
      (await "a group's handler is called for the topic it declared"
             |(= 1 (length wanted)))
      (wait 2)
      (assert (deep= @[:want/one] wanted)
              (note "and never for one it did not"))
      (state/stop-consumers! br-filter))

    # -- a handler that throws does not take the consumer with it --------
    #
    # What a nack *means* is the declared guarantee and is asked below;
    # what it may never mean is a consumer that stopped reading. The
    # handler throws once, so an at-least-once backend can get past the
    # message it is holding the cursor on.

    (forget-all!)
    (def after @[])
    (var boom true)
    (router/define! :conf-throws {:topic :boom/* :group :conf-throws}
                    {:fn (fn [m]
                           (when (and boom (= :boom/first (m :topic)))
                             (set boom false)
                             (error "the handler said no"))
                           (array/push after (m :topic)))})
    (def br-throws (broker b {:group :conf-throws}))
    (with-dyns [state/broker-dyn br-throws]
      (state/start-consumers! br-throws)
      (state/publish :boom/first {:n 1})
      (state/publish :boom/second {:n 2})
      (await "a message published after a handler threw is still delivered"
             |(index-of :boom/second after))
      (state/stop-consumers! br-throws))

    # -- stop! is idempotent ---------------------------------------------
    #
    # Straight at the backend: the broker stops a consumer once, but a
    # shutdown that raced a `close` stops it twice, and neither the
    # process nor the log is any business of the second call.

    (forget-all!)
    (def sub ((b :consume!) {:group :conf-stop
                             :topics [:stop/*]
                             :match? (fn [_] false)}
              (fn [_] nil)))
    # the second call is the assertion: stopping a stopped consumer is
    # not an error, or it raised here
    ((b :stop!) sub)
    ((b :stop!) sub)

    # -- durable: the log outlives the consumer --------------------------

    (when durable?
      (forget-all!)
      (def early @[])
      (router/define! :conf-early {:topic :early/one :group :conf-early}
                      {:fn (fn [m] (array/push early (get-in m [:payload "n"])))})
      (def br-early (broker b {:group :conf-early}))
      (with-dyns [state/broker-dyn br-early]
        (state/publish :early/one {:n 1})
        (state/start-consumers! br-early)
        (await "a message published before any consumer existed is delivered to the first one that asks"
               |(= 1 (length early)))
        (state/stop-consumers! br-early))

      # and the cursor is the group's, not the consumer's: the same
      # group coming back does not read the log again
      (def resumed @[])
      (forget-all!)
      (router/define! :conf-resume {:topic :early/one :group :conf-early}
                      {:fn (fn [m] (array/push resumed (get-in m [:payload "n"])))})
      (def br-resume (broker b {:group :conf-early}))
      (with-dyns [state/broker-dyn br-resume]
        (state/start-consumers! br-resume)
        (wait 3)
        (assert (empty? resumed)
                (note "a restarted consumer resumes at its cursor rather than replaying the log"))
        (state/publish :early/one {:n 2})
        (await "and picks up from there" |(= 1 (length resumed)))
        (assert (= 2 (first resumed)) (note "with what arrived while it was away or after"))
        (state/stop-consumers! br-resume)))

    # -- not durable: there is no log to catch up with -------------------
    #
    # The in-process backend's defining property, and the reason
    # `publish-tx!` refuses it. Asserted rather than tolerated, because
    # a backend that quietly replayed a buffer to a late subscriber
    # would behave unlike every backend it stands in for.

    (unless durable?
      (forget-all!)
      (def gone @[])
      (router/define! :conf-gone {:topic :gone/one :group :conf-gone}
                      {:fn (fn [m] (array/push gone (get-in m [:payload "n"])))})
      (def br-gone (broker b {:group :conf-gone}))
      (with-dyns [state/broker-dyn br-gone]
        (state/publish :gone/one {:n 1})
        (state/start-consumers! br-gone)
        (wait 3)
        (assert (empty? gone)
                (note "a message published while nobody was consuming is gone"))
        (state/publish :gone/one {:n 2})
        (await "while one published after a consumer joined arrives"
               |(= 1 (length gone)))
        (assert (= 2 (first gone)) (note "and it is the later one"))
        (state/stop-consumers! br-gone)))

    # -- at-least-once: a nack is a redelivery ---------------------------
    #
    # The one place in void where "what happens when it fails" is the
    # transport's decision and not the runtime's, so it is the
    # transport that has to demonstrate it.

    (when at-least-once?
      (forget-all!)
      (def attempts @[])
      (var failing true)
      (router/define! :conf-flaky {:topic :flaky/one :group :conf-flaky}
                      {:fn (fn [m]
                             (array/push attempts (get-in m [:meta :redelivery] 0))
                             (when failing (error "not yet")))})
      (def br-flaky (broker b {:group :conf-flaky}))
      (with-dyns [state/broker-dyn br-flaky]
        (state/publish :flaky/one {:n 1})
        (state/start-consumers! br-flaky)
        (await "a message whose handler threw comes back" |(<= 2 (length attempts)))
        (assert (= 0 (first attempts)) (note "the first delivery is not a redelivery"))
        (assert (pos? (last attempts))
                (note "and a redelivery knows how often it has been tried"))
        (set failing false)
        (await "and stops coming back once it succeeds"
               (fn []
                 (def n (length attempts))
                 (wait 2)
                 (= n (length attempts))))
        (def before (length attempts))
        (state/publish :flaky/one {:n 2})
        (await "the cursor having moved past it to the next message"
               |(< before (length attempts)))
        (state/stop-consumers! br-flaky)))

    # -- shared, ordered per group: one reader at a time -----------------
    #
    # Two backends over one log — two processes, as far as the
    # transport is concerned — consuming one group. Fan-out is between
    # groups; inside one, a message is delivered once, and a transport
    # that keeps a group in order has to arbitrate rather than race.

    (when (and shared? ordered?)
      (forget-all!)
      (def counted @{})
      (router/define! :conf-once {:topic :once/one :group :conf-leased}
                      {:fn (fn [m]
                             (def n (get-in m [:payload "n"]))
                             (put counted n (inc (get counted n 0))))})
      (def other (fresh))
      (def br-a (broker b {:group :conf-leased}))
      (def br-b (broker other {:group :conf-leased}))
      (with-dyns [state/broker-dyn br-a]
        (state/start-consumers! br-a)
        (with-dyns [state/broker-dyn br-b] (state/start-consumers! br-b))
        (state/publish :once/one {:n 1})
        (await "two consumers of one group deliver the message once between them"
               |(= 1 (get counted 1 0)))
        (wait 3)
        (assert (= 1 (get counted 1 0))
                (note "once between them and not once each — one reader per group at a time"))
        (with-dyns [state/broker-dyn br-b] (state/stop-consumers! br-b))
        (state/stop-consumers! br-a))))

  (printf "%s: bus-backend conformance OK" name)
  true)
