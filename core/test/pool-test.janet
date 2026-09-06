(import ../void/core/pool :as pool)
(import ../void/core/errors :as errors)

# A resource is a table the fixture counts: how many were opened, how
# many closed, and which ones are alive. Nothing here knows a database.

(defn- fixture
  "[pool state]. `opts` go to pool/make on top of the fixture's hooks;
  `:dead?` and `:stale?` are predicates the fixture's :reusable? and
  :validate consult, so a test can flip a resource's fate."
  [&opt opts]
  (default opts {})
  (def st @{:opened 0 :closed 0 :fail-connect false})
  (def p
    (pool/make
      (merge {:name "test"
              :connect (fn []
                         (when (st :fail-connect) (error "server unreachable"))
                         (put st :opened (inc (st :opened)))
                         @{:id (st :opened) :dead false :stale false})
              :close (fn [r]
                       (put st :closed (inc (st :closed)))
                       (put r :closed true))
              :reusable? (fn [r] (not (r :dead)))
              :validate (fn [r] (not (r :stale)))}
             opts)))
  [p st])

# -- lazy creation, reuse, stats -----------------------------------------

(let [[p st] (fixture {:size 2})]
  (def a (pool/acquire p))
  (def b (pool/acquire p))
  (assert (= 2 (st :opened)) "resources are opened on demand, up to :size")
  (assert (not= (a :id) (b :id)) "two checkouts are two resources")
  (pool/release p a)
  (def c (pool/acquire p))
  (assert (= (a :id) (c :id)) "a released resource is the next one handed out")
  (assert (= 2 (st :opened)) "reuse opens nothing")
  (def s (pool/stats p))
  (assert (= 2 (s :size)) "stats carry the configured size")
  (assert (= 2 (s :created)))
  (assert (= 2 (s :in-use)) "b and c are both out")
  (assert (zero? (s :idle)))
  (assert (zero? (s :waiting)))
  (assert (= 3 (s :checkouts)) "every acquire is counted")
  (assert (zero? (s :waits)) "none of them had to wait")
  (assert (struct? s) "stats is a value, not a window into the pool")
  (assert (= :up ((pool/health p) :status)) "health is up while the pool is open")
  (pool/release p b)
  (pool/release p c)
  (assert (= 2 ((pool/stats p) :idle)) "both are back on the idle stack"))

# -- the owner's counters ------------------------------------------------

(let [[p _] (fixture {:counters {:queries 0 :query-us 0}})]
  (assert (zero? ((pool/stats p) :queries)) "an owner counter starts at its declared zero")
  (pool/note! p :queries 1 :query-us 120)
  (pool/note! p :queries 1 :query-us 30)
  (def s (pool/stats p))
  (assert (= 2 (s :queries)) "note! adds to a counter")
  (assert (= 150 (s :query-us)) "and to several at once")
  (pool/note! p :reconnects 1)
  (assert (= 1 ((pool/stats p) :reconnects)) "an undeclared counter starts at zero"))

# `with` releases on every exit

(let [[p st] (fixture {:size 1})]
  (def seen (pool/with p (fn [r] (r :id))))
  (assert (= 1 seen) "with hands the resource to the body")
  (assert (zero? ((pool/stats p) :in-use)) "and releases it on return")
  (def [ok err] (protect (pool/with p (fn [_] (error "boom")))))
  (assert (and (not ok) (= "boom" err)) "the body's error propagates")
  (assert (zero? ((pool/stats p) :in-use)) "and the resource still came back")
  (assert (= 1 (st :opened)) "on the same, single resource"))

# -- saturation parks the fiber; release hands over FIFO -----------------

