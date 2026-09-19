(import ../void/core/order :as order)

(defn expect-error
  {:params [:string :string (fn [] :any)] :ret :any}
  "Run `thunk`, asserting it throws and that its error mentions `pat`;
  answers the caught error for further assertions."
  [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string name ": message " (string/format "%q" err) " lacks " (string/format "%q" pat)))
  err)

(defn names
  {:params [[{:name :keyword & r}]] :ret [:keyword]}
  "The names of a sorted list, anchors included, for comparing orders."
  [xs]
  (tuple ;(map |($ :name) xs)))

(def anchors [:a1 :a2 :a3])
(def opts {:anchors anchors :what "middleware"})

# -- edges / edges-str ---------------------------------------------------

(assert (= [] (order/edges nil)) "nil is no edge")
(assert (= [:a] (order/edges :a)) "a keyword is one edge")
(assert (= [:a :b] (order/edges @[:a :b])) "a list is itself, as a tuple")
(expect-error "an edge is a name" "an edge is a keyword or a list of keywords"
  |(order/edges "a")) # janet-zed: ignore types

(assert (= "after :a, :b; before :c"
           (order/edges-str {:name :x :after [:a :b] :before :c})))
(assert (= "before :c" (order/edges-str {:name :x :before :c})))
(assert (= "" (order/edges-str {:name :x})) "no edges, no text")

# -- 1. anchors alone come back in their order, marked -------------------

(def bare (order/sort [] opts))
(assert (= [:a1 :a2 :a3] (names bare)))
(assert (all |($ :anchor) bare) "every anchor is marked as one")

# -- 2. :after A is right after A ----------------------------------------

(def nodes [{:name :late :after :a2}
            {:name :early :after :a1}
            {:name :first :before :a1}])
(assert (= [:first :a1 :early :a2 :late :a3] (names (order/sort nodes opts))))

# -- 3. the input order does not matter ----------------------------------

(assert (= (names (order/sort nodes opts))
           (names (order/sort (reverse nodes) opts))))

# -- 4. :before A is right before A, after the anchor before it ----------

(assert (= [:a1 :x :a2 :a3]
           (names (order/sort [{:name :x :before :a2}] opts))))

# -- 5. inside a zone: by name, unless an edge says otherwise ------------

(assert (= [:a1 :b :c :a2 :a3]
           (names (order/sort [{:name :c :after :a1 :before :a2}
                               {:name :b :after :a1 :before :a2}] opts)))
        "no path between them: by name")
(assert (= [:a1 :c :b :a2 :a3]
           (names (order/sort [{:name :c :after :a1 :before :a2}
                               {:name :b :after [:a1 :c] :before :a2}] opts)))
        "an edge beats the name")

# -- 6. the nodes themselves come back, not copies -----------------------

(def node {:name :x :after :a1 :plugin :p :extra 1})
(assert (= node (in (order/sort [node] opts) 1)) "the contribution itself, extra keys and all")

# -- 7. duplicates, and a node named like an anchor ----------------------

(expect-error "duplicate" "duplicate middleware :x (from :q) — already given (from :p)"
  |(order/sort [{:name :x :after :a1 :plugin :p}
                {:name :x :after :a1 :plugin :q}] opts))
(expect-error "anchor clash" "middleware :a2 (from :p) takes the name of an anchor"
  |(order/sort [{:name :a2 :after :a1 :plugin :p}] opts))

# -- 8. unplaced, with the hint for a leftover :phase ---------------------

(def unplaced-err
  (expect-error "unplaced"
    "middleware :x (from :p) is not placed: give it :after or :before one of the anchors :a1 :a2 :a3"
    |(order/sort [{:name :x :plugin :p}] opts)))
(assert (not (string/find "ADR-0051" unplaced-err)) "no hint without a :phase")
(expect-error "phase hint" "(:phase was removed in ADR-0051)"
  |(order/sort [{:name :x :phase 4000}] opts))
(expect-error "a neighbour of nothing is placed nowhere" "middleware :y is not placed"
  |(order/sort [{:name :x :after :a1} {:name :y :before :z} {:name :z}] opts))

# -- 9. unknown, with did-you-mean ---------------------------------------

