(import ../void/core/schema :as schema)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat))
  (string err))

(defn errors-of [sch value &opt opts]
  ((schema/check sch value opts) :errors))

# -- base types ----------------------------------------------------------

(assert (schema/valid? :int 42) "bare keyword is a type")
(assert (schema/valid? :int 42.0) "whole floats count as ints (JSON numbers)")
(assert (not (schema/valid? :int 4.5)) "fractional numbers are not ints")
(assert (schema/valid? :string "x") "string type")
(assert (schema/valid? :any {:whatever true}) "any matches anything")
(assert (schema/valid? [:int {:min 18 :max 99}] 18) "numeric bounds inclusive")
(assert (not (schema/valid? [:int {:min 18}] 17)) "min bound enforced")
(assert (schema/valid? "exact" "exact") "bare value matches literally")
(assert (not (schema/valid? "exact" "other")) "literal mismatch fails")
(assert (schema/valid? [:literal :int] :int)
        "[:literal x] matches a keyword literally instead of as a type")

(expect-error "unknown head" "unknown schema head :strng"
              |(schema/normalize [:strng {}]))

# -- the SPEC §3.3 example -----------------------------------------------

(schema/defschema CreateUser
  "A new user."
  {:email [:string {:format :email}]
   :age   [:int {:min 18}]
   :role  [:enum :admin :user]
   :tags  [:vector :keyword {:max 10}]})

(assert (schema/valid? CreateUser
                       {:email "a@b.com" :age 30 :role :admin :tags [:a :b]})
        "valid CreateUser passes")

(def bad ((schema/check CreateUser
                        {:email "not-an-email" :age 17 :role :ghost
                         :tags [:a :b :c 42]})
          :errors))
(assert (= 4 (length bad)) "all errors are collected, not first-fail")
(def by-path (tabseq [e :in bad] (e :path) e))
(assert (= :format ((by-path [:email]) :code)) "email fails the :format check")
(assert (= :min ((by-path [:age]) :code)) "age fails the :min check")
(assert (= :enum ((by-path [:role]) :code)) "role fails the enum")
(assert (= :type ((by-path [:tags 3]) :code)) "error path reaches into the vector")

(assert (string/find "[:tags 3]" (schema/error-str (by-path [:tags 3])))
        "error-str renders the path")

(assert (= :missing (get (first (errors-of CreateUser {})) :code))
        "missing required key is reported")

# -- localizable messages ------------------------------------------------

(with-dyns [:void.schema/messages {:min (fn [e] "слишком мало")}]
  (assert (string/find "слишком мало"
                       (schema/error-str (first (errors-of [:int {:min 5}] 1))))
          "messages table from the dyn overrides the default text")
  (assert (string/find "expected" (schema/error-str (first (errors-of :int "x"))))
          "codes absent from the table fall back to defaults"))

(expect-error "validate throws the batch" "schema validation failed"
              |(schema/validate CreateUser {:age 17}))

# -- refinements: predicates and PEG patterns ----------------------------

(def even-schema [:and :int [:pred even? "must be even"]])
(assert (schema/valid? even-schema 4) "predicate refinement passes")
(def podd (first (errors-of even-schema 3)))
(assert (= :pred (podd :code)) "predicate failure has code :pred")
(assert (= "must be even" (schema/error-str podd))
        "custom predicate message is used verbatim")
(assert (= :pred (get (first (errors-of [:pred |(error "boom")] 1)) :code))
        "a throwing predicate is a validation failure, not a crash")

