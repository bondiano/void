(import ../void/core/bind :as bind)
(import ../void/core/errors :as errors)

# The tests import the module under test relatively; a qualified symbol
# goes through `require`, so the package root has to be a module path
# for `'void.core.errors/message` to be findable from here
(array/insert module/paths 0 [(string (os/cwd) "/:all:.janet") :source])

(defn expect-unresolvable [name needle thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (= :void.bind/unresolvable (errors/kind err))
          (string name ": kind " (string/format "%q" (errors/kind err))))
  (assert (string/find needle (errors/message err))
          (string name ": message " (string/format "%q" (errors/message err))
                  " lacks " (string/format "%q" needle))))

# -- a bare symbol is read through the declaring env, per call ---------

(defn greet [who] (string "hello " who))
(def env (curenv))

(def b (bind/resolve 'greet env "handler"))
(assert (= "hello x" ((b :call) "x")) "a bare symbol resolves in the declaring env")
(assert (not (b :no-reload)) "and reloads")
(assert (= 'greet (b :symbol)))
(assert (= greet (bind/current b)) "current is the module binding")

(defn greet [who] (string "hi " who))
(assert (= "hi x" ((b :call) "x"))
        "a redefinition — what a reload does to the env — is live without re-resolving")
(assert (= greet (bind/current b)))

# -- a function literal is itself, :no-reload -----------------------------

(def lit (bind/resolve (fn [x] (* 2 x)) nil "handler"))
(assert (= 84 ((lit :call) 42)))
(assert (lit :no-reload) "a value cannot be reloaded behind the caller's back")
(assert (nil? (lit :symbol)))
(assert (= (lit :call) (bind/current lit)))

(def cf (bind/resolve string/ascii-upper nil "handler"))
(assert (= "A" ((cf :call) "a")) "a cfunction is a function too")

# -- a qualified symbol requires its module -------------------------------

(def q (bind/resolve 'void.core.errors/message nil "handler"))
(assert (= "went wrong" ((q :call) (errors/make :t/x "went wrong")))
        "dots become path separators, the module is required")
(assert (= 'message (q :name)) "the binding's name is the part after the slash")

(assert (deep= ["my-app/orders" 'show] (bind/qualified 'my-app.orders/show)))
(assert (nil? (bind/qualified 'show)) "a bare symbol has no module")

# -- fail fast: an unresolvable symbol is refused where it is declared ---

(expect-unresolvable "bare without env" "qualify it"
                     |(bind/resolve 'greet nil "handler"))
(expect-unresolvable "bare, not in env" "does not resolve to a function in the declaring module"
                     |(bind/resolve 'never-defined env "handler"))
(expect-unresolvable "qualified, missing binding" "does not resolve to a function"
                     |(bind/resolve 'void.core.errors/never-defined nil "handler"))
(expect-unresolvable "qualified, missing module" "cannot be loaded"
                     |(bind/resolve 'no.such.module/thing nil "handler"))
(expect-unresolvable "neither symbol nor function" "must be a function or a symbol"
                     |(bind/resolve 42 nil ":on-request hook"))

(def [_ e] (protect (bind/resolve 'never-defined env "job :welcome-mail")))
(assert (string/has-prefix? "job :welcome-mail" (errors/message e))
        "the error names what was being resolved")
(assert (= 'never-defined (get (errors/data e) :symbol)) "and carries the symbol as data")

# the env-ref spelling — a closure around the env, because a manifest is
# frozen — is unwrapped by bind, not by every consumer
(assert (= "hi y" (((bind/resolve 'greet (fn [] env) "handler") :call) "y")))

# -- a binding that stops naming a function says so at the call ----------

(defn doomed [x] x)
(def d (bind/resolve 'doomed env "job :doomed"))
(def doomed 5)
(expect-unresolvable "renamed away" "no longer names a function in its module — was it renamed?"
                     |((d :call) 1))
(expect-unresolvable "current, renamed away" "job :doomed" |(bind/current d))

# -- declared: both halves of a defjob/defhandler declaration ------------

(defn work [x] (+ x 1))
(def decl (bind/declared {:binding 'work :env env :fn work} "job :work"))
(assert (not (decl :no-reload)) "a module-level binding wins over the captured value")
(defn work [x] (+ x 100))
(assert (= 101 ((decl :call) 1)) "so a reload reaches it")

(defn- declare-nested []
  (defn nested [x] (* 10 x))
  (bind/declared {:binding 'nested :env env :fn nested} "job :nested"))
(def nested-decl (declare-nested))
(assert (nested-decl :no-reload)
        "a declaration inside a function holds a binding no module env has — the value is used")
(assert (= 30 ((nested-decl :call) 3)))

(assert (= 2 (((bind/declared {:fn |(+ $ 1)} "job :x") :call) 1)) "a value alone")
(expect-unresolvable "a declaration with nothing" "needs :fn or :binding"
                     |(bind/declared {} "job :x"))
(expect-unresolvable "a symbol nothing holds and no value" "does not resolve"
                     |(bind/declared {:binding 'nothing-here :env env} "job :x"))

# -- describe, fn-name, origin: how tables and locks name a handler ------

(assert (= "my-app.orders/show" (bind/describe 'my-app.orders/show)))
(assert (= "<fn greet>" (bind/describe greet)) "a named function by name")
(assert (= "<fn>" (bind/describe (fn [] 1))) "an anonymous one without an address")
(assert (= "<fn string/find>" (bind/describe string/find)))
(assert (= "greet" (bind/fn-name greet)))
(assert (nil? (bind/fn-name (fn [] 1))))
(assert (nil? (bind/fn-name 42)))

# origin is the source path inverted through module/paths — a module
# *name*, which is the same on every machine that loaded the same code
(array/push module/paths ["/virtual/:all:.janet" :source])
(array/push module/paths ["/virtual/:all:/init.janet" :source])
# `compile` gives a thunk; calling it gives the anonymous function it
# builds, which carries the same source
(def in-app ((compile '(fn [] 1) (curenv) "/virtual/app/a.janet")))
(def in-init ((compile '(fn [] 1) (curenv) "/virtual/app/b/init.janet")))
(def elsewhere ((compile '(fn [] 1) (curenv) "/elsewhere/c.janet")))
(def in-project ((compile '(fn [] 1) (curenv) (string (os/cwd) "/main.janet"))))
(assert (nil? (bind/fn-name in-app)) "which is anonymous")
(assert (= "app/a" (bind/origin in-app)))
(assert (= "app/b" (bind/origin in-init)) "a module's init is the module")
(assert (nil? (bind/origin elsewhere)) "a source no template accounts for has no origin")
(assert (= "main" (bind/origin in-project)) "a project module through the cwd template")
(assert (= "void/core/errors" (bind/origin errors/message)) "a package module by its name")
(assert (nil? (bind/origin string/find)) "a cfunction has no source")

(print "void/core/bind tests OK")
