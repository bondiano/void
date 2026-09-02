(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/pressure :as pressure)
(import void/pressure/state :as state)

(log/set-level! "void.pressure" :error)

(def plugins ["void/pressure/init"])

(defn- config [extra]
  {:env @{} :cli (merge {:log {:level :error}} extra)})

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test :config (config {})}))
(assert (report :ok) "the plugin composes on its own — no void/http anywhere in it")
(assert (index-of :pressure/sampler (report :components)))
(assert (get-in report [:extensions :void.pressure/check])
        "and it owns the point ADR-0019 reserved for it")
(assert (= 1 (get-in report [:extensions :void.pressure/check :contributions]))
        "with the built-in :db/pool check already contributed — the motivating example of the module docstring, not left to prose")

(each [slice reason]
  [[{:pressure {:sample-interval 0}} "a sampler that never samples"]
   [{:pressure {:max-loop-lag -1}} "a negative lag limit"]
   [{:pressure {:recovery-ratio 2}} "a recovery bar above the limit it recovers from"]
   [{:pressure {:recovery-samples 0}} "recovering on no clean samples at all"]
   [{:pressure {:enabled "yes"}} "a flag that is not a boolean"]]
  (def [ok] (protect (plugin/dry-run {:plugins plugins :profile :test
                                      :config (config slice)})))
  (assert (not ok) (string reason " fails the boot")))

# -- defaults ------------------------------------------------------------

(assert (= 100 (pressure/defaults :max-loop-lag))
        "the default lag limit is two orders of magnitude over the §8.2 budget — a process there has already missed every latency budget it has")
(assert (zero? (pressure/defaults :max-rss-bytes))
        "and the memory ceiling is off by default: it is the deployment's number, not a guess")
(assert (= 1 (pressure/defaults :db-pool-max-waiting))
        "one parked fiber already means every connection is checked out")
(assert (= 2 (pressure/defaults :db-pool-wait-grace))
        "and the check sheds before the pool's own 5 s :checkout-timeout starts timing those fibers out")

# -- started -------------------------------------------------------------

(def boot (plugin/start! {:plugins plugins :profile :test
                          :config (config {:pressure {:sample-interval 0.01
                                                      :max-loop-lag 100}})}))

(def st (get-in boot [:system :instances :pressure/sampler]))
(assert st "the sampler started")
(assert (= st (state/active)) "and the module-level surface reaches it")
(assert (not (pressure/under-pressure?)) "a quiet process is not shedding")

(ev/sleep 0.06)
(assert (pos? (st :sampled)) "the fiber is sampling")

(def s (pressure/status))
(assert (s :sampling))
(assert (deep= [:void.db/pool] (s :checks))
        "the built-in check is on the started state — and a composition without a :db/pool is simply never pressured by it")
(assert (= 100 (get-in s [:limits :max-loop-lag])))
(assert (nil? (get-in s [:limits :max-rss-bytes])) "an off limit reports as off, not as 0")
(assert (get-in s [:available :loop-lag]))
(assert (= (os/getpid) (s :pid))
        "the status names its process — in prefork every worker samples its own loop (ADR-0010) and the pid is what tells two of them apart")

(def health (first (filter |(= :pressure/state ($ :name))
                           (plugin/extension boot :void.core/health))))
(assert (= :up (((health :fn)) :status)))

# the CLI command renders whatever the status holds
(def printed @"")
(with-dyns [*out* printed] (pressure/print-status (pressure/status)))
(assert (string/find "under pressure  no" (string printed)))
(assert (string/find "loop lag" (string printed)))

(plugin/shutdown! boot 3)
(assert (nil? (state/active)) "and stopping takes the state with it")
(assert (not (pressure/under-pressure?)))
(assert (not (st :sampling)) "sampler included")

# -- health before the plugin is up --------------------------------------

(assert (= :down (((health :fn)) :status))
        "the health check answers even when there is nothing to report")

(print "plugin-test ok")
