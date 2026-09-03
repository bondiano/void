(import ../test-support/paths)
(import void/bench/results :as results)
(import void/bench/targets :as targets)

# -- comparison: the 5% contract -----------------------------------------

(defn rows [&keys {:rps rps :p50 p50 :p99 p99}]
  {:rows {:b0 {:bench :plaintext
               :throughput {:rps rps}
               :latency {:rate 16000 :p50 p50 :p99 p99}}}})

(def base (rows :rps 20000 :p50 2 :p99 6))

# within threshold — noise, not news
(let [cmp (results/compare-results base (rows :rps 19200 :p50 2.05 :p99 6.2))]
  (assert (empty? (cmp :regressions)) "≤5% degradation passes")
  (assert (empty? (cmp :improvements)) "≤5% gain is noise"))

# throughput drop over 5%
(let [cmp (results/compare-results base (rows :rps 18000 :p50 2 :p99 6))]
  (assert (= 1 (length (cmp :regressions))) "10% rps drop is a regression")
  (def e (first (cmp :regressions)))
  (assert (= :b0 (e :target)))
  (assert (= :rps (e :metric)))
  (assert (< (math/abs (- (e :delta) -0.1)) 1e-9) "delta is -10%"))

# latency growth over 5%
(let [cmp (results/compare-results base (rows :rps 20000 :p50 2.4 :p99 6))]
  (assert (= 1 (length (cmp :regressions))) "20% p50 growth is a regression")
  (assert (= :p50 ((first (cmp :regressions)) :metric))))

# the absolute floor: 5%+ relative but under 0.1ms absolute is noise
(let [tiny (results/compare-results
             (rows :rps 20000 :p50 0.4 :p99 6)
             (rows :rps 20000 :p50 0.44 :p99 6))]
  (assert (empty? (tiny :regressions)) "sub-0.1ms latency moves are noise"))

# improvements are reported, not failed
(let [cmp (results/compare-results base (rows :rps 24000 :p50 1.5 :p99 4))]
  (assert (empty? (cmp :regressions)))
  (assert (= 3 (length (cmp :improvements))) "rps + p50 + p99 improved"))

# a custom threshold widens the corridor
(let [cmp (results/compare-results base (rows :rps 18000 :p50 2 :p99 6) 0.15)]
  (assert (empty? (cmp :regressions)) "10% drop passes a 15% threshold"))

# subset runs: uncovered targets are listed, never failed
(let [cmp (results/compare-results base {:rows {}})]
  (assert (empty? (cmp :regressions)))
  (assert (deep= (cmp :missing) @[:b0]) "missing target listed"))

# modes measured on only one side are skipped
(let [cmp (results/compare-results
             base
             {:rows {:b0 {:bench :plaintext :throughput {:rps 20000}}}})]
  (assert (empty? (cmp :regressions)) "no latency mode -> no latency verdict"))

# -- result files round-trip ---------------------------------------------

(def tmp (string (os/cwd) "/test/tmp-results"))
(def path (string tmp "/nested/r.jdn"))
(results/write-file path base)
(assert (deep= (results/read-file path) base) "jdn round-trip")
(os/rm path)
(os/rmdir (string tmp "/nested"))
(os/rmdir tmp)

# -- environment capture is total ----------------------------------------

(def env (results/environment))
(assert (= janet/version (env :janet)) "janet version recorded")
(assert (number? (env :cpus)) "cpu count recorded")

# -- budgets -------------------------------------------------------------

(def notes
  (results/budget-notes
    {:throughput {:rps 25000}
     :latency {:rate 16000 :p50 0.4 :p99 2.9}
     :runtime {:loop-lag {:p50 0.05 :p99 0.4 :max 3}}}
    (targets/budgets :b0)))
(assert (all |(= :ok (first $)) notes) "all b0 budgets met")

(def missed
  (results/budget-notes
    {:throughput {:rps 15000}
     :latency {:rate 16000 :p50 2.7 :p99 2.0}
     :runtime {:loop-lag {:p50 0.05 :p99 0.4 :max 3}}}
    (targets/budgets :b0)))
(assert (= :miss (first (missed 0))) "throughput floor missed")
(assert (= :miss (first (missed 1))) "p50 budget missed")
(assert (= :ok (first (missed 2))) "p99 budget met")

(def unmeasured
  (results/budget-notes {:throughput {:rps 25000}} (targets/budgets :b0)))
(assert (= :skip (first (unmeasured 1))) "no wrk2 run -> latency unchecked")

# -- the two budgets only the process itself can see ---------------------

(def laggy
  (results/budget-notes
    {:throughput {:rps 25000}
     :latency {:rate 16000 :p50 0.4 :p99 2.9}
     :runtime {:loop-lag {:p50 0.9 :p99 4.2 :max 12}}}
    (targets/budgets :b0)))
(assert (deep= @[:miss] (distinct (map first (filter |(string/find "loop-lag" ($ 1)) laggy))))
        "a loop that runs 4ms late under target load misses the budget")

(def unprobed
  (results/budget-notes
    {:throughput {:rps 25000} :latency {:rate 16000 :p50 0.4 :p99 2.9}}
    (targets/budgets :b0)))
(assert (= :skip (first (last unprobed)))
        "a target with no probe leaves the runtime budget unmeasured, not unmet")

(def gc-bound
  (results/budget-notes
    {:throughput {:rps 2000}
     :latency {:rate 1200 :p50 3 :p99 15}
     :runtime {:loop-lag {:p50 0.2 :p99 0.8 :max 14}}}
    (targets/budgets :b3)))
(assert (= :miss (first (last gc-bound)))
        "B3 carries the GC budget as a loop-lag maximum — 14ms of lag bounds no 10ms pause")
(assert (string/find "GC pause bound" ((last gc-bound) 1))
        "and says so, because the bound is the argument")

# -- loop-lag is compared between commits too ----------------------------

(def lag-base {:rows {:b0 {:runtime {:loop-lag {:p99 0.3}}}}})
(def lag-worse {:rows {:b0 {:runtime {:loop-lag {:p99 0.9}}}}})
(def lag-cmp (results/compare-results lag-base lag-worse))
(assert (= 1 (length (lag-cmp :regressions)))
        "a loop-lag p99 that triples is a regression")
(assert (= :loop-lag-p99 (get-in lag-cmp [:regressions 0 :metric])))

(def lag-noise {:rows {:b0 {:runtime {:loop-lag {:p99 0.34}}}}})
(assert (empty? ((results/compare-results lag-base lag-noise) :regressions))
        "a move under the absolute floor is noise with a percentage sign on it")

# -- the target tables are coherent --------------------------------------

(each tname targets/order
  (def spec (targets/targets tname))
  (assert (in targets/benches (spec :bench))
          (string tname " names a known bench"))
  (assert (number? (spec :port)) (string tname " has a port"))
  (assert (string? (spec :cmd)) (string tname " has a command")))
(each tname targets/default-targets
  (assert (in targets/targets tname) "default target exists"))
(eachk bkey targets/budgets
  (assert (in targets/targets bkey) "budget row matches a target"))
(eachp [bname bench] targets/benches
  (assert (number? (bench :rate)) (string bname " has a wrk2 rate"))
  (each k [:script :body-file]
    (when-let [rel (bench k)]
      (assert (os/stat (string (os/cwd) "/" rel))
              (string bname " " k " exists: " rel)))))

(print "results-test ok")