(let [[p st] (fixture {:size 1 :checkout-timeout 2})]
  (def held (pool/acquire p))
  (def order @[])
  (def done (ev/chan 2))
  (defn waiter [name]
    (ev/go (fn []
             (def r (pool/acquire p))
             (array/push order name)
             (pool/release p r)
             (ev/give done name))))
  (waiter :first)
  (ev/sleep 0.01)
  (waiter :second)
  (ev/sleep 0.01)
  (assert (= 2 ((pool/stats p) :waiting)) "both fibers are parked on the pool")
  (assert (= 1 (st :opened)) "a saturated pool opens no extra resource")
  (pool/release p held)
  (ev/take done)
  (ev/take done)
  (assert (deep= @[:first :second] order) "waiters are served in arrival order")
  (assert (= 1 (st :opened)) "the single resource served both")
  (def s (pool/stats p))
  (assert (= 2 (s :waits)) "both waits are counted")
  (assert (>= (s :wait-us) 0) "wait time is measured")
  (assert (zero? (s :waiting)) "nobody is left parked"))

# -- exhaustion: a checkout nobody serves times out ----------------------

(let [[p st] (fixture {:size 1 :checkout-timeout 0.05 :timeout-kind :test/pool-timeout})]
  (def kept (pool/acquire p))
  (def t0 (os/clock :monotonic))
  (def [ok err] (protect (pool/acquire p)))
  (assert (not ok) "an unserved checkout throws")
  (assert (>= (- (os/clock :monotonic) t0) 0.04) "after waiting :checkout-timeout")
  (assert (= :test/pool-timeout (errors/kind err)) "as the pool's :timeout-kind")
  (assert (string/find "test pool checkout timed out" (errors/message err))
          "naming the pool")
  (assert (= 1 (get (errors/data err) :in-use)) "with the occupancy as data")
  (assert (= 1 ((pool/stats p) :timeouts)) "timeouts are counted")
  (assert (zero? ((pool/stats p) :waiting)) "the timed-out waiter left the wait list")
  (pool/release p kept)
  (def again (pool/acquire p))
  (assert (= (kept :id) (again :id)) "the pool recovers after a timeout")
  (assert (= 1 (st :opened)) "without opening anything")
  (pool/release p again))

(let [[p _] (fixture {:size 1 :checkout-timeout 0.05})]
  (def kept (pool/acquire p))
  (def [ok err] (protect (pool/acquire p)))
  (assert (= :void.core/pool-timeout (errors/kind err)) "the default kind is the kernel's")
  (assert (= 503 (errors/status err)) "and it is a 503")
  (pool/release p kept))

# -- a resource reported non-reusable is closed, not returned -----------

(let [[p st] (fixture {:size 1 :checkout-timeout 2})]
  (def r (pool/acquire p))
  (put r :dead true)
  (pool/release p r)
  (assert (= 1 (st :closed)) "a resource :reusable? refuses is closed")
  (assert (zero? ((pool/stats p) :idle)) "and never reaches the idle stack")
  (assert (zero? ((pool/stats p) :created)) "its slot is free")
  (def fresh (pool/acquire p))
  (assert (= 2 (fresh :id)) "the next checkout opens a fresh one")
  (pool/release p fresh))

# a non-reusable release frees the slot for a parked waiter

(let [[p st] (fixture {:size 1 :checkout-timeout 2})]
  (def broken (pool/acquire p))
  (def got (ev/chan 1))
  (ev/go (fn [] (ev/give got ((pool/acquire p) :id))))
  (ev/sleep 0.01)
  (put broken :dead true)
  (pool/release p broken)
  (assert (= 2 (ev/take got)) "the waiter opened a fresh resource in the freed slot")
  (assert (= 1 (st :closed)) "the broken one was closed")
  (assert (= 2 (st :opened)) "exactly one replacement was opened"))

# a :reusable? that throws has answered no

(let [[p st] (fixture {:size 1 :reusable? (fn [_] (error "cannot tell"))})]
  (def r (pool/acquire p))
  (pool/release p r)
  (assert (= 1 (st :closed)) "a throwing :reusable? closes the resource")
  (assert (zero? ((pool/stats p) :idle))))

# -- :validate: an idle resource that died is replaced ------------------

(let [[p st] (fixture {:size 1})]
  (def r (pool/acquire p))
  (pool/release p r)
  (put r :stale true)
  (def next (pool/acquire p))
  (assert (= 2 (next :id)) "a stale idle resource is not handed out")
  (assert (= 1 (st :closed)) "it was closed")
  (assert (= 1 ((pool/stats p) :created)) "and its slot reused for the fresh one")
  (pool/release p next))

