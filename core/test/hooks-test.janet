(import ../void/core/hooks :as hooks)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat))
  (string err))

# -- hook registry: validation -------------------------------------------

(def reg (hooks/registry))

(expect-error "non-keyword hook" "keyword"
  |(hooks/add! reg "before-start" (fn [_] nil)))
(expect-error "non-function handler" "function"
  |(hooks/add! reg :before-start 42))
(expect-error "unknown option" "unknown option"
  |(hooks/add! reg :before-start (fn [_] nil) :prio 1))
(expect-error "bad phase" ":phase"
  |(hooks/add! reg :before-start (fn [_] nil) :phase 1.5))
(expect-error "odd options" "key-value"
  |(hooks/add! reg :before-start (fn [_] nil) :phase))

# -- ordering: phase, then name; args reach handlers ---------------------

(def log @[])
(hooks/add! reg :boot (fn [x] (array/push log [:b x])) :phase 2000 :name :b)
(hooks/add! reg :boot (fn [x] (array/push log [:a x])) :phase 2000 :name :a)
(hooks/add! reg :boot (fn [x] (array/push log [:late x])) :phase 3000 :name :late)
(hooks/add! reg :boot (fn [x] (array/push log [:early x])) :phase 10 :name :early)

(assert (= 4 (hooks/run! reg :boot :ctx)) "run! returns the handler count")
(assert (= (freeze log)
           [[:early :ctx] [:a :ctx] [:b :ctx] [:late :ctx]])
        "handlers run by :phase, ties broken by :name, args passed through")

(assert (zero? (hooks/run! reg :never-registered)) "unknown hook is a no-op")

# re-adding the same name replaces the handler
(hooks/add! reg :boot (fn [x] (array/push log [:early2 x])) :phase 10 :name :early)
(array/clear log)
(hooks/run! reg :boot 1)
(assert (= [:early2 1] (first log)) "same :name replaces the handler")

# remove!
(assert (hooks/remove! reg :boot :late))
(assert (nil? (hooks/remove! reg :boot :late)) "second remove returns nil")
(assert (= 3 (length (hooks/handlers reg :boot))))
(assert (= 3 (length (hooks/handlers reg))) "handlers without hook lists everything")

# -- error propagation ---------------------------------------------------

(def ereg (hooks/registry))
(def eorder @[])
(hooks/add! ereg :h (fn [_] (array/push eorder :first)) :phase 1 :name :ok)
(hooks/add! ereg :h (fn [_] (error "boom")) :phase 2 :name :bad :plugin :test/p)
(hooks/add! ereg :h (fn [_] (array/push eorder :third)) :phase 3 :name :after)

(def msg (expect-error "run! fail-fast" "boom" |(hooks/run! ereg :h nil)))
(assert (string/find ":bad" msg) "error names the handler")
(assert (string/find "test/p" msg) "error names the plugin")
(assert (= [:first] (freeze eorder)) "run! stops at the failing handler")

(array/clear eorder)
(def errs (hooks/run-protected! ereg :h nil))
(assert (= 1 (length errs)))
(assert (string/find "boom" (errs 0)))
(assert (= [:first :third] (freeze eorder))
        "run-protected! keeps going past a failing handler")

# -- declarations --------------------------------------------------------

# an undeclared registry runs anything silently
(assert (hooks/declared? (hooks/registry) :anything))
(assert (= "void.http" (hooks/namespace-of :void.http/listening)))
(assert (= "void.http" (hooks/owner-namespace :void/http)))
(assert (nil? (hooks/namespace-of :after-start)))

(def dreg (hooks/registry [:void.x/fired] [:void/x]))
(assert (hooks/declared? dreg :void.x/fired))
(assert (hooks/declared? dreg :after-start) "lifecycle hooks are always declared")
(assert (not (hooks/declared? dreg :void.x/typo)))
(assert (hooks/suspect? dreg :void.x/typo) "undeclared in an owned namespace: suspect")
(assert (not (hooks/suspect? dreg :void.y/event)) "an absent plugin's hook is not suspect")
(hooks/add! dreg :void.x/typo (fn [&] nil) :name :h)
(assert (deep= @[:void.x/typo] (keys dreg)) "the declaration set is not a hook of the registry")
(assert (= 1 (length (hooks/handlers dreg))) "nor does it show among the handlers")
# firing a suspect name warns (on stderr) and still runs the handlers
(assert (= 1 (hooks/run! dreg :void.x/typo)) "a suspect hook still runs its handlers")

(print "hooks-test: all assertions passed")
