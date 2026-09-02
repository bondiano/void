(import ../test-support/paths)
(import ../test-support/fake-driver :as fake)
(import void/db/driver :as driver)
(import void/db/pool :as pool)

(defn- new-pool [&opt opts]
  (def [drv st] (fake/make))
  [(pool/make (driver/normalize drv) (or opts {})) st])

# -- lazy creation and reuse ---------------------------------------------

(def [p st] (new-pool {:size 2}))
(def a (pool/checkout p))
(def b (pool/checkout p))
(assert (= 2 (st :conns)) "connections are opened on demand, up to :size")
(assert (not= (a :id) (b :id)) "two checkouts are two connections")
(pool/checkin p a)
(def c (pool/checkout p))
(assert (= (a :id) (c :id)) "a returned connection is reused")
(assert (= 2 (st :conns)) "reuse does not open a third connection")
(assert (= 2 ((pool/stats p) :in-use)) "b and c are both out")
(assert (zero? ((pool/stats p) :idle)) "nothing idle while both are out")

# -- saturation parks the fiber, FIFO hands over -------------------------

(def [p2 st2] (new-pool {:size 1 :checkout-timeout 2}))
(def held (pool/checkout p2))
(def order @[])
(def done (ev/chan 2))

(defn- waiter [name]
  (ev/go (fn []
           (def e (pool/checkout p2))
           (array/push order name)
           (pool/checkin p2 e)
           (ev/give done name))))

(waiter :first)
(ev/sleep 0.01)
(waiter :second)
(ev/sleep 0.01)
(assert (= 2 ((pool/stats p2) :waiting)) "both fibers are parked on the pool")
(assert (= 1 (st2 :conns)) "a saturated pool opens no extra connections")

(pool/checkin p2 held)
(ev/take done)
(ev/take done)
(assert (deep= @[:first :second] order) "waiters are served in arrival order")
(assert (= 1 (st2 :conns)) "the single connection served both")
(def s2 (pool/stats p2))
(assert (= 2 (s2 :waits)) "both waits are counted")
(assert (>= (s2 :wait-us) 0) "wait time is measured")

# -- a checkout that never gets a connection times out -------------------

(def [p3 _] (new-pool {:size 1 :checkout-timeout 0.05}))
(def kept (pool/checkout p3))
(def [ok err] (protect (pool/checkout p3)))
(assert (not ok) "an unserved checkout throws")
(assert (string/find "timed out" err) "the error names the timeout")
(assert (= 1 ((pool/stats p3) :timeouts)) "timeouts are counted")
# the pool is still usable afterwards
(pool/checkin p3 kept)
(def again (pool/checkout p3))
(assert again "the pool recovers after a timeout")
(pool/checkin p3 again)

# -- discard frees the slot and wakes a waiter ---------------------------

(def [p4 st4] (new-pool {:size 1 :checkout-timeout 2}))
(def broken (pool/checkout p4))
(def got (ev/chan 1))
(ev/go (fn []
         (def e (pool/checkout p4))
         (ev/give got (e :id))))
(ev/sleep 0.01)
(pool/discard! broken)
(pool/checkin p4 broken)
(def fresh-id (ev/take got))
(assert (= 1 (st4 :closed)) "the discarded connection was closed")
(assert (= 2 fresh-id) "the waiter opened a fresh connection in the freed slot")
(assert (= 2 (st4 :conns)) "exactly one replacement was opened")

# -- close-all -----------------------------------------------------------

(def [p5 st5] (new-pool {:size 2}))
(def e1 (pool/checkout p5))
(def e2 (pool/checkout p5))
(pool/checkin p5 e1)
(pool/close-all! p5)
(assert (= 1 (st5 :closed)) "idle connections are closed on shutdown")
(pool/checkin p5 e2)
(assert (= 2 (st5 :closed)) "in-flight connections are closed when they come back")
(assert (not (first (protect (pool/checkout p5)))) "a closed pool refuses checkouts")

# -- a cancelled waiter leaves the wait list and frees nothing ----------

(def [p6 st6] (new-pool {:size 1 :checkout-timeout 5}))
(def held6 (pool/checkout p6))
(def wsup6 (ev/chan 1))
(def w6 (ev/go (fn [] (pool/checkout p6)) nil wsup6))
(ev/sleep 0.02)
(assert (= 1 ((pool/stats p6) :waiting)) "the second checkout is parked")
(ev/cancel w6 :abandon)
(ev/take wsup6)
(ev/sleep 0.01)
(assert (zero? ((pool/stats p6) :waiting)) "the cancelled waiter left the wait list (M10)")
(assert (empty? (p6 :waiters)) "and was removed from the array, not just marked dead")
# the held connection still returns to a usable pool
(pool/checkin p6 held6)
(def c6 (pool/checkout p6))
(assert (= (held6 :id) (c6 :id)) "the connection is reused after the waiter was cancelled")
(assert (= 1 (st6 :conns)) "no connection was leaked or reopened")
(pool/checkin p6 c6)

# -- a connection handed to a waiter cancelled in the window is rehomed --

(def [p7 st7] (new-pool {:size 1 :checkout-timeout 5}))
(def held7 (pool/checkout p7))
(def wsup7 (ev/chan 1))
(def w7 (ev/go (fn [] (pool/checkout p7)) nil wsup7))
(ev/sleep 0.02)
(assert (= 1 ((pool/stats p7) :waiting)) "the waiter is parked")
# hand the connection over, then cancel before the waiter consumes it
(pool/checkin p7 held7)
(ev/cancel w7 :abandon)
(ev/take wsup7)
(ev/sleep 0.01)
(def s7 (pool/stats p7))
(assert (zero? (s7 :waiting)) "the cancelled waiter is gone")
(assert (= 1 (s7 :created)) "the handed-over connection was not lost (H8)")
(assert (zero? (s7 :in-use)) "and is not stuck marked in use")
(def c7 (pool/checkout p7))
(assert (= (held7 :id) (c7 :id)) "the very same connection is handed out again")
(assert (= 1 (st7 :conns)) "no replacement was opened")
(pool/checkin p7 c7)

(print "pool-test: ok")