# a :validate that repairs keeps the resource; one that throws closes it

(let [[p st] (fixture {:size 1 :validate (fn [r] (put r :stale false) r)})]
  (def r (pool/acquire p))
  (pool/release p r)
  (put r :stale true)
  (assert (= r (pool/acquire p)) "a validator returning the resource hands that one out")
  (assert (not (r :stale)) "repaired")
  (assert (zero? (st :closed)))
  (pool/release p r))

(let [[p st] (fixture {:size 1 :validate (fn [_] (error "reconnect refused"))})]
  (def r (pool/acquire p))
  (pool/release p r)
  (def [ok err] (protect (pool/acquire p)))
  (assert (and (not ok) (= "reconnect refused" err)) "a throwing validator reaches the caller")
  (assert (= 1 (st :closed)) "after the resource was closed")
  (assert (zero? ((pool/stats p) :created)) "and its slot freed")
  (assert (zero? ((pool/stats p) :in-use)) "nothing is counted as out"))

# -- a failing :connect releases the slot it reserved ------------------

(let [[p st] (fixture {:size 1})]
  (put st :fail-connect true)
  (def [ok err] (protect (pool/acquire p)))
  (assert (and (not ok) (= "server unreachable" err)) "the connect error reaches the caller as is")
  (assert (zero? ((pool/stats p) :created)) "the slot is not leaked")
  (put st :fail-connect false)
  (assert (pool/acquire p) "so the next checkout can open one"))

# -- close!: idle closed now, in-use on return, waiters woken to fail ---

(let [[p st] (fixture {:size 2})]
  (def a (pool/acquire p))
  (def b (pool/acquire p))
  (pool/release p a)
  (pool/close! p)
  (assert (pool/closed? p))
  (assert (= 1 (st :closed)) "idle resources are closed on shutdown")
  (pool/release p b)
  (assert (= 2 (st :closed)) "in-flight resources are closed when they come back")
  (assert (= :down ((pool/health p) :status)))
  (def [ok err] (protect (pool/acquire p)))
  (assert (and (not ok) (= :void.core/pool-closed (errors/kind err)))
          "a closed pool refuses checkouts"))

(let [[p st] (fixture {:size 1 :checkout-timeout 5})]
  (def held (pool/acquire p))
  (def outcome (ev/chan 1))
  (ev/go (fn [] (ev/give outcome (protect (pool/acquire p)))))
  (ev/sleep 0.01)
  (assert (= 1 ((pool/stats p) :waiting)) "a second checkout is parked")
  (pool/close! p)
  (def [ok err] (ev/take outcome))
  (assert (not ok) "the parked waiter is woken and fails")
  (assert (= :void.core/pool-closed (errors/kind err)) "with the closed kind, not a timeout")
  (assert (zero? ((pool/stats p) :timeouts)) "and it is not counted as a timeout")
  (assert (empty? (p :waiters)) "no waiter lingers")
  (pool/release p held)
  (assert (= 1 (st :closed)) "the held resource is closed on its way back"))

# -- a waiter cancelled mid-wait leaves the list and frees nothing ------

(let [[p st] (fixture {:size 1 :checkout-timeout 5})]
  (def held (pool/acquire p))
  (def sup (ev/chan 1))
  (def w (ev/go (fn [] (pool/acquire p)) nil sup))
  (ev/sleep 0.02)
  (assert (= 1 ((pool/stats p) :waiting)) "the second checkout is parked")
  (ev/cancel w :abandon)
  (ev/take sup)
  (ev/sleep 0.01)
  (assert (zero? ((pool/stats p) :waiting)) "the cancelled waiter left the wait list")
  (assert (empty? (p :waiters)) "and was removed from the array, not just marked dead")
  (pool/release p held)
  (def again (pool/acquire p))
  (assert (= (held :id) (again :id)) "the resource is reused after the waiter was cancelled")
  (assert (= 1 (st :opened)) "nothing was leaked or reopened")
  (pool/release p again))

