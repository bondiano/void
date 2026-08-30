(import ../test-support/paths)
(import void/cli/prompt :as prompt)

# Every prompt has two front ends and one definition (void/cli/prompt).
# The raw-mode one needs a terminal; this suite drives the other, which
# is the one CI and `void make ... < answers` go through — and which is
# therefore the one that must never block, never ask twice and always
# have an answer.

(defn- answers
  "Run `f` with a scripted stdin: each call to a prompt consumes one
  line, and `nil` afterwards is EOF."
  [lines f]
  (def remaining (array ;lines))
  (with-dyns [prompt/interactive-dyn false
              prompt/input-dyn (fn []
                                 (unless (empty? remaining)
                                   (def line (first remaining))
                                   (array/remove remaining 0)
                                   line))]
    (f)))

# -- ask -----------------------------------------------------------------

(assert (= "users" (answers ["users"] |(prompt/ask "table")))
        "a typed answer comes back trimmed")

(assert (= "posts" (answers [] |(prompt/ask "table" {:default "posts"})))
        "EOF takes the default")

(assert (= "posts" (answers [""] |(prompt/ask "table" {:default "posts"})))
        "an empty line takes the default")

(assert (= "" (answers [] |(prompt/ask "table")))
        "no default and no answer is the empty string, not a hang")

(assert (= "ok" (answers ["  ok  "] |(prompt/ask "q")))
        "surrounding whitespace is not part of an answer")

# A rejected answer cannot be re-asked without a terminal — a pipe has
# nothing else to offer — so it has to be an error rather than a loop.
(assert (not (first (protect (answers ["nope"]
                                      |(prompt/ask "q" {:validate (fn [_] "no")})))))
        "a validated answer that fails is an error without a tty")

(assert (= "yes" (answers ["yes"]
                          |(prompt/ask "q" {:validate (fn [s] (unless (= s "yes") "no"))})))
        "a validated answer that passes comes back")

# -- choose --------------------------------------------------------------

(def options
  [{:label "string" :value :string :doc "short text"}
   {:label "int" :value :int}
   {:label "bool" :value :bool}])

(assert (= :int (answers ["int"] |(prompt/choose "type" options)))
        "an option is picked by its label")

(assert (= :bool (answers ["3"] |(prompt/choose "type" options)))
        "an option is picked by its 1-based number")

(assert (= :string (answers [] |(prompt/choose "type" options)))
        "EOF takes the first option")

(assert (= :bool (answers [] |(prompt/choose "type" options {:default :bool})))
        "EOF takes :default when there is one")

(assert (not (first (protect (answers ["float"] |(prompt/choose "type" options)))))
        "an answer that is not an option is an error naming the options")

(assert (not (first (protect (prompt/choose "type" []))))
        "an empty list of options is a bug in the caller, not a prompt")

(assert (= "b" (answers ["b"] |(prompt/choose "letter" ["a" "b"])))
        "plain strings work as options, and are their own values")

# -- confirm -------------------------------------------------------------

(assert (= true (answers ["y"] |(prompt/confirm "sure?"))) "y is true")
(assert (= false (answers ["n"] |(prompt/confirm "sure?"))) "n is false")
(assert (= true (answers ["YES"] |(prompt/confirm "sure?"))) "case does not matter")
(assert (= true (answers [] |(prompt/confirm "sure?"))) "EOF takes the default")
(assert (= false (answers [] |(prompt/confirm "sure?" false)))
        "and the default is the caller's")
(assert (not (first (protect (answers ["maybe"] |(prompt/confirm "sure?")))))
        "anything that is not yes or no is refused")

# -- interactive? --------------------------------------------------------

(assert (not (with-dyns [prompt/interactive-dyn false] (prompt/interactive?)))
        "the dyn overrides tty detection")
(assert (with-dyns [prompt/interactive-dyn true] (prompt/interactive?))
        "in both directions")

(print "prompt-test ok")
