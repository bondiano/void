(import ../void/core/util :as util)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string name ": message " (string/format "%q" err) " lacks " (string/format "%q" pat)))
  err)

# -- callable? -----------------------------------------------------------

(assert (util/callable? (fn [] 1)) "a Janet function")
(assert (util/callable? |(+ $ 1)) "a short-fn")
(assert (util/callable? string/join) "a C function")
(assert (not (util/callable? :keyword)) "a keyword is data, not a call")
(assert (not (util/callable? @{:call (fn [] 1)})) "a table with a :call key is not a handler")
(assert (not (util/callable? nil)))
(assert (not (util/callable? (fiber/new (fn [] 1)))) "a fiber is resumed, not called")

# -- names-str -----------------------------------------------------------

(assert (= ":a :b :c" (util/names-str [:c :a :b])) "sorted, so the list is scannable")
(assert (= ":a :b :c" (util/names-str [:b :c :a])) "and independent of collection order")
(assert (= "" (util/names-str [])) "an empty list is the empty string, not an error")
(assert (= "\"x\" \"y\"" (util/names-str ["y" "x"])) "strings keep their quotes (%q)")
(assert (= "foo" (util/names-str ['foo])) "symbols print bare")

# -- unique-by -----------------------------------------------------------

(def by-name (util/unique-by "widget name" |($ :name)))
(assert (nil? (by-name [{:name :a} {:name :b}])) "distinct keys pass silently")
(assert (nil? (by-name [])))
(def dup-err (expect-error "duplicate" "duplicate widget name :a"
               |(by-name [{:name :a} {:name :b} {:name :a}])))
(assert (string/find "widget name" dup-err) "the message names what was duplicated")
(assert (nil? ((util/unique-by "path" |($ :path)) [{:path "/a"} {:path "/b"}])))
(expect-error "the key can be anything hashable" "duplicate path \"/a\""
  |((util/unique-by "path" |($ :path)) [{:path "/a"} {:path "/a"}]))

# -- levenshtein ---------------------------------------------------------

(assert (= 0 (util/levenshtein "abc" "abc")))
(assert (= 3 (util/levenshtein "" "abc")) "insertions")
(assert (= 3 (util/levenshtein "abc" "")) "deletions")
(assert (= 1 (util/levenshtein "kitten" "kitsen")) "one substitution")
(assert (= 3 (util/levenshtein "kitten" "sitting")) "the textbook pair")
(assert (= (util/levenshtein "flaw" "lawn") (util/levenshtein "lawn" "flaw")) "symmetric")

# -- closest / suggest ---------------------------------------------------

(def points [:void.core/health :void.http/route :void.http/middleware])
(assert (= :void.core/health (util/closest :void.core/helth points)) "one edit away")
(assert (= :void.http/route (util/closest "void.http/rotue" points)) "strings work as well as keywords")
(assert (nil? (util/closest :completely/different points)) "nothing within three edits: no guess")
(assert (nil? (util/closest :ab [:xy :zz])) "a short name is not corrected into an unrelated short name")
(assert (nil? (util/closest :x [])) "no candidates, no answer")
(assert (= :aa (util/closest :ab [:ac :aa])) "a tie goes to the first in sorted order, not collection order")

(assert (= " — did you mean :void.core/health?" (util/suggest :void.core/helth points))
        "the tail is ready to append to a message")
(assert (= "" (util/suggest :completely/different points)) "and empty when there is no guess")
(assert (= (string "unknown point :void.core/helth" (util/suggest :void.core/helth points))
           "unknown point :void.core/helth — did you mean :void.core/health?"))

(print "util-test: all assertions passed")
