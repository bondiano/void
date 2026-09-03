(import ../test-support/paths)
(import void/core/log :as log)
(import void/bus :as bus)
(import void/bus/backend :as backend)
(import void/bus/codec :as codec)
(import void/bus/memory :as memory)
(import void/bus/middleware :as middleware)
(import void/bus/router :as router)
(import void/bus/state :as state)

(log/set-level! "void" :fatal)

(defn- settle [&opt n] (ev/sleep (or n 0.03)))

(defn- bus-over [cfg]
  (def m (memory/make {}))
  (def b (backend/normalize (memory/store m)))
  (state/make b (codec/normalize codec/jdn)
              (merge @{:group :default :dedup {:enabled false}
                       :poison {:enabled false}
                       :retry {:enabled false}}
                     cfg)))

# -- declaration ---------------------------------------------------------

(def orders @[])
(bus/defhandler order-paid
  "Ship what was paid for."
  {:topic :order/paid}
  [msg]
  (array/push orders (msg :payload)))

(assert (index-of :order-paid (router/defined)))
(def d (router/lookup :order-paid))
(assert (= :order/paid (d :topic)))
(assert (= "Ship what was paid for." (d :doc)))
(assert (= :order-paid (get-in d [:opts :name]))
        "the handler's name travels in its options, for the middleware that need it")

# the function stays an ordinary function
(order-paid {:payload {:direct true}})
(assert (deep= {:direct true} (last orders))
        "calling a handler directly runs the body, without a chain")
(array/clear orders)

(assert (not (first (protect (router/define! :bad {} {:fn (fn [_])}))))
        "a handler without a topic is refused where it is declared")
(assert (not (first (protect (router/define! :bad {:topic :a/b :queue :x} {:fn (fn [_])}))))
        "and so is an option nobody declared")
(assert (not (first (protect (router/define! :bad {:topic :a/b} {}))))
        "a definition needs a function")

# -- late binding --------------------------------------------------------

(assert (= order-paid (router/handler-fn (router/lookup :order-paid)))
        "the function is resolved through the module binding")

# -- groups --------------------------------------------------------------

(bus/defhandler audit-everything {:topic :* :group :audit} [msg] nil)

(assert (deep= @[:audit :default] (router/groups :default))
        "a handler that names no group joins the composition's")
(assert (deep= @[:order-paid] (map |($ :name) (router/for-group :default :default))))
(assert (deep= @[:audit-everything] (map |($ :name) (router/for-group :audit :default))))

# -- narrowing a backend's read ------------------------------------------

(assert (deep= @[:order/paid] (router/exact-topics (router/for-group :default :default)))
        "a group of exact topics narrows to a topic IN (...)")
(assert (nil? (router/exact-topics (router/for-group :audit :default)))
        "one wildcard among them makes the whole set unnarrowable")

# -- fan-out, in name order, on the consuming fiber ----------------------

(def order-of-arrival @[])
(router/define! :a-first {:topic :fan/out} {:fn (fn [_] (array/push order-of-arrival :a))})
(router/define! :z-last {:topic :fan/out} {:fn (fn [_] (array/push order-of-arrival :z))})

(def br (bus-over {}))
(with-dyns [state/broker-dyn br]
  (state/start-consumers! br)
  (state/publish :fan/out {:n 1})
  (settle)
  (assert (deep= @[:a :z] order-of-arrival)
          "two handlers on one topic run in name order and cannot interleave")

  # a wildcard group sees what an exact one does not
  (state/publish :order/paid {:sku "x"})
  (settle)
  (assert (deep= @[{:sku "x"}] orders) "the exact handler ran")

  # a topic nobody handles is not an error
  (state/publish :nobody/cares {})
  (settle)
  (assert true "a message with no handler in the group is a debug line, not a failure")
  (state/stop-consumers! br))

# -- a failing handler nacks the message ---------------------------------

(router/forget! :a-first)
(router/forget! :z-last)
(router/forget! :order-paid)
(router/forget! :audit-everything)

(router/define! :explodes {:topic :boom/now} {:fn (fn [_] (error "handler said no"))})
(def compiled
  (router/compile-group (router/for-group :default :default)
                        [(middleware/normalize (middleware/panic-guard))]))
(def [ok err] (protect (router/dispatch compiled {:id "1" :topic :boom/now :meta @{}})))
(assert (not ok) "the error reaches the backend, which is what a nack is")
(assert (string/find "handler said no" (string err))
        "and it is the handler's own error, not a wrapped one")

# -- a handler may bound its own time ------------------------------------

(router/forget! :explodes)
(router/define! :slow {:topic :slow/one :timeout 0.05}
                {:fn (fn [_] (ev/sleep 5))})
(def slow-chain (router/compile-group (router/for-group :default :default) []))
(def t0 (os/clock :monotonic))
(def [ok2 _] (protect (router/dispatch slow-chain {:id "2" :topic :slow/one :meta @{}})))
(assert (not ok2) ":timeout turns a handler that will not return into a nack")
(assert (< (- (os/clock :monotonic) t0) 1) "and it does so on time")

# -- an unknown named middleware is a build error ------------------------

(router/forget! :slow)
(router/define! :picky {:topic :a/b :middleware [:nope]} {:fn (fn [_])})
(def [ok3 err3]
  (protect (router/compile (router/lookup :picky) [])))
(assert (not ok3) "a typo in :middleware fails at build, not at the first message")
(assert (string/find "nope" (string err3)))

(print "void/bus/router tests OK")
