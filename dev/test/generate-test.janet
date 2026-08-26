(import ../test-support/paths)
(import void/core/schema :as schema)
(import void/dev/generate :as gen)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat)))

# -- generated values validate against their schema ----------------------

(def cases
  [:int
   :number
   :string
   :boolean
   :keyword
   :symbol
   :buffer
   [:int {:min 18 :max 21}]
   [:number {:min -1 :max 1}]
   [:string {:min 3 :max 5}]
   [:string {:format :email}]
   [:string {:format :uuid}]
   [:string {:format :date}]
   [:enum :admin :user :guest]
   [:union :int :string]
   [:optional :int]
   [:vector :keyword {:min 2 :max 4}]
   [:map-of :keyword :int]
   [:literal 42]
   [:and [:int {:min 0 :max 10}] [:int {:min 5 :max 20}]]
   {:email [:string {:format :email}]
    :age [:int {:min 18}]
    :role [:enum :admin :user]
    :tags [:vector :keyword {:max 3}]
    :bio [:optional :string]}])

(loop [sch :in cases
       seed :range [1 6]]
  (def v (gen/generate sch {:seed seed}))
  (assert (schema/valid? sch v)
          (string/format "generated %q does not satisfy %q (seed %d)"
                         v sch seed)))

# bounds are honored, not just validated
(loop [seed :range [1 20]]
  (def v (gen/generate [:int {:min 18 :max 21}] {:seed seed}))
  (assert (and (>= v 18) (<= v 21))))

# -- determinism with :seed ----------------------------------------------

(def sch {:a :int :b [:string {:min 4}]})
(assert (deep= (gen/generate sch {:seed 7}) (gen/generate sch {:seed 7}))
        "same seed, same value")

# -- refs and recursion cap ----------------------------------------------

(schema/register! :gen/Tree
  {:value :int
   :kids [:vector [:ref :gen/Tree] {:min 0 :max 1}]})
(def tree (gen/generate [:ref :gen/Tree] {:seed 3 :max-depth 6}))
(assert (schema/valid? :gen/Tree tree) "recursive schema generates a valid tree")

(expect-error "unregistered ref" "not registered"
  |(gen/generate [:ref :gen/Nope]))

# -- ungeneratable schemas say so ----------------------------------------

(expect-error "bare pred" ":pred" |(gen/generate [:pred pos?]))
(expect-error "peg schema" ":peg" |(gen/generate [:peg "abc"]))
(expect-error "pattern prop" ":pattern" |(gen/generate [:string {:pattern "x+"}]))
(expect-error "unknown format" "format" |(gen/generate [:string {:format :phone}]))

# an optional ungeneratable field degrades to nil instead of failing
(def with-pred {:id :int :odd [:optional [:pred odd?]]})
(def wp (gen/generate with-pred {:seed 1}))
(assert (schema/valid? with-pred wp))
(assert (nil? (wp :odd)) "optional :pred field degrades to nil")

# -- the projection is registered on load --------------------------------

(assert (not (nil? (index-of :generator (schema/projections))))
        ":generator projection is registered")
(assert (schema/valid? :int (schema/project :generator :int {:seed 1})))

(print "generate-test: all assertions passed")
