(import ../test-support/paths)
(import void/authz/policy :as policy)

# -- the shape -----------------------------------------------------------

(each bad [{} {:name "x" :fn (fn [_])} {:name :x} {:name :x :fn 42} "nope"]
  (def [ok] (protect (policy/normalize bad)))
  (assert (not ok) (string/format "%q is not a policy" bad)))

(policy/register! {:name :always :doc "yes" :fn (fn [_] true)})
(assert (deep= [:always] (tuple ;(policy/policies))))
(assert (= "yes" ((policy/lookup :always) :doc)))

# registering the same name again replaces it — that is what makes a REPL
# redefinition take effect without a restart
(policy/register! {:name :always :fn (fn [_] false)})
(assert (not (((policy/lookup :always) :fn) {})))
(assert (= 1 (length (policy/policies))))

(def [ok err] (protect (policy/policy! :missing)))
(assert (not ok) "an unknown policy is an error, not a quiet deny")
(assert (string/find "always" (string err)) "and the message lists what there is")

(policy/deregister! :always)
(assert (empty? (policy/policies)))

# -- defpolicy is sugar over the data form -------------------------------

(policy/defpolicy :orders/read
  "An order is visible to its owner."
  [ctx]
  (= (get ctx :owner) (get ctx :who)))

(def p (policy/lookup :orders/read))
(assert p "defpolicy registered it")
(assert (= "An order is visible to its owner." (p :doc)) "with its docstring")
(assert ((p :fn) {:owner 1 :who 1}) "and the function is an ordinary one, callable in a test with a table")
(assert (not ((p :fn) {:owner 1 :who 2})))

(policy/defpolicy :no-doc [ctx] true)
(assert (nil? ((policy/lookup :no-doc) :doc)) "the docstring is optional")

(def [ok2] (protect (macex '(policy/defpolicy :two-params [a b] true))))
(assert (not ok2) "a policy takes exactly one argument: the context")

# -- a policy may answer with its reason ---------------------------------

(policy/defpolicy :with-reason [ctx] "not today")
(assert (= "not today" (((policy/lookup :with-reason) :fn) {}))
        "a string answer is the reason — ./decide turns it into the decision's :reason")

(assert (deep= [:no-doc :orders/read :with-reason] (tuple ;(policy/policies))))
(each r (policy/describe)
  (assert (keyword? (r :name)))
  (assert (or (nil? (r :doc)) (string? (r :doc)))))

(print "policy-test ok")