(def hex [:string {:pattern '(some (range "09" "af"))}])
(assert (schema/valid? hex "c0ffee") "PEG pattern matches")
(assert (= :pattern (get (first (errors-of hex "xyz")) :code)) "PEG pattern fails")
(assert (= :pattern (get (first (errors-of hex "c0ffee-tail")) :code))
        "patterns are anchored: the whole string must match")
(assert (schema/valid? [:peg '(some (range "09"))] "123") "[:peg ...] head works")

(assert (schema/valid? [:string {:format :uuid}]
                       "123e4567-e89b-42d3-a456-426614174000")
        "built-in :uuid format")
(expect-error "unknown format" "unknown string format"
              |(schema/normalize [:string {:format :emial}]))

# -- coercion ------------------------------------------------------------

(def coerced
  (schema/coerce CreateUser
                 {:email "a@b.com" :age "30" :role "admin" :tags [:a]}))
(assert (= 30 (coerced :age)) "string->int coercion for query/form params")
(assert (= :admin (coerced :role)) "string->keyword coercion into enums")
(assert (= "a@b.com" (coerced :email)) "already-valid values pass through")

(assert (= true (schema/coerce :boolean "true")) "string->boolean coercion")
(assert (= false (schema/coerce :boolean "false"))
        "coercing to false works (falsey coerced values are kept)")
(assert (deep= [1 2] (schema/coerce [:vector :int] ["1" "2"]))
        "coercion descends into vectors")
(expect-error "coercion still validates" "schema validation failed"
              |(schema/coerce :int "not-a-number"))
(assert (= 42 (schema/validate :int "42" {:coerce true}))
        "validate takes {:coerce true} directly")

# -- composition: merge / select / optional / union ----------------------

(def Timestamps {:created-at :string :updated-at :string})
(def Post (schema/merge {:id :int :title [:string {:min 1}]} Timestamps))
(assert (schema/valid? Post {:id 1 :title "t" :created-at "x" :updated-at "y"})
        "merge combines entries of both maps")
(assert (= 2 (length (errors-of Post {:id 1 :title "t"})))
        "merged entries are all required")

(def PostRef (schema/select Post [:id :title]))
(assert (schema/valid? PostRef {:id 1 :title "t"}) "select keeps only given keys")
(expect-error "select unknown key" "not in schema"
              |(schema/select Post [:nope]))

(def MaybeInt (schema/optional :int))
(assert (schema/valid? MaybeInt nil) "optional accepts nil")
(assert (schema/valid? MaybeInt 5) "optional accepts the inner type")
(assert (not (schema/valid? MaybeInt "x")) "optional still validates non-nil")
(assert (schema/valid? {:name :string :nick [:optional :string]} {:name "a"})
        "optional map keys may be absent")

(def IdOrName (schema/union :int :string))
(assert (schema/valid? IdOrName 5) "union matches the first branch")
(assert (schema/valid? IdOrName "x") "union matches a later branch")
(def uerr (first (errors-of IdOrName :kw)))
(assert (= :union (uerr :code)) "union failure has code :union")
(assert (= 2 (length (uerr :causes))) "union failure keeps per-branch causes")
(assert (schema/valid? [:or :int :string] "x") ":or is an alias of :union")

# -- recursive schemas ---------------------------------------------------

(schema/defschema Tree
  {:value :int
   :children [:optional [:vector [:ref :Tree]]]})

(assert (schema/valid? Tree {:value 1
                             :children [{:value 2}
                                        {:value 3 :children [{:value 4}]}]})
        "recursive schema via [:ref name]")
(def deep-err (first (errors-of Tree {:value 1 :children [{:value 2 :children [{:value :bad}]}]})))
(assert (= [:children 0 :children 0 :value] (deep-err :path))
        "errors surface the full recursive path")
(assert (schema/valid? {:left :Tree} {:left {:value 1}})
        "an unknown keyword resolves as a registry reference")
(expect-error "unresolved ref" "not registered"
              |(schema/validate [:ref :Nope] 1))

# -- registry ------------------------------------------------------------

(assert (= CreateUser (schema/lookup :CreateUser))
        "defschema registers under the keyword name")
(assert (schema/node? CreateUser) "defschema binds the normalized schema")
(assert (not (nil? (index-of :Tree (schema/registered)))) "registered lists names")
(schema/register! :Wrapped {:inner :int})
(assert (schema/valid? [:ref :Wrapped] {:inner 1}) "register! + ref by name")
(schema/register! :Local :string)
(assert (schema/valid? [:ref :Local] "x") "ref to a scalar registered schema")

# -- closed maps and map-of ----------------------------------------------

(def Closed [:map {:closed true} {:a :int}])
(assert (schema/valid? Closed {:a 1}) "closed map with known keys")
(assert (= :unknown (get (first (errors-of Closed {:a 1 :b 2})) :code))
        "closed map rejects unknown keys")
(assert (schema/valid? {:a :int} {:a 1 :extra true})
        "maps are open by default")

(def Counters [:map-of :keyword :int])
(assert (schema/valid? Counters {:a 1 :b 2}) "map-of checks keys and values")
(assert (= :key (get (first (errors-of Counters {"s" 1})) :code))
        "bad map-of key is reported with code :key")
(def ccoerced (schema/coerce Counters {"a" "1"}))
(assert (= 1 (ccoerced :a)) "map-of coerces both keys and values")

# -- custom types (extension point :void.core/schema-type) ---------------

(schema/register-type! :money
  {:validate (fn [v _] (and (dictionary? v) (number? (v :amount)) (keyword? (v :currency))))
   :coerce (fn [v _] (when (string? v)
                       (when-let [n (scan-number v)]
                         {:amount n :currency :usd})))
   :message "expected money like {:amount 1 :currency :usd}"})

(assert (schema/valid? :money {:amount 9.99 :currency :eur}) "custom type validates")
(assert (= "expected money like {:amount 1 :currency :usd}"
           (schema/error-str (first (errors-of :money 5))))
        "custom type message is used")
(assert (deep= {:amount 5 :currency :usd} (schema/coerce :money "5"))
        "custom type coercion")
(expect-error "type/combinator collision" "collides"
              |(schema/register-type! :union {:validate (fn [v _] true)}))

# -- projections (extension point :void.core/schema-projection) ----------

(assert (not (nil? (index-of :validator (schema/projections))))
        "the validator projection ships with the core")
(def check-user (schema/project :validator CreateUser {:coerce true}))
(assert (= 30 ((check-user {:email "a@b.com" :age "30" :role :user :tags []}) :age))
        "projected validator coerces and returns the value")
(expect-error "projected validator throws" "schema validation failed"
              |(check-user {:age 1}))

(schema/register-projection! :keys
  (fn [sch] (if (= :map (sch :type))
              (map first (sch :children))
              (errorf ":keys projection only handles map schemas, got %q" (sch :type)))))
(assert (deep= @[:age :email :role :tags] (schema/project :keys CreateUser))
        "plugins can add their own projections")
(expect-error "projection rejects what it cannot handle" "only handles map"
              |(schema/project :keys :int))
(expect-error "unknown projection" "unknown schema projection"
              |(schema/project :nope :int))

# -- :db/* annotations: parsed and stored, never validated ---------------

(schema/defschema User
  [:map {:db/table "users"}
   {:id    [:int {:db/pk true :db/type "bigserial"}]
    :email [:string {:format :email :db/index true}]
    :brand [:optional [:int {:db/fk "brands"}]]}])

(assert (schema/valid? User {:id 1 :email "a@b.com"})
        "db annotations do not affect validation")
(def ann (schema/db-annotations User))
(assert (= "users" (get-in ann [:schema :db/table])) "table-level annotation stored")
(assert (= true (get-in ann [:fields :id :db/pk])) "field annotations stored")
(assert (= "brands" (get-in ann [:fields :brand :db/fk]))
        "annotations are found under :optional wrappers")
(assert (nil? (get-in ann [:fields :email :format]))
        "non-db props are not part of db annotations")
(def dto (schema/select User [:email]))
(assert (= "users" (get-in (schema/db-annotations dto) [:schema :db/table]))
        "a DTO selected from an entity keeps its provenance data")

(print "void/core/schema test OK")
