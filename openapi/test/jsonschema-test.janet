(import ../test-support/paths)
(import void/core/schema :as schema)
(import void/openapi/jsonschema :as js)

# -- scalar types and props ----------------------------------------------

(assert (deep= @{"type" "integer" "minimum" 18} (js/json-schema [:int {:min 18}])))
(assert (deep= @{"type" "number" "maximum" 10} (js/json-schema [:number {:max 10}])))
(assert (deep= @{"type" "boolean"} (js/json-schema :boolean)))
(assert (deep= @{"type" "string"} (js/json-schema :keyword)))
(assert (deep= @{} (js/json-schema :any)))
(assert (deep= @{"type" "null"} (js/json-schema :nil)))

(def s (js/json-schema [:string {:min 2 :max 8 :format :email :pattern "a+"}]))
(assert (= "string" (s "type")))
(assert (= 2 (s "minLength")))
(assert (= 8 (s "maxLength")))
(assert (= "email" (s "format")))
(assert (= "a+" (s "pattern")))

# -- combinators ---------------------------------------------------------

(assert (deep= @{"enum" @["admin" "user" 3]}
               (js/json-schema [:enum :admin :user 3])))
(assert (deep= @{"const" "on"} (js/json-schema [:literal :on])))
(assert (deep= @{"anyOf" @[@{"type" "integer"} @{"type" "string"}]}
               (js/json-schema [:union :int :string])))
(assert (deep= @{"allOf" @[@{"type" "integer" "minimum" 0}
                           @{"type" "integer" "maximum" 9}]}
               (js/json-schema [:and [:int {:min 0}] [:int {:max 9}]])))
(assert (deep= @{"type" "array" "items" @{"type" "string"} "maxItems" 10}
               (js/json-schema [:vector :string {:max 10}])))
(assert (deep= @{"type" "object" "additionalProperties" @{"type" "integer"}}
               (js/json-schema [:map-of :keyword :int])))

# a standalone optional admits null
(assert (deep= @{"anyOf" @[@{"type" "integer"} @{"type" "null"}]}
               (js/json-schema [:optional :int])))

# preds degrade to annotated permissive schemas, pegs to strings
(assert (= "pred" ((js/json-schema [:pred pos?]) "x-void/type")))
(assert (= "string" ((js/json-schema [:peg "a+"]) "type")))

# -- maps: properties, required, closed ----------------------------------

(def m (js/json-schema {:email [:string {:format :email}]
                        :age [:optional [:int {:min 18}]]}))
(assert (= "object" (m "type")))
(assert (deep= @["email"] (m "required")))
(assert (deep= @{"type" "string" "format" "email"}
               (get-in m ["properties" "email"])))
# the optional wrapper survives as anyOf-with-null on the property
(assert (deep= @{"anyOf" @[@{"type" "integer" "minimum" 18} @{"type" "null"}]}
               (get-in m ["properties" "age"])))

(def closed (js/json-schema [:map {:closed true} {:a :int}]))
(assert (= false (closed "additionalProperties")))

# -- refs and components -------------------------------------------------

(schema/defschema JsTestLeaf {:x :int})
(schema/defschema JsTestBranch
  {:leaf [:ref :JsTestLeaf]
   :next [:optional [:ref :JsTestBranch]]})

(def refs @{})
(def r (js/convert [:ref :JsTestBranch] refs))
(assert (deep= @{"$ref" "#/components/schemas/JsTestBranch"} r))
(assert (deep= @[:JsTestBranch] (keys refs)))

# components chases refs transitively, recursion terminates
(def comps (js/components refs))
(assert (deep= @["JsTestBranch" "JsTestLeaf"] (sorted (keys comps))))
(assert (= "#/components/schemas/JsTestLeaf"
           (get-in comps ["JsTestBranch" "properties" "leaf" "$ref"])))

# an unregistered ref shows up annotated instead of crashing
(def missing (js/components @{:JsTestNowhere true}))
(assert (= "JsTestNowhere" (get-in missing ["JsTestNowhere" "x-void/unregistered"])))

# -- the :openapi projection registers through the plugin ----------------
# (covered end-to-end in plugin-test; here: direct call works)
(assert (deep= @{"type" "integer"} (js/json-schema :int)))

(print "jsonschema-test: ok")
