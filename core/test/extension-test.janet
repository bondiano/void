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

# -- :key — one contribution per key, resolved in key order ----------------

(def keyed (extension/extension-point :test/thing :schema {:name :keyword :n [:optional :int]} :key :name))
(assert (= "test thing" (keyed :what)) "the duplicate noun derives from the point name")
(assert (= "dash tile" ((extension/extension-point :void.dash/tile :key :name) :what)) "`void.` is dropped, the slash a space")
(assert (= "widget" ((extension/extension-point :widget :key :name) :what)) "no namespace: the bare name")
(assert (= "span exporter" ((extension/extension-point :void.obs/exporter :key :name :what "span exporter") :what)) ":what overrides it")

(def [rk ek] (extension/resolve-point :test/thing keyed [(contrib :test/b {:name :b :n 2})
                                                        (contrib :test/a {:name :a :n 1})]))
(assert (empty? ek))
(assert (deep= @[{:name :a :n 1} {:name :b :n 2}] rk) "the default fold sorts by the key")

(def [rd ed] (extension/resolve-point :test/thing keyed [(contrib :test/a {:name :a :n 1})
                                                        (contrib :test/b {:name :a :n 2})]))
(assert (nil? rd))
(assert (deep= @["extension point :test/thing: duplicate test thing :a"] ed) "a repeated key names the noun and the value")

(def unschematic (extension/extension-point :test/loose :key :name))
(def [rn en] (extension/resolve-point :test/loose unschematic [(contrib :test/a {:n 1})]))
(assert (nil? rn))
(assert (deep= @["extension point :test/loose: contribution without :name: {:n 1}"] en)
        "without a schema to say so, the key check itself refuses a contribution that lacks the key")

# an explicit :validate runs after the uniqueness check, an explicit :reduce replaces the key order
(def keyed-own
  (extension/extension-point :test/own :schema {:name :keyword :n :int} :key :name
    :validate (fn [cs] (each c cs (when (neg? (c :n)) (errorf "thing %q is negative" (c :name)))))
    :reduce (fn [cs] (sorted-by |($ :n) cs))))
(def [ro eo] (extension/resolve-point :test/own keyed-own [(contrib :test/a {:name :b :n 2})
                                                          (contrib :test/b {:name :a :n 1})]))
(assert (empty? eo))
(assert (deep= @[{:name :a :n 1} {:name :b :n 2}] ro) "the point's own :reduce decides the order")
(assert (deep= @["extension point :test/own: thing :a is negative"]
           (last (extension/resolve-point :test/own keyed-own [(contrib :test/a {:name :a :n -1})])))
        "the point's own :validate still runs")
(assert (deep= @["extension point :test/own: duplicate test own :a"]
           (last (extension/resolve-point :test/own keyed-own [(contrib :test/a {:name :a :n 1})
                                                              (contrib :test/b {:name :a :n -1})])))
        "uniqueness is checked before the point's own :validate")

# -- :index — a table keyed by :key --------------------------------------

(def indexed (extension/extension-point :test/codec :schema {:name :keyword :fn :function} :key :name :index true))
(def a-fn (fn [] :a))
(def b-fn (fn [] :b))
(def [ri ei] (extension/resolve-point :test/codec indexed [(contrib :test/a {:name :a :fn a-fn})
                                                          (contrib :test/b {:name :b :fn b-fn})]))
(assert (empty? ei))
(assert (table? ri) "an index is a table")
(assert (deep= @{:a {:name :a :fn a-fn} :b {:name :b :fn b-fn}} ri) "keyed by the key, the contribution as the value")
(assert (deep= @{} (first (extension/resolve-point :test/codec indexed []))) "no contributions: an empty index")
(assert (deep= @["extension point :test/codec: duplicate test codec :a"]
           (last (extension/resolve-point :test/codec indexed [(contrib :test/a {:name :a :fn a-fn})
                                                              (contrib :test/b {:name :a :fn b-fn})])))
        "an index refuses a repeated key the same way")

(def projected (extension/extension-point :test/serializer :schema {:key :keyword :fn :function} :key :key :index |($ :fn)))
(assert (deep= @{:err a-fn :req b-fn}
           (first (extension/resolve-point :test/serializer projected [(contrib :test/a {:key :err :fn a-fn})
                                                                      (contrib :test/b {:key :req :fn b-fn})])))
        "a function :index projects each contribution into the value")

# -- the option checks ---------------------------------------------------

(expect-error ":key not a keyword" ":key must be the keyword of the contribution field"
  |(extension/extension-point :test/bad :key "name"))
(expect-error ":key on a :single point" ":key needs :cardinality :many"
  |(extension/extension-point :test/bad :cardinality :single :key :name))
(expect-error ":key outside the schema" ":key :id is not a field of :schema (fields: :fn :name)"
  |(extension/extension-point :test/bad :schema {:name :keyword :fn :function} :key :id))
(assert (extension/point? (extension/extension-point :test/ok :schema [:or :dictionary :function] :key :name))
        "a non-dictionary schema cannot vouch for the field and is not asked to")
(expect-error ":what without :key" ":what names the key in the duplicate message and needs :key"
  |(extension/extension-point :test/bad :what "thing"))
(expect-error ":what not a string" ":what must be a string"
  |(extension/extension-point :test/bad :key :name :what :thing))
(expect-error ":index without :key" ":index folds contributions into a table keyed by :key and needs :key"
  |(extension/extension-point :test/bad :index true))
(expect-error ":index of the wrong shape" ":index must be true or (fn [contribution] value)"
  |(extension/extension-point :test/bad :key :name :index :name))
(expect-error ":index next to :reduce" ":index and :reduce are two answers to one question"
  |(extension/extension-point :test/bad :key :name :index true :reduce identity))
(assert (nil? ((extension/extension-point :test/plain2) :what)) "no :key: no noun in the contract")

(print "extension-test: all assertions passed")
