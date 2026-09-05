# The backend conformance suite: one set of assertions, run against
# every `:void/jobs-backend` there is.
#
# Three stores — a table in this heap, rows in a database, hashes in
# redis — answer the same eight questions, and the runtime above them
# is written once. That is the whole claim the contract makes, and a
# suite that only ever ran against the in-process backend would be a
# suite that never checked it. So this file holds the assertions and
# memory-test / db-test / redis-test each hand it a backend.
#
# What it does NOT test is the runtime: retries, timeouts, rate limits
# and flows are decisions, they live above the contract, and they are
# tested once in worker-test against the in-process backend.

(import void/jobs/backend :as backend)
(import void/jobs/record :as record)

(defn- pending [job &opt extra]
  (record/make (merge {:job job :queue :default} (or extra {}))))

(defn- claim [b &opt opts]
  ((b :claim!) (merge {:queues [:default] :now (os/clock :realtime) :token "w1"}
                      (or opts {}))))

(defn run!
  ``Assert that `b` behaves like a `:void/jobs-backend`. `name` names
  the store in the failure messages, because "a claim came back twice"
  is a different bug in each of them.``
  [name b0]
  (def b (backend/normalize b0))
  (defn note [msg] (string name ": " msg))

  # -- push and fetch ----------------------------------------------------

  (def r1 ((b :push!) (pending :alpha)))
  (assert r1 (note "a pushed record comes back"))
  (assert (= :pending (r1 :state)) (note "pending"))
  (def fetched ((b :fetch) (r1 :id)))
  (assert (= (r1 :id) (fetched :id)) (note "and can be fetched by id"))
  (assert (= :alpha (fetched :job)) (note "with its job name"))
  (assert (nil? ((b :fetch) "no-such-id")) (note "an unknown id is nil, not an error"))

  # arguments survive the round trip whatever they are
  (def r-args ((b :push!) (pending :alpha {:args [1 "two" :three {:a [1 2]}]})))
  (def back ((b :fetch) (r-args :id)))
  (assert (deep= [1 "two" :three {:a [1 2]}] (tuple ;(back :args)))
          (note "arguments survive the store"))

  # -- claiming ----------------------------------------------------------

  (def taken (claim b))
  (assert taken (note "a runnable record can be claimed"))
  (assert (= :running (taken :state)) (note "and comes back running"))
  (assert (= 1 (taken :attempt)) (note "with the attempt counted"))
  (assert (= "w1" (taken :token)) (note "and the claimant's token on it"))

  # a claim is exclusive: the second claim gets the *other* record
  (def second-claim (claim b {:token "w2"}))
  (assert second-claim (note "the other record is still claimable"))
  (assert (not= (taken :id) (second-claim :id))
          (note "a claimed record is not handed out twice"))
  (assert (nil? (claim b {:token "w3"})) (note "and an empty queue claims nothing"))

  # a queue nobody asked for is not claimed from
  (def other ((b :push!) (pending :beta {:queue :mail})))
  (assert (nil? (claim b)) (note ":default does not claim :mail"))
  (def mail (claim b {:queues [:mail]}))
  (assert (= (other :id) (mail :id)) (note "and :mail does"))

  # -- settling ----------------------------------------------------------

  (record/complete! taken :done (os/clock :realtime))
  ((b :settle!) taken)
  (def done ((b :fetch) (taken :id)))
  (assert (= :completed (done :state)) (note "a settled record keeps its state"))
  (assert (= :done (done :result)) (note "and its result"))

  (record/retry! second-claim "boom" (+ 3600 (os/clock :realtime)) (os/clock :realtime))
  ((b :settle!) second-claim)
  (def retried ((b :fetch) (second-claim :id)))
  (assert (= :pending (retried :state)) (note "a retry goes back to pending"))
  (assert (= "boom" (retried :error)) (note "carrying the error"))
  (assert (= 1 (length (retried :failures))) (note "and the failure"))
  (assert (nil? (claim b)) (note "but not before its :run-at"))
  (assert (claim b {:now (+ 7200 (os/clock :realtime))})
          (note "and it is claimable once that arrives"))

  # -- delays ------------------------------------------------------------

  (def later ((b :push!) (pending :delayed {:run-at (+ 60 (os/clock :realtime))})))
  (assert (nil? (claim b)) (note "a delayed record is not claimed early"))
  (def now-due (claim b {:now (+ 120 (os/clock :realtime))}))
  (assert (= (later :id) (now-due :id)) (note "and is claimed once it is due"))
  ((b :settle!) (record/complete! now-due nil (os/clock :realtime)))

  # -- priority and order ------------------------------------------------

  ((b :clear!) {})
  (def low ((b :push!) (pending :low {:priority 9})))
  (def high ((b :push!) (pending :high {:priority 1})))
  (def mid ((b :push!) (pending :mid {:priority 5})))
  (assert (= (high :id) ((claim b) :id)) (note "the lowest :priority number runs first"))
  (assert (= (mid :id) ((claim b) :id)) (note "then the next"))
  (assert (= (low :id) ((claim b) :id)) (note "then the last"))

  # -- groups ------------------------------------------------------------

  ((b :clear!) {})
  (def g1 ((b :push!) (pending :tenant {:group "acme" :priority 1})))
  (def g2 ((b :push!) (pending :tenant {:group "globex" :priority 2})))
  (def skipped (claim b {:skip-groups {"acme" true}}))
  (assert (= (g2 :id) (skipped :id))
          (note "a capped group is skipped, not waited for"))

  # -- unique keys -------------------------------------------------------

  ((b :clear!) {})
  (def u1 ((b :push!) (pending :unique {:unique-key "u:1"})))
  (assert u1 (note "the first holder of a unique key is stored"))
  (assert (nil? ((b :push!) (pending :unique {:unique-key "u:1"})))
          (note "the second is refused"))
  (def u-claimed (claim b))
  (assert (nil? ((b :push!) (pending :unique {:unique-key "u:1"})))
          (note "and still refused while it runs"))
  ((b :settle!) (record/complete! u-claimed nil (os/clock :realtime)))
  (assert ((b :push!) (pending :unique {:unique-key "u:1"}))
          (note "the key is released when the job finishes"))

  # -- listing and counting ----------------------------------------------

  ((b :clear!) {})
  ((b :push!) (pending :listed))
  ((b :push!) (pending :listed {:queue :mail}))
  (def all ((b :list) {}))
  (assert (= 2 (length all)) (note "list sees both"))
  (assert (= 1 (length ((b :list) {:queue :mail}))) (note "and filters by queue"))
  (assert (= 1 (length ((b :list) {:limit 1}))) (note "and honours its limit"))
  (def counts ((b :counts)))
  (assert (= 1 (get-in counts [:default :pending])) (note "counts by queue and state"))
  (assert (= 1 (get-in counts [:mail :pending])))

  # -- removing and clearing ---------------------------------------------

  (def doomed ((b :push!) (pending :doomed)))
  (assert ((b :remove!) (doomed :id)) (note "a record can be removed"))
  (assert (nil? ((b :fetch) (doomed :id))) (note "and is gone"))
  (assert (not ((b :remove!) (doomed :id))) (note "removing it twice says so"))
  (assert (pos? ((b :clear!) {:queue :mail})) (note "clear takes a queue"))
  (assert (empty? ((b :list) {:queue :mail})) (note "and empties it"))

  # -- reaping -----------------------------------------------------------

  (when (backend/supports-reaping? b)
    ((b :clear!) {})
    ((b :push!) (pending :stalls))
    (def held (claim b {:token "gone"}))
    (assert (empty? ((b :reap!) {:now (os/clock :realtime) :ttl 60 :token "w2"}))
            (note "a fresh claim is not stalled"))
    (def reaped ((b :reap!) {:now (+ 3600 (os/clock :realtime)) :ttl 60 :token "w2"}))
    (assert (= 1 (length reaped)) (note "an abandoned claim is reaped"))
    (assert (= "w2" ((first reaped) :token))
            (note "and taken over rather than released — a second reaper finds nothing"))
    (assert (empty? ((b :reap!) {:now (+ 3600 (os/clock :realtime)) :ttl 60 :token "w3"}))
            (note "which is exactly what the second reaper finds")))

  # -- settle fencing ----------------------------------------------------
  #
  # The other half of reaping: worker A stalls, a reaper hands its job
  # to B, and A finally finishes anyway. A's settle, fenced by the
  # token it claimed under, must not overwrite the state B now owns.

  (when (backend/supports-reaping? b)
    ((b :clear!) {})
    ((b :push!) (pending :fenced))
    (def mine (claim b {:token "stalled"}))
    (def reaped ((b :reap!) {:now (+ 3600 (os/clock :realtime)) :ttl 60 :token "taker"}))
    (assert (= (mine :id) ((first reaped) :id)) (note "the stalled claim was taken over"))
    (record/complete! mine :late (os/clock :realtime))
    (assert (nil? ((b :settle!) mine "stalled"))
            (note "a settle fenced by a lost token does not land"))
    (def still ((b :fetch) (mine :id)))
    (assert (= :running (still :state))
            (note "the record keeps the state the reaper gave it"))
    (assert (= "taker" (still :token)) (note "and the new owner's token"))
    (def theirs (first reaped))
    (record/complete! theirs :first (os/clock :realtime))
    (assert ((b :settle!) theirs "taker")
            (note "while the live claim settles through the same fence")))

  # -- heartbeats --------------------------------------------------------

  (when (backend/supports-heartbeat? b)
    ((b :clear!) {})
    ((b :push!) (pending :slow))
    (def slow (claim b))
    (def later-t (+ 1000 (os/clock :realtime)))
    ((b :touch!) [(slow :id)] later-t)
    (assert (empty? ((b :reap!) {:now (+ 1010 later-t) :ttl 3600 :token "w9"}))
            (note "a refreshed claim is not stalled")))

  # a heartbeat is fenced the way a settle is: the old holder of a
  # reaped claim refreshes nothing
  (when (and (backend/supports-heartbeat? b) (backend/supports-reaping? b))
    ((b :clear!) {})
    ((b :push!) (pending :beats))
    (def held (claim b {:token "stalled"}))
    ((b :reap!) {:now (+ 3600 (os/clock :realtime)) :ttl 60 :token "taker"})
    (assert (zero? ((b :touch!) [(held :id)] (+ 7200 (os/clock :realtime)) "stalled"))
            (note "a heartbeat under a lost token refreshes nothing"))
    (assert (= 1 ((b :touch!) [(held :id)] (+ 7200 (os/clock :realtime)) "taker"))
            (note "and one under the live token refreshes the claim")))

  # -- flows -------------------------------------------------------------

  (when (backend/supports-flows? b)
    ((b :clear!) {})
    (def parent ((b :push!) (pending :parent {:children-left 2})))
    (assert (= :waiting (parent :state)) (note "a parent with children waits"))
    (def c1 ((b :push!) (pending :child {:parent (parent :id)})))
    (def c2 ((b :push!) (pending :child {:parent (parent :id)})))
    (def r1 (claim b))
    ((b :settle!) (record/complete! r1 :one (os/clock :realtime)))
    (assert (nil? ((b :release-parent!) r1))
            (note "one child of two does not release the parent"))
    (def r2 (claim b))
    ((b :settle!) (record/complete! r2 :two (os/clock :realtime)))
    (def released ((b :release-parent!) r2))
    (assert released (note "the last child does"))
    (assert (= :pending (released :state)) (note "and the parent becomes claimable"))
    (assert (= 2 (length (released :children)))
            (note "with what both children returned"))
    (assert (= (parent :id) ((claim b) :id))
            (note "which a worker then picks up like anything else")))

  # -- locks -------------------------------------------------------------

  (def t (os/clock :realtime))
  (assert ((b :lock!) "conf:lock" 30 "a" t) (note "a lease can be taken"))
  (assert (not ((b :lock!) "conf:lock" 30 "b" t)) (note "and not by two at once"))
  (assert ((b :lock!) "conf:lock" 30 "a" t) (note "the holder may renew it"))
  ((b :unlock!) "conf:lock" "a")
  (assert ((b :lock!) "conf:lock" 30 "b" t) (note "and release it for the next one"))
  ((b :unlock!) "conf:lock" "b")

  # -- rate limiting -----------------------------------------------------

  (def rt (b :rate-take!))
  (def window (string "conf-" (math/floor (* 1000 (os/clock :realtime)))))
  (def rate-queue (keyword window))
  (assert (zero? (rt rate-queue 2 60 t)) (note "the first call in a window passes"))
  (assert (zero? (rt rate-queue 2 60 t)) (note "and so does the second"))
  (assert (pos? (rt rate-queue 2 60 t)) (note "the third is told how long to wait"))
  (assert (zero? (rt rate-queue nil nil t)) (note "no limit means no wait"))

  ((b :clear!) {})
  (printf "%s: backend conformance ok" name)
  true)
