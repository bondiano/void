# The built-in :db/pool check: the pure decision, the grace period,
# a real pool driven to exhaustion, and the whole thing wired through
# a state — plus the skip: no pool means no opinion, not a throw.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/db/pool :as pool)
(import void/pressure/checks :as checks)
(import void/pressure/state :as state)

(log/set-level! "void.pressure" :error)

# -- the decision, as a pure function ------------------------------------

(def calm {:size 5 :in-use 2 :waiting 0 :timeouts 0})
(def busy {:size 5 :in-use 5 :waiting 3 :timeouts 1})

(def [ok-r ok-since] (checks/evaluate calm 1 2 nil 100))
(assert (get ok-r :ok) "a pool with nobody waiting is not pressure")
(assert (nil? ok-since) "and starts no clock")

(def [first-r first-since] (checks/evaluate busy 1 2 nil 100))
(assert (get first-r :ok)
        "the first exhausted reading is a burst until the grace period says otherwise — back-pressure is the pool doing its job")
(assert (= 100 first-since) "but the clock starts")

(def [held-r held-since] (checks/evaluate busy 1 2 100 103))
(assert (not (get held-r :ok))
        "exhaustion that holds past the grace period is pressure")
(assert (= 100 held-since) "and the clock keeps its epoch")
(assert (string/find "db pool exhausted" (held-r :reason)))
(assert (string/find "3 waiting" (held-r :reason))
        "the reason carries the numbers an operator reaches for first")

(def [reset-r reset-since] (checks/evaluate calm 1 2 100 103))
(assert (get reset-r :ok))
(assert (nil? reset-since)
        "one calm reading resets the clock — the grace period must hold *without a break*")

(assert (get (first (checks/evaluate busy 0 0 nil 100)) :ok)
        ":db-pool-max-waiting 0 turns the check off")
(assert (get (first (checks/evaluate {:size 5 :in-use 5 :waiting 2} 3 0 nil 100)) :ok)
        "a threshold above the queue is not reached")

# -- the factory over a stubbed reader -----------------------------------

(var stub calm)
(def check (checks/make-db-pool-check (fn [] stub) {:max-waiting 1 :grace 0.05}))

(assert (get (check) :ok) "calm is calm")
(set stub busy)
(assert (get (check) :ok) "the first exhausted reading only starts the clock")
(ev/sleep 0.06)
(assert (not (get (check) :ok)) "held past the grace period, it trips")
(set stub calm)
(assert (get (check) :ok))
(set stub busy)
(assert (get (check) :ok)
        "and after a calm reading the grace period starts over")

(set stub nil)
(assert (get (check) :ok) "a reader with nothing to read is no opinion, not a throw")

# -- a real pool, exhausted ----------------------------------------------

(def stub-driver
  {:connect (fn [] @{})
   :close (fn [_] nil)})

(def p (pool/make stub-driver {:size 1 :checkout-timeout 1}))
(def held (pool/checkout p))

# a second checkout has to park: the pool is at :size with nothing idle
(def parked (ev/go (fn [] (pool/checkin p (pool/checkout p)))))
(ev/sleep 0.02)
(assert (= 1 ((pool/stats p) :waiting)) "the fiber is parked")

(def live-check
  (checks/make-db-pool-check (fn [] (pool/stats p)) {:max-waiting 1 :grace 0}))
(def verdict (live-check))
(assert (not (get verdict :ok)) "an exhausted real pool trips the check")
(assert (string/find "size 1, in use 1" (verdict :reason)))

# -- through a state: the check is one more reason to shed ---------------

(def st (state/make {:max-loop-lag 100 :recovery-samples 1}
                    [{:name :void.db/pool :fn live-check}]))
(assert (= :high (state/observe! st @{:loop-lag 1}))
        "the pool's exhaustion sheds, whatever the loop says")
(def r (get-in st [:reasons 0]))
(assert (and (= :void.db/pool (r :signal)) (r :check)))
(assert (string/find "db pool exhausted" (r :reason)))

# hand the connection over: the parked fiber runs, returns it, calm again
(pool/checkin p held)
(ev/sleep 0.02)
(assert (zero? ((pool/stats p) :waiting)))
(assert (= :recovered (state/observe! st @{:loop-lag 1}))
        "and a pool with room again is a process that stops shedding")
(pool/close-all! p)

# -- the shipped contribution outside any boot ---------------------------

(assert (= :void.db/pool (checks/db-pool-contribution :name))
        "the contribution watches the component the audit named")
(assert (get ((checks/db-pool-contribution :fn)) :ok)
        "with no running boot there is no pool to watch — {:ok true}, never a throw")

(print "checks-test ok")
