(import ../void/core/hooks :as hooks)

(defn expect-error
  {:params [:string :string (fn [] :any)] :ret :string}
  "Run `thunk`, asserting it throws and that its error mentions `pat`;
  answers the caught error rendered as a string."
  [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat))
  (string err))

# -- hook registry: validation -------------------------------------------

(def reg (hooks/registry))

(expect-error "non-keyword hook" "keyword"
  |(hooks/add! reg "before-start" (fn [_] nil))) # janet-zed: ignore types
(expect-error "non-function handler" "function"
  |(hooks/add! reg :before-start 42))
(expect-error "unknown option" "unknown option"
  |(hooks/add! reg :before-start (fn [_] nil) :prio 1))
(expect-error "a leftover :phase" ":phase was removed in ADR-0051"
  |(hooks/add! reg :before-start (fn [_] nil) :phase 500))
(expect-error "a bad edge" ":after"
  |(hooks/add! reg :before-start (fn [_] nil) :name :x :after "configured"))
(expect-error "odd options" "key-value"
  |(hooks/add! reg :before-start (fn [_] nil) :name))

# -- ordering: edges first, the unplaced after them by name --------------

(def log @[])
(hooks/add! reg :boot (fn [x] (array/push log [:b x])) :name :b)
(hooks/add! reg :boot (fn [x] (array/push log [:a x])) :name :a)
(hooks/add! reg :boot (fn [x] (array/push log [:late x])) :name :late :after :a)
(hooks/add! reg :boot (fn [x] (array/push log [:early x])) :name :early :before :late)

(assert (= 4 (hooks/run! reg :boot :ctx)) "run! returns the handler count")
(assert (= (freeze log)
           [[:a :ctx] [:early :ctx] [:late :ctx] [:b :ctx]])
        "placed handlers by their edges, the unplaced after them by name, args passed through")

(assert (zero? (hooks/run! reg :never-registered)) "unknown hook is a no-op")

# re-adding the same name replaces the handler
(hooks/add! reg :boot (fn [x] (array/push log [:early2 x])) :name :early :before :late)
(array/clear log)
(hooks/run! reg :boot 1)
(assert (= [:early2 1] (log 1)) "same :name replaces the handler")

# remove!
(assert (hooks/remove! reg :boot :b))
(assert (nil? (hooks/remove! reg :boot :b)) "second remove returns nil")
(assert (= 3 (length (hooks/handlers reg :boot))))
(assert (= 3 (length (hooks/handlers reg))) "handlers without hook lists everything")

# -- the lifecycle anchors -----------------------------------------------

(defn names
  {:params [@{:keyword :any} :keyword] :ret [:keyword]}
  "The handler names of `hook` on `r`, in execution order."
  [r hook]
  (tuple ;(map |($ :name) (hooks/handlers r hook))))

(defn noop
  {:params [:any] :ret :nil}
  "A handler that does nothing."
  [_] nil)

(def lreg (hooks/registry))
(hooks/add! lreg :before-start noop :name :z/reader :before :void.core/configured)
(hooks/add! lreg :before-start noop :name :a/table :after :void.core/configured)
(hooks/add! lreg :before-start noop :name :m/free)
(hooks/add! lreg :before-start noop :name :b/reader :before :void.core/configured)
(assert (= [:b/reader :z/reader :a/table :m/free] (names lreg :before-start))
        ":before-start: readers before :void.core/configured, by name; the builder after it; the unplaced last")

(hooks/add! lreg :after-start noop :name :z/banner :after :void.core/started)
(hooks/add! lreg :after-start noop :name :a/work :after :void.core/checked)
(hooks/add! lreg :after-start noop :name :y/check :before :void.core/checked)
(hooks/add! lreg :after-start noop :name :b/outbox :after :void.core/checked :before :a/work)
(hooks/add! lreg :after-start noop :name :c/bridge :after :a/work)
(hooks/add! lreg :after-start noop :name :a/free)
(assert (= [:y/check :b/outbox :a/work :c/bridge :z/banner :a/free]
           (names lreg :after-start))
        ":after-start: checks, then the work in edge order, then what follows :void.core/started, then the unplaced")

(hooks/add! lreg :before-stop noop :name :z/draining :before :void.core/drained)
(hooks/add! lreg :before-stop noop :name :b/stop :after :void.core/drained)
(hooks/add! lreg :before-stop noop :name :a/unbridge :after :void.core/drained :before :b/stop)
(assert (= [:z/draining :a/unbridge :b/stop] (names lreg :before-stop))
        ":before-stop: draining first, unbridge before stop-consuming")

(assert (not (some |($ :anchor) (hooks/handlers lreg))) "the anchors are not handlers")

# the tie-break is the graph's, not the order of registration
(def treg (hooks/registry))
(each n [:c :a :b]
  (hooks/add! treg :before-start noop :name n :before :void.core/configured))
(assert (= [:a :b :c] (names treg :before-start)) "ties broken by name")

# -- the cache -----------------------------------------------------------

(def creg (hooks/registry))
(hooks/add! creg :h noop :name :b)
(def first-order (hooks/handlers creg :h))
(assert (= first-order (hooks/handlers creg :h)) "the order is cached")
(hooks/add! creg :h noop :name :a)
(assert (= [:a :b] (names creg :h)) "add! drops the cached order")
(hooks/remove! creg :h :a)
(assert (= [:b] (names creg :h)) "remove! drops the cached order")

# -- errors in the order -------------------------------------------------

(def ereg0 (hooks/registry))
(hooks/add! ereg0 :before-start noop :name :x :after :void.core/configurd)
(expect-error "unknown edge" "unknown" |(hooks/handlers ereg0 :before-start))
(hooks/remove! ereg0 :before-start :x)
(hooks/add! ereg0 :before-start noop :name :x :after :y)
(hooks/add! ereg0 :before-start noop :name :y :after :x)
(expect-error "a cycle" "cycle" |(hooks/handlers ereg0 :before-start))
(hooks/remove! ereg0 :before-start :y)
(hooks/add! ereg0 :other noop :name :y :after :void.core/configured)
(expect-error "an anchor of another hook" "unknown" |(hooks/handlers ereg0 :other))

# an edge to a plugin the contributor does not require
(def rreg (hooks/registry nil nil {:p/a {:void/core "1"} :p/b {:p/a "1"}}))
(hooks/add! rreg :h noop :name :a/first :plugin :p/a)
(hooks/add! rreg :h noop :name :b/next :plugin :p/b :after :a/first)
(assert (= [:a/first :b/next] (names rreg :h)) "an edge to a required plugin's handler")
(hooks/add! rreg :h noop :name :a/late :plugin :p/a :after :b/next)
(expect-error "not required" "does not require" |(hooks/handlers rreg :h))

# -- error propagation ---------------------------------------------------

(def ereg (hooks/registry))
(def eorder @[])
(hooks/add! ereg :h (fn [_] (array/push eorder :first)) :name :ok)
(hooks/add! ereg :h (fn [_] (error "boom")) :name :bad :plugin :test/p :after :ok)
(hooks/add! ereg :h (fn [_] (array/push eorder :third)) :name :after :after :bad)

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