# -- a resource handed to a waiter cancelled in the window is rehomed ---

(let [[p st] (fixture {:size 1 :checkout-timeout 5})]
  (def held (pool/acquire p))
  (def sup (ev/chan 1))
  (def w (ev/go (fn [] (pool/acquire p)) nil sup))
  (ev/sleep 0.02)
  # hand the resource over, then cancel before the waiter consumes it
  (pool/release p held)
  (ev/cancel w :abandon)
  (ev/take sup)
  (ev/sleep 0.01)
  (def s (pool/stats p))
  (assert (zero? (s :waiting)) "the cancelled waiter is gone")
  (assert (= 1 (s :created)) "the handed-over resource was not lost")
  (assert (zero? (s :in-use)) "and is not stuck marked in use")
  (assert (= 1 (s :idle)) "it is back on the idle stack")
  (def again (pool/acquire p))
  (assert (= (held :id) (again :id)) "the very same resource is handed out again")
  (assert (= 1 (st :opened)) "no replacement was opened")
  (pool/release p again))

# -- the losing ordering: the release is scheduled BEFORE the cancel ----
#
# The test above releases and cancels from the same fiber, so the run
# queue is [child taker, waiter's cancel] and the child always wins.
# Under load the queue is the other way round: another handler's
# release is already scheduled when the request deadline cancels the
# waiter, so the cancel supersedes whatever the release scheduled the
# child with. A resource travelling through the channel is lost here —
# :created stays, :in-use is zero, and a :size 1 pool never opens
# another. The handover goes through the waiter record instead.

(let [[p st] (fixture {:size 1 :checkout-timeout 0.2})]
  (def held (pool/acquire p))
  (def sup (ev/chan 1))
  (def w (ev/go (fn [] (pool/acquire p)) nil sup))
  (ev/sleep 0.02)
  # queue: [releaser, w's cancel] — the release hands over to the child
  # taker, then the cancel lands on w before the child runs
  (ev/go (fn releaser [] (pool/release p held)))
  (ev/cancel w :abandon)
  (ev/take sup)
  (ev/sleep 0.01)
  (def s (pool/stats p))
  (assert (zero? (s :waiting)) "the cancelled waiter is gone")
  (assert (= 1 (s :created)) "the resource released under the cancel was not lost")
  (assert (zero? (s :in-use)) "and is not stuck marked in use")
  (assert (= 1 (s :idle)) "it is back on the idle stack")
  (def again (pool/acquire p))
  (assert (= (held :id) (again :id)) "the very same resource is handed out again, without a timeout")
  (assert (= 1 (st :opened)) "no replacement was opened")
  (pool/release p again))

# a resource handed to a cancelled waiter goes to the next live waiter

(let [[p st] (fixture {:size 1 :checkout-timeout 5})]
  (def held (pool/acquire p))
  (def sup (ev/chan 1))
  (def doomed (ev/go (fn [] (pool/acquire p)) nil sup))
  (ev/sleep 0.01)
  (def got (ev/chan 1))
  (ev/go (fn [] (def r (pool/acquire p)) (ev/give got (r :id)) (pool/release p r)))
  (ev/sleep 0.01)
  (assert (= 2 ((pool/stats p) :waiting)))
  (pool/release p held)
  (ev/cancel doomed :abandon)
  (ev/take sup)
  (assert (= (held :id) (ev/take got)) "the rehomed resource reached the waiter behind the cancelled one")
  (assert (= 1 (st :opened)) "without opening a second one"))

# -- a retry announced under the checkout deadline -------------------------
#
# A slot freed by a non-reusable release is announced to the oldest
# waiter as a retry. When the waiter's own deadline fires in the same
# loop turn — the timer phase queues the child's cancel and the
# releaser's resumption back to back — the doorbell never reaches the
# child: it dies of the cancel without taking. The retry mark lives in
# the waiter record, so the waiter still learns of the free slot and
# opens a fresh resource instead of timing out on it. The thread is
# blocked past both timers to make that turn happen on purpose.

