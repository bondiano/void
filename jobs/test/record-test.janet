(import ../test-support/paths)
(import void/jobs/record :as record)

# -- construction --------------------------------------------------------

(def r (record/make {:job :send :args [1 :two] :queue :mail :priority 2
                     :max-attempts 5 :timeout 30}))
(assert (= :pending (r :state)) "a new record is pending")
(assert (zero? (r :attempt)) "with no attempt yet")
(assert (= [1 :two] (r :args)) "and its arguments as a tuple")
(assert (<= (r :run-at) (os/clock :realtime)) "runnable from now")
(assert (record/runnable? r (os/clock :realtime)))

(def later (record/make {:job :send :run-at (+ 60 (os/clock :realtime))}))
(assert (not (record/runnable? later (os/clock :realtime))) "a delayed record is not")

(def parent (record/make {:job :parent :children-left 2}))
(assert (= :waiting (parent :state)) "a record with children waits for them")
(assert (record/live? parent) "and is still work owed")

(def [ok _] (protect (record/make {:args [1]})))
(assert (not ok) "a record without a job name is refused")

# ids sort by creation time, which is what breaks a priority tie in
# favour of whoever has waited longer
(def stamps (map |(record/new-id $) [1000 2000 3000]))
(assert (deep= stamps (sorted stamps)) "ids sort in the order they were made")
(assert (= 3 (length (distinct (map |(string/slice $ 11) stamps))))
        "and are still distinct within one second — the tail is random")

# -- transitions ---------------------------------------------------------

(def t 1000)
(def j (record/make {:job :x :max-attempts 2 :now t}))
(record/start! j "w1" t)
(assert (= :running (j :state)))
(assert (= 1 (j :attempt)) "a claim counts as an attempt")
(assert (= "w1" (j :token)))

(record/retry! j "boom" (+ t 5) t)
(assert (= :pending (j :state)) "a retry goes back to the queue")
(assert (nil? (j :token)) "with no claim on it")
(assert (= 1 (j :attempt)) "keeping the attempts it has used")
(assert (= (+ t 5) (j :run-at)) "and waiting until it may run again")
(assert (= 1 (length (j :failures))) "the failure is remembered")

(record/start! j "w2" (+ t 6))
(record/kill! j "boom again" (+ t 7))
(assert (= :dead (j :state)) "out of attempts is the dead letter queue")
(assert (= 2 (length (j :failures))) "with both failures on it")
(assert (not (record/live? j)))

(record/revive! j (+ t 8))
(assert (= :pending (j :state)) "reviving requeues it")
(assert (zero? (j :attempt)) "with its attempts back")
(assert (= 2 (length (j :failures)))
        "and its history intact — why it died is why somebody is retrying it")

(def claimed (record/make {:job :y}))
(record/start! claimed "w" 100)
(record/defer! claimed 200)
(assert (zero? (claimed :attempt))
        "a deferral gives the attempt back — a rate limit is not a failure")

(def many (record/make {:job :z}))
(for i 0 20
  (record/start! many "w" i)
  (record/retry! many (string "e" i) i i))
(assert (= record/max-failures (length (many :failures)))
        "the failure list is capped — the tail belongs to a log, not a queue")
(assert (= "e19" (get (last (many :failures)) :error)) "and keeps the newest")

# -- stalling ------------------------------------------------------------

(def held (record/make {:job :h}))
(record/start! held "w" 100)
(assert (not (record/stalled? held 150 60)) "a fresh claim is not stalled")
(assert (record/stalled? held 200 60) "an old one is")
(put held :claimed-at 190)
(assert (not (record/stalled? held 200 60)) "a refreshed one is not")

# -- serialization -------------------------------------------------------

(def full (record/make {:job :ser :args [1 "a" :k {:m [1 2]}]}))
(record/start! full "w" 100)
(record/complete! full {:ok true} 101)
(def round (record/decode (record/encode full)))
(assert (= (full :id) (round :id)) "a record survives the round trip")
(assert (deep= (full :args) (tuple ;(round :args))))
(assert (deep= (full :result) (round :result)))

(def [eok eerr] (protect (record/encode-value (fn [] 1) "the arguments")))
(assert (not eok) "a function cannot be queued")
(assert (string/find "plain data" eerr) "and the error says what may be")

(assert (nil? (record/decode-value nil)) "an absent column decodes to nothing")

# -- rendering -----------------------------------------------------------

(def line (record/summary full 200))
(assert (string/find "completed" line) "the summary says the state")
(assert (string/find "ser" line) "and the job")

(print "record-test ok")
