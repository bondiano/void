(import ../void/core/extension :as extension)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string name ": message " (string/format "%q" err) " lacks " (string/format "%q" pat)))
  err)

(defn contrib [plugin value] {:plugin plugin :value value})

# -- point? ---------------------------------------------------------------

(def p (extension/extension-point :test/p :schema {:name :keyword}))
(assert (extension/point? p) "a built point")
(assert (extension/point? {:name :x :cardinality :single}) "the shape is what counts, not the constructor")
(assert (not (extension/point? {:name :x})) "no cardinality: an options dictionary, not a point")
(assert (not (extension/point? {:name "x" :cardinality :many})) "a string name is not a point")
(assert (not (extension/point? :x)))
(assert (not (extension/point? nil)))

# -- drain-collected! -----------------------------------------------------

(assert (= {:points {} :contributes {}} (extension/drain-collected!)) "nothing queued: empty, and frozen")
(extension/contribute! :test/p {:name :a})
(extension/contribute! :test/p {:name :b})
(extension/contribute! :test/q {:name :c})
(extension/declare-point! p)
(def drained (extension/drain-collected!))
(assert (= [{:name :a} {:name :b}] (get-in drained [:contributes :test/p])) "contributions in the order made")
(assert (= [{:name :c}] (get-in drained [:contributes :test/q])))
(assert (= p (get-in drained [:points :test/p])))
(assert (struct? drained) "the drain is a frozen snapshot")
(assert (= {:points {} :contributes {}} (extension/drain-collected!)) "and the queue is empty afterwards")
(extension/declare-point! p)
(expect-error "declaring twice before a drain" "declared twice before defplugin" |(extension/declare-point! p))
(extension/drain-collected!)

# -- resolve-point: schema, cardinality, cross-check, fold, in that order --

(def many (extension/extension-point :test/many
            :schema {:name :keyword :phase [:optional :int]}
            :validate (fn [cs] (when (some |(= :bad ($ :name)) cs) (error "no :bad names")))
            :reduce (fn [cs] (sorted-by |(get $ :phase 0) cs))))

(def [resolved errs]
  (extension/resolve-point :test/many many [(contrib :test/b {:name :b :phase 2})
                                            (contrib :test/a {:name :a :phase 1})]))
(assert (empty? errs))
(assert (deep= @[{:name :a :phase 1} {:name :b :phase 2}] resolved) "the fold sees the values, not the {:plugin :value} wrappers")

(def [r0 e0] (extension/resolve-point :test/many many []))
(assert (empty? e0))
(assert (deep= @[] r0) "no contributions: the reducer runs on an empty tuple")

(def [r1 e1] (extension/resolve-point :test/many many [(contrib :test/x {:name "s"})
                                                       (contrib :test/y {:name :ok})]))
(assert (nil? r1) "nothing is resolved when a contribution fails its schema")
(assert (= 1 (length e1)))
(assert (string/find "plugin :test/x: contribution to :test/many:" (e1 0)) "the error names the plugin and the point")

(def [r2 e2] (extension/resolve-point :test/many many [(contrib :test/x {:name :bad})]))
(assert (nil? r2))
(assert (deep= @["extension point :test/many: no :bad names"] e2) "the cross-check's throw, attributed to the point")

(def exploding (extension/extension-point :test/boom :reduce (fn [_] (error "kaboom"))))
(def [r3 e3] (extension/resolve-point :test/boom exploding [(contrib :test/x 1)]))
(assert (nil? r3))
(assert (deep= @["extension point :test/boom: :reduce failed: kaboom"] e3))

# defaults: :many folds to the tuple, :single to the one value

(def plain (extension/extension-point :test/plain))
(assert (deep= [[1 2] @[]] (extension/resolve-point :test/plain plain [(contrib :test/x 1) (contrib :test/y 2)])))

(def single (extension/extension-point :test/single :cardinality :single))
(assert (deep= [nil @[]] (extension/resolve-point :test/single single [])) "an absent :single is nil, not an error")
(assert (deep= [7 @[]] (extension/resolve-point :test/single single [(contrib :test/x 7)])))
(def [r4 e4] (extension/resolve-point :test/single single [(contrib :test/x 1) (contrib :test/y 2)]))
(assert (nil? r4))
(assert (deep= @["extension point :test/single has cardinality :single but received 2 contributions (from: :test/x, :test/y)"] e4))

(def required (extension/extension-point :test/required :cardinality :single-required))
(assert (deep= [7 @[]] (extension/resolve-point :test/required required [(contrib :test/x 7)])))
(assert (deep= [nil @["extension point :test/required requires exactly one contribution, got 0"]]
           (extension/resolve-point :test/required required [])))
(assert (deep= [nil @["extension point :test/required requires exactly one contribution, got 2 (from: :test/x, :test/y)"]]
           (extension/resolve-point :test/required required [(contrib :test/x 1) (contrib :test/y 2)])))

# schema and cardinality are both reported in one pass; the cross-check and the fold never run after either
(def strict (extension/extension-point :test/strict :cardinality :single-required :schema {:n :int}))
(def [r5 e5] (extension/resolve-point :test/strict strict [(contrib :test/x {:n "1"}) (contrib :test/y {:n 2})]))
(assert (nil? r5))
(assert (= 2 (length e5)) "the schema error and the cardinality error both report; the fold never runs")
(assert (string/find "contribution to :test/strict" (e5 0)))
(assert (string/find "requires exactly one contribution, got 2" (e5 1)))

(print "extension-test: all assertions passed")