(let [[p st] (fixture {:size 1 :checkout-timeout 0.05})]
  (def held (pool/acquire p))
  (def sup (ev/chan 1))
  (def w (ev/go (fn [] (pool/acquire p)) nil sup))
  (ev/go (fn releaser []
           (ev/sleep 0.02)
           (put held :dead true)
           (pool/release p held)))
  (ev/sleep 0)
  (assert (= 1 ((pool/stats p) :waiting)) "the second checkout is parked under its deadline")
  (os/sleep 0.1)
  (def [sig fib] (ev/take sup))
  (assert (= :ok sig) "the waiter told of the freed slot does not time out on it")
  (def got (fiber/last-value fib))
  (assert (= 2 (got :id)) "it opened a fresh resource in the slot the dead one left")
  (assert (= 1 (st :closed)) "the dead resource was closed")
  (assert (zero? ((pool/stats p) :timeouts)) "and nothing was counted as a timeout")
  (pool/release p got))

# -- a retry announced to a waiter cancelled in the window is passed on ---
#
# The same losing ordering as the release above, for the retry: the
# freed slot is announced to w, then w's cancel lands before its child
# runs and supersedes the doorbell. A retry that travelled through the
# channel was lost with it, and the waiter behind w sat until its own
# timeout on a slot nobody would open. The mark is in w's record, and
# w's exit hands it to the next live waiter.

(let [[p st] (fixture {:size 1 :checkout-timeout 0.2})]
  (def held (pool/acquire p))
  (def sup (ev/chan 1))
  (def doomed (ev/go (fn [] (pool/acquire p)) nil sup))
  (ev/sleep 0.01)
  (def sup2 (ev/chan 1))
  (def behind (ev/go (fn [] (def r (pool/acquire p)) (pool/release p r) (r :id)) nil sup2))
  (ev/sleep 0.01)
  (assert (= 2 ((pool/stats p) :waiting)))
  (put held :dead true)
  # queue: [releaser, doomed's cancel] — the release closes the dead
  # resource and announces the slot to doomed; the cancel lands on
  # doomed before its child runs
  (ev/go (fn releaser [] (pool/release p held)))
  (ev/cancel doomed :abandon)
  (ev/take sup)
  (def [sig fib] (ev/take sup2))
  (assert (= :ok sig) "the waiter behind the cancelled one was told of the freed slot, and did not time out")
  (assert (= 2 (fiber/last-value fib)) "it opened a fresh resource in that slot")
  (assert (= 1 (st :closed)) "the dead one was closed")
  (assert (zero? ((pool/stats p) :timeouts)))
  (assert (zero? ((pool/stats p) :waiting)) "nobody is left parked"))

# -- close! between a handover and the waiter's return -------------------
#
# A release pops the oldest waiter and writes the resource into its
# record; close! runs before that waiter does, so wake-all cannot see
# it. Without a second look the waiter would return the resource and
# the closed pool would count a checkout — "no more checkouts" would
# hold for every waiter but this one.

(let [[p st] (fixture {:size 1 :checkout-timeout 0.2})]
  (def held (pool/acquire p))
  (def sup (ev/chan 1))
  (def w (ev/go (fn [] (pool/acquire p)) nil sup))
  (ev/sleep 0.02)
  (pool/release p held)
  (pool/close! p)
  (def [sig fib] (ev/take sup))
  (assert (= :error sig) "the waiter served just before close! does not get a checkout")
  (assert (= :void.core/pool-closed (errors/kind (fiber/last-value fib)))
          "it fails with the closed kind, like the waiters close! woke")
  (assert (= 1 (st :closed)) "the resource it was handed is closed on its way back")
  (def s (pool/stats p))
  (assert (zero? (s :in-use)) "and is not counted as checked out")
  (assert (zero? (s :created))))

# -- make refuses a pool it cannot run -----------------------------------

(assert (not (first (protect (pool/make {:close (fn [_])}))))
        "make needs :connect")
(assert (not (first (protect (pool/make {:connect (fn [] 1)}))))
        "make needs :close")

(print "void/core/pool test OK")
