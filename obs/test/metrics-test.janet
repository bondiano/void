# The metric registry: the three instrument kinds, redeclaration as a
# reload rather than a reset, the cardinality cap that is the feature,
# pull-based collectors and the quantile read off a histogram.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/obs/metrics :as metrics)

(log/set-level! "void.obs" :error)

(defn- fresh []
  (metrics/clear-registry!)
  (metrics/set-max-label-sets! metrics/default-max-label-sets))

# -- declaration ---------------------------------------------------------

(fresh)

(def hits (metrics/counter :test/hits-total {:doc "hits" :labels [:route]}))
(assert (= :counter (hits :kind)))
(assert (= [:route] (hits :labels)) "labels are a tuple in declaration order")
(assert (= hits (metrics/find-metric :test/hits-total)))

(metrics/inc! hits :home)
(metrics/inc! hits :home 4)
(assert (= 5 (metrics/value hits :home))
        "a bare label value is the one-label sugar")

(def again (metrics/counter :test/hits-total {:labels [:route]}))
(assert (= hits again) "redeclaring returns the same handle — a REPL reload is not a reset")
(assert (= 5 (metrics/value again :home)) "with its values intact")

(assert (not (first (protect (metrics/counter :test/hits-total {:labels [:method]}))))
        "the same name with different labels is a conflict, not a silent replacement")
(assert (not (first (protect (metrics/gauge :test/hits-total))))
        "and neither is the same name with a different kind")
(assert (not (first (protect (metrics/counter "not-a-keyword")))))

# -- gauges --------------------------------------------------------------

(def in-flight (metrics/gauge :test/in-flight))
(metrics/add! in-flight nil 1)
(metrics/add! in-flight nil 1)
(metrics/add! in-flight nil -1)
(assert (= 1 (metrics/value in-flight)) "a gauge goes both ways")
(metrics/set! in-flight nil 42)
(assert (= 42 (metrics/value in-flight)))

# -- histograms ----------------------------------------------------------

(def dur (metrics/histogram :test/duration-seconds
           {:labels [:route] :buckets [0.01 0.1 1]}))
(each v [0.005 0.05 0.5 5]
  (metrics/observe! dur [:home] v))
(def series (metrics/value dur [:home]))
(assert (= 4 (series :count)))
(assert (= 5.555 (+ 0 (series :sum))))
(assert (= [1 1 1] (tuple ;(series :buckets)))
        "the 5 s observation is over the last bound and lands in no bucket — +Inf is :count minus the rest")

(assert (nil? (metrics/quantile dur 0.5 [:nothing])) "no observations, no quantile")
(def p50 (metrics/quantile dur 0.5 [:home]))
(assert (and (> p50 0.01) (<= p50 0.1))
        "the median of the four falls in the second bucket")
(assert (= 1 (metrics/quantile dur 0.99 [:home]))
        "and everything past the last bound reads as that bound, never as a number the buckets cannot support")
(assert (not (first (protect (metrics/quantile hits 0.5))))
        "a counter has no quantile")

# -- the cardinality cap -------------------------------------------------

(fresh)
(metrics/set-max-label-sets! 3)
(def paths (metrics/counter :test/paths-total {:labels [:path]}))
(each p ["/a" "/b" "/c" "/d" "/e"]
  (metrics/inc! paths p))
(assert (= 3 (length (paths :values))) "the cap holds")
(assert (= 2 (paths :dropped)) "and what it refused is counted, not silently lost")
(metrics/inc! paths "/a")
(assert (= 2 (metrics/value paths "/a"))
        "a label set already known keeps counting after the cap is reached")

(def reported ((metrics/dropped :collect)))
(assert (= 1 (length reported)) "the registry reports its own drops, by metric")
(assert (= 2 (in (first reported) 1))
        "and the number is what the cap refused — 'the dashboard is missing rows' becomes 'this metric is over-labelled'")

# -- collectors ----------------------------------------------------------

(fresh)
(var backing 7)
(def pulled (metrics/gauge :test/pulled {:doc "pull"}))
(metrics/set-collector! pulled (fn [] backing))
(def snap (metrics/snapshot))
(def entry (first (filter |(= :test/pulled ($ :name)) snap)))
(assert (= 7 (get-in entry [:series 0 :value])) "a collector is called at snapshot time")
(set backing 9)
(assert (= 9 (get-in (first (filter |(= :test/pulled ($ :name)) (metrics/snapshot)))
                     [:series 0 :value]))
        "and again on the next one — nothing is cached between scrapes")

(metrics/set-collector! pulled nil)
(assert (empty? (get-in (first (filter |(= :test/pulled ($ :name)) (metrics/snapshot)))
                        [:series]))
        "a detached collector reports no series — what a stopped component honestly looks like")

(metrics/set-collector! pulled (fn [] [[["a"] 1] [["b"] 2]]))
(assert (= 2 (length (get-in (first (filter |(= :test/pulled ($ :name)) (metrics/snapshot)))
                             [:series])))
        "a collector may return several labelled series")

(metrics/set-collector! pulled (fn [] (error "no")))
(assert (first (protect (metrics/snapshot)))
        "a collector that throws is logged, never a failed scrape")

# -- snapshot and reset --------------------------------------------------

(fresh)
(def c (metrics/counter :test/c {:doc "c"}))
(metrics/inc! c)
(def s (first (metrics/snapshot)))
(assert (= :test/c (s :name)))
(assert (= 1 (get-in s [:series 0 :value])))
(metrics/reset! :test/c)
(assert (nil? (metrics/value c)) "reset drops the values")
(assert (metrics/find-metric :test/c) "and keeps the declaration")

(fresh)
(print "metrics-test ok")