(expect-error "unknown" "middleware :x: :after :sesion is unknown — did you mean :session?"
  |(order/sort [{:name :session :after :a1} {:name :x :after :sesion}] opts))
(expect-error "unknown anchor" ":before :a4 is unknown"
  |(order/sort [{:name :x :after :a1 :before :a4}] opts))

# -- 10. reach: own plugin, the owner, direct :requires ------------------

(def plugged
  [{:name :owned :after :a1 :plugin :host}
   {:name :dep :after :a1 :plugin :dep}
   {:name :other :after :a1 :plugin :other}])
(def reach-opts (merge opts {:owner :host :requires {:me {:dep true} :you [:dep]}}))
(defn with-node
  {:params [{:keyword :any}] :ret :any}
  "Sort the plugged nodes plus one more, under the reach rules."
  [n]
  (order/sort [;plugged n] reach-opts))
(assert (with-node {:name :x :after :owned :plugin :me}) "the owner's node is in reach")
(assert (with-node {:name :x :after :dep :plugin :me}) "a required plugin's node is in reach")
(assert (with-node {:name :x :after :dep :plugin :you}) ":requires may be a list")
(assert (with-node {:name :x :after :a1 :plugin :other :before :other}) "its own plugin's node")
(expect-error "not required" "middleware :x (from :me): :after :other belongs to :other, which :me does not require"
  |(with-node {:name :x :after :other :plugin :me}))
(assert (order/sort [;plugged {:name :x :after :other :plugin :me}] opts)
        "no :requires, no reach check")

# -- 11. every error in one throw ----------------------------------------

(def batched
  (expect-error "batched" "middleware order is broken:"
    |(order/sort [{:name :x :after :a1} {:name :x :after :a1}
                  {:name :y} {:name :z :after :nope}] opts)))
(each part ["duplicate middleware :x" "middleware :y is not placed" ":after :nope is unknown"]
  (assert (string/find part batched) (string "the batch lacks " part)))

# -- 12. a cycle prints its path -----------------------------------------

(expect-error "cycle" "middleware order is a cycle: :x -> :y -> :x"
  |(order/sort [{:name :x :after :a1 :before :y} {:name :y :before :x}] opts))
(expect-error "a cycle through anchors" "cycle: :a1 -> :a2 -> :x -> :a1"
  |(order/sort [{:name :x :after :a2 :before :a1}] opts))

# -- 13. :unplaced :last: after everything, by name ----------------------

(assert (= [:a1 :x :a2 :a3 :b :c]
           (names (order/sort [{:name :c} {:name :b} {:name :x :after :a1}]
                              (merge opts {:unplaced :last})))))

# -- 14. no anchors: a first-answer-wins list ----------------------------

(def plain {:what "renderer" :unplaced :last})
(assert (= [:grpc :rest :html :json]
           (names (order/sort [{:name :json} {:name :rest}
                               {:name :html} {:name :grpc :before :rest}] plain)))
        "placed nodes by the graph, then the rest by name")
(assert (= [:b :a :c]
           (names (order/sort [{:name :c} {:name :a :after :b} {:name :b}] plain)))
        "the target of an edge is placed too")
(assert (= [:a :b] (names (order/sort [{:name :b} {:name :a}] plain))) "no edges: by name")
(expect-error "no anchors, :error" "renderer :a is not placed: give it :after or :before another renderer"
  |(order/sort [{:name :a} {:name :b :before :c} {:name :c}] {:what "renderer"}))

# -- 15. first-wins: the same sort, and :priority is gone ---------------

(assert (= [:z :y :a :b]
           (names (order/first-wins [{:name :b} {:name :z :before :y}
                                     {:name :y} {:name :a}] "source")))
        "first-wins is the anchorless sort with the unplaced last, by name")
(def stale-err
  (expect-error "leftover :priority" "removed in ADR-0051 — place it with :after/:before"
    |(order/first-wins [{:name :ok} {:name :old :priority 10}] "source")))
(assert (string/find "source :old has :priority" (string stale-err)) "the stale node is named")
(assert (nil? (order/reject-priority [{:name :fine :after :x}] "source")))

(print "order-test: all assertions passed")
