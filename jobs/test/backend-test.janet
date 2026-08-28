(import ../test-support/paths)
(import void/jobs/backend :as backend)

(defn- minimal [&opt extra]
  (merge @{:name :fake
           :push! (fn [j] j)
           :claim! (fn [o] nil)
           :settle! (fn [j] j)
           :fetch (fn [id] nil)
           :list (fn [o] [])
           :counts (fn [&opt o] {})
           :remove! (fn [id] false)
           :clear! (fn [o] 0)}
         (or extra {})))

# -- the contract --------------------------------------------------------

(def b (backend/normalize (minimal)))
(assert b "eight functions are a backend")
(each k [:push! :claim! :settle! :fetch :list :counts :remove! :clear!]
  # `put`, not a merge: a nil value vanishes from a table literal, and
  # the test would then be asserting about a complete backend
  (def without (let [t (minimal)] (put t k nil) t))
  (def [ok err] (protect (backend/normalize without)))
  (assert (not ok) (string "a backend without " k " is refused"))
  (assert (string/find (string k) err) "and the error names the key"))

(def [ok err] (protect (backend/normalize {:name :bad :push! :not-a-function})))
(assert (not ok) "a key that is not a function is refused")

# -- capabilities are derived, never declared ----------------------------

(def caps (backend/capabilities b))
(assert (not (caps :flows)) "a minimal backend cannot hold a flow parent")
(assert (not (caps :reaping)) "nor return an abandoned claim")
(assert (not (caps :heartbeat)) "nor keep one alive")
(assert (= :process (caps :rate-limit)) "and its rate limit is this process's")
(assert (= :process (caps :locks)) "as is its lock")

(def [fok ferr] (protect (backend/require-flows! b)))
(assert (not fok) "so flows are refused rather than lost")
(assert (string/find "release-parent" ferr) "with the missing key named")

(def full
  (backend/normalize
    (minimal {:shared? true
              :reap! (fn [o] [])
              :touch! (fn [ids now] 0)
              :release-parent! (fn [c] nil)
              :rate-take! (fn [q l d n] 0)
              :lock! (fn [n t tok now] true)
              :unlock! (fn [n tok] true)})))
(def fcaps (backend/capabilities full))
(assert (fcaps :flows) "a backend that can hold a parent says so")
(assert (fcaps :shared) "and that several processes see it")
(assert (= :shared (fcaps :rate-limit)) "its rate limit is the fleet's")
(assert (= :shared (fcaps :locks)) "and so is its lock")
(assert (backend/require-flows! full) "flows are allowed")

# a backend that declares a shared rate limit but has no :rate-take!
# cannot lie its way past the derivation
(def liar (backend/normalize (minimal {:shared-rate? true :shared-locks? true})))
(assert (= :process (get (backend/capabilities liar) :rate-limit))
        "what a backend can do is derived from what it has, not from what it claims")

# -- the in-process fallbacks --------------------------------------------

(def rate (backend/local-rate-limiter))
(assert (zero? (rate :q 2 60 100)) "the first call in a window passes")
(assert (zero? (rate :q 2 60 100)) "and the second")
(assert (pos? (rate :q 2 60 100)) "the third waits")
(assert (zero? (rate :other 2 60 100)) "a different queue has its own window")
(assert (zero? (rate :q 2 60 200)) "and the next window starts empty")
(assert (zero? (rate :q nil nil 100)) "no limit is no wait")

(def locks (backend/local-locks))
(assert ((locks :lock!) "a" 10 "t1" 100) "a lease can be taken")
(assert (not ((locks :lock!) "a" 10 "t2" 100)) "and not by two at once")
(assert ((locks :lock!) "a" 10 "t1" 100) "the holder may renew")
(assert ((locks :lock!) "a" 10 "t2" 200) "and it expires")
(assert ((locks :unlock!) "a" "t2") "the holder may release it")
(assert (not ((locks :unlock!) "a" "t1")) "and nobody else may")

(print "backend-test ok")
