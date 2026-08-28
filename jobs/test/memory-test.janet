(import ../test-support/paths)
(import ../test-support/conformance :as conformance)
(import void/core/log :as log)
(import void/jobs/backend :as backend)
(import void/jobs/memory :as memory)
(import void/jobs/record :as record)

(log/set-level! "void.jobs" :error)

# -- the contract --------------------------------------------------------

(conformance/run! "memory" (memory/store (memory/make)))

# -- what is particular to a table in this heap --------------------------

(def m (memory/make {:max-completed 2 :max-dead 2}))
(def b (backend/normalize (memory/store m)))

(defn- run-one [job]
  (def r ((b :push!) (record/make {:job job :queue :default})))
  (def c ((b :claim!) {:queues [:default] :now (os/clock :realtime) :token "w"}))
  ((b :settle!) (record/complete! c :ok (os/clock :realtime)))
  c)

(each j [:a :b :c :d] (run-one j))
(assert (= 2 (get-in ((b :counts)) [:default :completed]))
        "finished records are trimmed to the retention cap")
(assert (= 2 (length (m :jobs)))
        "and the trimmed ones are gone from the table, not merely from the ring")

# a queue of a thousand jobs is a table of a thousand entries and no more
(def big (backend/normalize (memory/store (memory/make))))
(each i (range 100)
  ((big :push!) (record/make {:job :bulk :queue :default :priority (% i 10)})))
(assert (= 100 (get-in ((big :counts)) [:default :pending])))
(def first-out ((big :claim!) {:queues [:default] :now (os/clock :realtime) :token "w"}))
(assert (zero? (first-out :priority)) "the claim scans, and the scan is exact")

# -- claim order ---------------------------------------------------------

(def order-m (memory/make))
(def ob (backend/normalize (memory/store order-m)))
(def t (os/clock :realtime))
(each id ["zzz" "aaa"]
  ((ob :push!) (record/make {:job :tie :queue :default :priority 5 :run-at t :id id})))
(assert (= "aaa" (((ob :claim!) {:queues [:default] :now t :token "w"}) :id))
        "a priority tie goes to the id that sorts first, and ids sort by creation time")

(def prefs (memory/make))
(def pb (backend/normalize (memory/store prefs)))
((pb :push!) (record/make {:job :ordinary :queue :default :priority 1}))
((pb :push!) (record/make {:job :urgent :queue :critical :priority 9}))
(assert (= :urgent (((pb :claim!) {:queues [:critical :default]
                                   :now (os/clock :realtime) :token "w"}) :job))
        "the worker's queue preference beats priority — that is what preference means")
