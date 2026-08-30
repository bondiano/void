(import ../test-support/paths)
(import void/core/schema :as schema)
(import void/proto :as proto)
(import void/proto/schema :as pschema)
(import void/proto/descriptor :as desc)

# -- a descriptor is a schema, and nobody had to be told ------------------

(proto/defenum :s/Kind {:KIND_UNSET 0 :KIND_ONE 1})
(proto/defmessage :s/Inner {:v [1 :string]})
(proto/defmessage :s/Msg
  {:id [1 :string] :small [2 :int32] :big [3 :int64] :unsigned [4 :uint64]
   :flag [5 :bool] :amount [6 :double] :kind [7 :s/Kind] :inner [8 :s/Inner]
   :list [9 :repeated :int32] :tags [10 :map :string :string]
   :maybe [11 :optional :string]})

(assert (schema/lookup :s/Msg)
        "registering a message registered a void schema under the same name")
(assert (schema/lookup :s/Inner))
(assert (schema/lookup :s/Kind) "and an enum is a schema too")

(def valid
  {:id "A" :small 7 :big 9 :unsigned 3 :flag true :amount 1.5
   :kind :KIND_ONE :inner {:v "x"} :list [1 2] :tags {"a" "b"} :maybe "note"})
(assert (schema/valid? (schema/lookup :s/Msg) valid)
        "a message the codec would encode is a value the schema accepts")
(assert (schema/valid? (schema/lookup :s/Msg) (proto/decode :s/Msg (proto/encode :s/Msg valid)))
        "and so is one it decoded — including the defaults it filled in")

(assert (not (schema/valid? (schema/lookup :s/Msg) (merge valid {:small 2147483648})))
        "an int32 that is not one fails validation, because the projection carried the bounds")
(assert (not (schema/valid? (schema/lookup :s/Msg) (merge valid {:kind :KIND_NOPE}))))
(assert (not (schema/valid? (schema/lookup :s/Msg) (merge valid {:id 7}))))

(assert (schema/valid? (schema/lookup :s/Msg)
                       (merge valid {:big (int/s64 "9007199254740993")}))
        "a 64-bit field accepts the int/s64 the codec hands back — :int would not")
(assert (not (schema/valid? (schema/lookup :s/Msg) (merge valid {:unsigned -1})))
        "and :proto/uint64 still knows what unsigned means")

(assert (schema/valid? (schema/lookup :s/Msg) (merge valid {:proto/unknown "\x01"}))
        "the bytes a forwarded message carries do not make it invalid")

(def projected (pschema/schema-of :s/Msg))
(assert (= :optional (first (projected :maybe))) "an `optional` field projects as optional")
(assert (= :optional (first (projected :inner))) "and so does a message field, whose absence is a value")
(assert (= :vector (first (projected :list))))
(assert (= :map-of (first (projected :tags))))
(assert (= :string (projected :id)) "while a scalar with implicit presence is just its type")

# -- and a schema is a descriptor, given the one thing it cannot know -----

(def Item {:sku [:string {:proto/field 1}]
           :qty [:int {:proto/field 2 :proto/type :int32}]})
(proto/register! (schema/project :proto Item {:name :s/Item}))

(def Order
  {:id [:string {:proto/field 1}]
   :total [:int {:proto/field 2 :proto/type :int64}]
   :items [:vector [:ref :s/Item] {:proto/field 3}]
   :note [:optional [:string {:proto/field 4}]]
   :labels [:map-of :string [:int {:proto/type :int32}] {:proto/field 5}]})

(def d (schema/project :proto Order {:name :s/Order :proto-name "s.Order"}))
(assert (= :message (d :kind)))
(assert (= "s.Order" (d :proto-name)))
(assert (= :int64 (get-in d [:by-name :total :type])) ":proto/type says which integer")
(assert (= :repeated (get-in d [:by-name :items :label])))
(assert (= :s/Item (get-in d [:by-name :items :ref])))
(assert (= :optional (get-in d [:by-name :note :label])))
(assert (= :int32 (get-in d [:by-name :labels :value :type])))

(def [ok err] (protect (schema/project :proto {:a :string} {:name :s/NoNumbers})))
(assert (not ok))
(assert (string/find "proto/field" err)
        "a field with no number is refused — a wire format's compatibility contract is not guessable")

(assert (not (first (protect (schema/project :proto {:a [[:enum :x :y] {:proto/field 1}]}
                                             {:name :s/Inline}))))
        "and an inline enum is refused, because a protobuf enum is a named type")

# the projection and the codec agree: what the schema describes is what
# the wire carries
(proto/register! d)
(def value {:id "A" :total 5 :items [] :labels {"k" 1}})
(assert (deep= @{"id" "A" "total" "5" "labels" @{"k" 1}}
               (proto/to-json :s/Order (proto/decode :s/Order (proto/encode :s/Order value))))
        "a schema, projected to a descriptor, encodes and reads back the value it described")

# -- two messages that name each other ------------------------------------
#
# They are two declarations, and the first cannot wait for the second:
# a reference to something not registered yet is still a reference.

(proto/defmessage :s/Node {:label [1 :string] :edge [2 :s/Edge]})
(proto/defmessage :s/Edge {:weight [1 :int32] :to [2 :s/Node]})
(assert (schema/valid? (schema/lookup :s/Node)
                       {:label "a" :edge {:weight 1 :to {:label "b"}}})
        "and the schema projected from the first one validates the second")
(assert (= "b" (get-in (proto/decode :s/Node (proto/encode :s/Node
                                                           {:label "a"
                                                            :edge {:weight 1
                                                                   :to {:label "b"}}}))
                       [:edge :to :label])))

# -- the annotations are visible without being validated ------------------

(def ann (pschema/annotations Order))
(assert (= 2 (get-in ann [:fields :total :proto/field])))
(assert (= :int64 (get-in ann [:fields :total :proto/type])))
(assert (schema/valid? Order {:id "x" :total 1 :items [] :labels {}})
        "and :proto/* props take no part in validation, exactly like :db/*")

(print "schema ok")
