(import ../void/core/cli :as cli)

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

# -- command words -------------------------------------------------------

(assert (deep= ["routes"] (cli/command-words :routes)))
(assert (deep= ["openapi" "export"] (cli/command-words :openapi/export)))
(assert (= "void jobs list" (cli/command-line {:name :jobs/list})))

# -- arity ---------------------------------------------------------------

(assert (deep= [0 0] (cli/arity [])) "an empty declaration takes nothing")
(assert (deep= [1 1] (cli/arity ["ID"])))
(assert (deep= [1 2] (cli/arity ["SRC" "[KEY]"])))
(assert (deep= [1 nil] (cli/arity ["NAME" "[FIELD...]"]))
        "a bracketed rest is zero or more after the required name")
(assert (deep= [1 nil] (cli/arity ["FIELD..."]))
        "an unbracketed rest is one or more")

# -- flags ---------------------------------------------------------------

(def listing
  {:name :jobs/list
   :doc "List records"
   :args []
   :flags {"--queue" {:key :queue :type :keyword :doc "only this queue"}
           "--limit" {:key :limit :type :int :doc "how many"}
           "--all" {:key :all :type :bool :doc "every queue"}}})

(let [[opts pos] (cli/parse listing ["--queue" "mail" "--limit" "5" "--all"])]
  (assert (= :mail (opts :queue)) "a :keyword flag arrives as a keyword")
  (assert (= 5 (opts :limit)) "an :int flag arrives as a number")
  (assert (= true (opts :all)) "a :bool flag is its own value")
  (assert (empty? pos)))

(assert (deep= [@{} []] [;(cli/parse listing [])])
        "nothing declared and nothing passed is empty, not nil")

(expect-error "unknown flag" "did you mean"
              |(cli/parse listing ["--limi" "5"]))
(expect-error "a value-less flag" "needs a value"
              |(cli/parse listing ["--limit"]))
(expect-error "a bad number" "whole number"
              |(cli/parse listing ["--limit" "five"]))
(expect-error "a positional where none is declared" "usage: void jobs list"
              |(cli/parse listing ["extra"]))

(def show {:name :jobs/show :args ["ID"]})
(expect-error "too few positionals" "usage: void jobs show ID"
              |(cli/parse show []))
(expect-error "too many positionals" "usage: void jobs show ID"
              |(cli/parse show ["a" "b"]))
(assert (deep= ["a"] (in (cli/parse show ["a"]) 1)))

# a command with no :flags keeps its `--`-words: `void make resource
# --force` reaches a generator that parses its own
(assert (deep= ["--force"] (in (cli/parse {:name :make :args ["[A...]"]} ["--force"]) 1))
        "a command that declares no flags is handed its dashes")

# flags are recognized after positionals too
(def put {:name :storage/put :args ["SRC" "[KEY]"]
          :flags {"--expires" {:key :expires :type :int}}})
(let [[opts pos] (cli/parse put ["f.txt" "--expires" "60"])]
  (assert (= 60 (opts :expires)))
  (assert (deep= ["f.txt"] pos)))

# -- usage and help ------------------------------------------------------

(assert (= "void jobs list [--all] [--limit LIMIT] [--queue QUEUE]"
           (cli/usage listing))
        "the usage line is sorted and built from the declaration")
(assert (= "void jobs show ID" (cli/usage show)))
(assert (= "void routes" (cli/usage {:name :routes}))
        "a command with nothing declared has no surface to describe")

(def lines (cli/help listing))
(assert (string/has-prefix? "usage: void jobs list" (first lines)))
(assert (some |(string/find "List records" $) lines) "the docstring is in the help")
(assert (some |(string/find "only this queue" $) lines) "and so is each flag's")
(assert (some |(string/find "--all " $) lines) "a :bool flag prints without a value word")

(assert (cli/help-wanted? listing ["--help"]))
(assert (cli/help-wanted? listing ["x" "-h"]))
(assert (not (cli/help-wanted? listing ["--limit" "5"])))
(assert (not (cli/help-wanted? {:name :x :flags {"--help" {:key :help :type :bool}}} ["--help"]))
        "a command that declares --help itself keeps it")

(assert (string/has-prefix? "  jobs show ID  " (cli/summary show))
        "the listing prints the invocation, positionals and all")

# -- call ----------------------------------------------------------------

(defn- called
  {:params [{:name :keyword & r} (fn [& :any] :any) (or @[:string] [:string])] :ret :any}
  "Call `command` through `cli/call` with a fixed `[:instance]`
  instances tuple, so each test only has to name what varies."
  [command f args]
  (cli/call command f [:instance] args))

(assert (deep= [:instance "a" "b"]
               (called {:name :raw} (fn [& a] a) ["a" "b"]))
        "declaring neither :args nor :flags is the old convention, untouched")

(assert (deep= [:instance "a"]
               (called show (fn [& a] a) ["a"]))
        ":args alone checks the count and passes the positionals")

(let [got (called listing (fn [i o & pos] [i o pos]) ["--limit" "3"])]
  (assert (= :instance (got 0)))
  (assert (= 3 (get-in got [1 :limit])) ":flags puts the options ahead of the positionals")
  (assert (empty? (got 2))))

(expect-error "call checks the declaration" "usage: void jobs show ID"
              |(called show (fn [& a] a) []))

(print "cli-test: all assertions passed")
