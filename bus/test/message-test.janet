(import ../test-support/paths)
(import void/bus/message :as message)

# -- topics and patterns -------------------------------------------------

(assert (message/topic? :user/created) "a namespaced keyword is a topic")
(assert (message/topic? :heartbeat) "so is a bare one")
(assert (not (message/topic? :*)) ":* is a pattern, never a topic")
(assert (not (message/topic? :user/*)) "and so is a namespace wildcard")
(assert (not (message/topic? "user/created")) "a string is not a topic")

(each p [:user/created :user/* :*]
  (assert (message/pattern? p) (string/format "%q is a subscription pattern" p)))
(assert (not (message/pattern? "user/*")) "a pattern is a keyword too")

(assert (message/matches? :user/created :user/created))
(assert (not (message/matches? :user/created :user/deleted)))
(assert (message/matches? :user/* :user/created))
(assert (message/matches? :user/* :user/deleted))
(assert (not (message/matches? :user/* :order/created))
        "a namespace wildcard stops at the namespace")
(assert (not (message/matches? :user/* :users/created))
        "and it does not match a namespace that merely starts the same way")
(assert (message/matches? :* :anything/at-all))
(assert (message/matches? :* :bare))

(assert (message/exact? :user/created) "an exact topic narrows a backend's read")
(assert (not (message/exact? :user/*)) "a wildcard does not")

(assert (not (first (protect (message/check-pattern! "user" "test"))))
        "a pattern that is not a keyword is refused, with the caller named")

# -- ids -----------------------------------------------------------------

(def ids (seq [_ :range [0 200]] (message/new-id)))
(assert (= 200 (length (distinct ids))) "ids do not collide")
(assert (all |(= 27 (length $)) ids) "an id is a fixed-width string")
(def early (message/new-id 1000))
(def late (message/new-id 2000))
(assert (< early late) "ids sort by the second they were minted in")

# -- make ----------------------------------------------------------------

(def m (message/make :user/created {:id 42}))
(assert (message/message? m))
(assert (= :user/created (m :topic)))
(assert (= {:id 42} (m :payload)) "the payload is exactly what was passed")
(assert (string? (m :id)))
(assert (number? (get-in m [:meta :published-at])))
(assert (= (m :id) (message/correlation-id m))
        "the first message of a chain correlates the chain")
(assert (nil? (get-in m [:meta :causation-id]))
        "a message caused by a request has no causation")

(assert (not (first (protect (message/make :* {}))))
        "a pattern is not a topic to publish on")
(assert (not (first (protect (message/make "user/created" {}))))
        "and neither is a string")
(assert (not (first (protect (message/make :user/created {} {:meta "no"}))))
        ":meta must be a dictionary")

# the framework's keys never touch the payload
(assert (deep= @[:id] (keys (m :payload)))
        "nothing void writes lands in the payload")

# -- correlation and causation inherit from the fiber --------------------

(with-dyns [message/correlation-dyn "corr-1" message/causation-dyn "msg-0"]
  (def child (message/make :order/placed {}))
  (assert (= "corr-1" (message/correlation-id child))
          "a message published while handling one inherits the correlation")
  (assert (= "msg-0" (get-in child [:meta :causation-id]))
          "and is caused by the message being handled"))

(def explicit (message/make :order/placed {} {:correlation-id "given"}))
(assert (= "given" (message/correlation-id explicit))
        "an explicit correlation wins over the fiber's")

# an application's own meta survives beside the framework's
(def tagged (message/make :order/placed {} {:meta {:tenant "acme"}}))
(assert (= "acme" (get-in tagged [:meta :tenant])))
(assert (number? (get-in tagged [:meta :published-at])))

# -- with-meta does not mutate ------------------------------------------

(def annotated (message/with-meta m {:redelivery 3}))
(assert (= 3 (message/redelivery annotated)))
(assert (= 0 (message/redelivery m))
        "the message a retry will replay is not the one a middleware annotated")

# -- reply-to and a fixed clock ------------------------------------------

(def asked (message/make :rpc/ask {} {:reply-to :rpc/answer :at 1234}))
(assert (= :rpc/answer (get-in asked [:meta :reply-to])))
(assert (= 1234 (get-in asked [:meta :published-at])))

(assert (string/find "user/created" (message/summary m))
        "the summary line names the topic")

(print "void/bus/message tests OK")
