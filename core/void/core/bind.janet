### void/core/bind — late binding of symbols (ADR-0002): the one
### resolver behind every place a symbol stands in for a function.
###
### A route handler, a job, a bus handler or command, a CLI command, an
### MCP tool and a lifecycle hook are all declared the same way: as a
### *symbol* naming a function, or as the function itself. The symbol
### is the point. The declaration holds `'orders/show` rather than
### `<function 0x…>`, which is what makes a route table or a job
### registry a value that prints, diffs and locks — and the function is
### read through the module's environment table on every call, so a
### redefinition in the REPL, or a reload by void/dev's watcher (which
### re-evaluates a file into its *existing* env table), is live for the
### next request, the next job, the next message, without anything
### being rebuilt. A function literal is accepted too and marked
### `:no-reload`: it is a value, and nothing can update a value behind
### a caller's back.
###
### Two spellings of a symbol. A qualified one — `'my-app.orders/show`
### — names binding `show` in module `my-app/orders` (dots become path
### separators); the module is `require`d, so it resolves from
### anywhere, a plugin manifest included. A bare one — `'show` — is
### looked up in `env`, the declaring module's environment: what
### `(curenv)` gave where the declaration was written, which `defroutes`,
### `defjob`, `defhandler` and `defcommand` capture for you. A bare
### symbol without an env is an error that says to qualify it.
###
### **Fail fast.** `resolve` looks the symbol up at once and raises when
### it does not name a function, so a route table, a job registry, a
### command or a tool is validated where it is declared or built — at
### boot, or at the command line before a component starts — and not by
### a 500 in production. What it keeps for the call is the env table
### and the name, never the function value: the per-call read is
### `(get-in env [name :value])`, two table lookups and a type check,
### which is exactly what Janet's own `resolve` does with a symbol.
### ADR-0002 planned a cache invalidated by an env-generation counter on
### top of that; there is nothing for such a cache to save — the lookup
### *is* the cache, and a generation would be a third thing to keep
### correct — so there is none.
###
### Errors are `:void.bind/unresolvable` envelopes (void/core/errors,
### ADR-0044): the message is one sentence naming what was being
### resolved and the symbol; `:data` carries `{:what :symbol}`. The
### sentence is part of the DX and is kept readable — "does not resolve
### to a function in the declaring module", "no longer names a function
### in its module — was it renamed?" — because the person reading it is
### the one who just renamed something.

(import ./errors :as errors)
(import ./util :as util)

(errors/define! :void.bind/unresolvable
  {:doc "a symbol standing in for a function does not name one — where it is declared or the table is built (fail fast), or after a reload, at the call; :data carries :what and :symbol"})

(defn- refuse
  "Raise `:void.bind/unresolvable` for `sym`: the formatted sentence as
  the message, `{:what :symbol}` as the data every caller can branch on."
  [what sym fmt & args]
  (errors/raise :void.bind/unresolvable
                (string/format fmt ;args)
                {:what what :symbol sym}))

(defn- unwrap-env
  "An env given as a closure (`router/env-ref`, because a manifest is
  frozen and freezing an env table walks the module graph) is called;
  a table is itself."
  [env]
  (if (util/callable? env) (env) env))

# -- symbols -------------------------------------------------------------

(defn qualified
  ``The [module-path name] of a qualified symbol — `'my-app.orders/show`
  is binding `show` in module "my-app/orders" — or nil for a bare one.``
  [sym]
  (def s (string sym))
  (when-let [i (last (string/find-all "/" s))]
    [(string/replace-all "." "/" (string/slice s 0 i))
     (symbol (string/slice s (inc i)))]))

(defn- module-env
  "The env of a qualified symbol's module, `require`d; a module that
  cannot be loaded is the symbol's fault as far as the reader is
  concerned, so the error names both."
  [sym path what]
  (def [ok env] (protect (require path)))
  (unless ok
    (refuse what sym "%s %q: module %q cannot be loaded: %s"
            what sym path (errors/message env)))
  env)

(defn- locate
  "[env name] a symbol resolves through; raises when the binding is
  not a function *now* — which, for a declaration, is fail fast."
  [sym env what]
  (def [menv nm]
    (if-let [[path nm] (qualified sym)]
      [(module-env sym path what) nm]
      [(or (unwrap-env env)
           (refuse what sym
                   "cannot resolve bare %s symbol %q without a module environment — qualify it (my-app.orders/show)"
                   what sym))
       sym]))
  (unless (util/callable? (get-in menv [nm :value]))
    (refuse what sym "%s %q does not resolve to a function%s"
            what sym (if (qualified sym) "" " in the declaring module")))
  [menv nm])

(defn- read-now
  "The function behind a located binding, read at the call: the env
  is live, so a binding a reload dropped or turned into something
  else says so here rather than as a call of nil."
  [menv nm sym what]
  (def f (get-in menv [nm :value]))
  (unless (util/callable? f)
    (refuse what sym "%s: %q no longer names a function in its module — was it renamed?"
            what sym))
  f)

# -- resolving -----------------------------------------------------------

(defn resolve
  ``Resolve a handler declaration — a symbol or a function — to a
  *binding*:

      {:call      (fn [& args])   ; the late-bound call
       :no-reload bool            ; true for a function literal
       :symbol    sym | nil       ; as declared
       :name      sym | nil       ; the binding's name in :env
       :env       env | nil       ; the module env it is read from
       :what      string}         ; what this is, for errors

  `env` is the declaring module's environment (or an env-ref closure)
  for bare symbols; `what` names the thing being resolved in errors
  ("handler", "job :welcome-mail", ":on-request hook"). A symbol that
  does not name a function now raises `:void.bind/unresolvable` — this
  is the fail-fast half. `:call` reads the binding on every call, so a
  reload is live; a function literal is called as it is.``
  [x &opt env what]
  (default what "handler")
  (cond
    (util/callable? x)
    {:call x :no-reload true :symbol nil :name nil :env nil :what what}

    (symbol? x)
    (let [[menv nm] (locate x env what)]
      {:call (fn late-bound [& args] ((read-now menv nm x what) ;args))
       :no-reload false
       :symbol x
       :name nm
       :env menv
       :what what})

    (refuse what x "%s must be a function or a symbol, got %q" what x)))

(defn current
  ``The function a binding stands for *right now* — the module binding
  for a symbol (what `explain-route` and a worker want to show or
  call), the literal itself otherwise. Raises `:void.bind/unresolvable`
  when the binding no longer names a function.``
  [b]
  (if (b :symbol)
    (read-now (b :env) (b :name) (b :symbol) (b :what))
    (b :call)))

(defn declared
  ``The binding of a `{:binding 'sym :env <env> :fn <function>}`
  declaration — the shape `defjob`, `defhandler` and `defcommand`
  record, both halves of the handler at once. The symbol in its env
  wins when both are given and the symbol names a function there
  (late-bound; a reload reaches it); otherwise the function value,
  `:no-reload` — which is what a definition written inside a function,
  at the REPL or by a factory has, since no module env holds its
  binding. Neither is an error naming the symbol.``
  [decl what]
  (def sym (get decl :binding))
  (def env (unwrap-env (get decl :env)))
  (def f (get decl :fn))
  (cond
    (and sym env (util/callable? (get-in env [sym :value]))) (resolve sym env what)
    (util/callable? f) (resolve f nil what)
    sym (resolve sym env what)
    (refuse what nil "%s: a definition needs :fn or :binding + :env" what)))

# -- describing, for tables and locks -------------------------------------

(def- short-fn-name
  "The name the compiler gives every `|` lambda: `(disasm |(+ $ 1))`
  reports `short-fn`, so two short lambdas would be one name — and one
  cache key, one lock entry. They are anonymous here, at the price of
  a function someone deliberately named `short-fn`."
  "short-fn")

(defn fn-name
  "The name of a function value, or nil for an anonymous one — read
  off its bytecode rather than `(string f)`, which prints an address
  for the anonymous and would put that address into a digest. A `|`
  lambda counts as anonymous (see `short-fn-name`)."
  [f]
  (cond
    (function? f) (when-let [n (get (disasm f) :name)]
                    (unless (= short-fn-name (string n)) (string n)))
    (cfunction? f) (let [s (string f)]
                     (when-let [m (peg/match '(* "<cfunction " (<- (some (if-not ">" 1))) ">") s)]
                       (unless (string/find "0x" (m 0)) (m 0))))
    nil))

(defn- template-prefix
  "The literal part of a module/paths template before `:all:`, with
  `:sys:` expanded; nil for templates relative to the requiring file
  or a dyn, which do not describe a module's location."
  [tpl]
  (when-let [i (string/find ":all:" tpl)]
    (def pre (string/slice tpl 0 i))
    (unless (or (string/find ":cur:" pre) (string/find ":@" pre))
      [(string/replace ":sys:" (string (dyn :syspath)) pre)
       (string/slice tpl (+ i 5))])))

(defn- candidate
  "The module name `src` has under one template prefix/suffix pair, or
  nil: a name is relative (an absolute path is a template that did
  not really match, `.:all:.janet` against an absolute source), and a
  module's `init` is the module."
  [pre post src]
  (when (and (not (empty? post))
             (string/has-prefix? pre src) (string/has-suffix? post src)
             (> (length src) (+ (length pre) (length post))))
    (def name (string/slice src (length pre) (- (length src) (length post))))
    (unless (or (string/has-prefix? "/" name) (string/find ".." name))
      (if (string/has-suffix? "/init" name)
        (string/slice name 0 (- (length name) 5))
        name))))

(defn- candidates
  "Every [prefix-length name] a source path has across module/paths:
  one per template that accounts for it, in the order of the paths."
  [src]
  (def cwd (string (os/cwd) "/"))
  (def relative (if (string/has-prefix? cwd src) (string/slice src (length cwd)) src))
  (seq [entry :in module/paths
        :let [tpl (when (indexed? entry) (entry 0))]
        :when (string? tpl)
        :let [pair (template-prefix tpl)]
        :when pair
        :let [[pre post] pair
              name (or (candidate pre post src)
                       (candidate (if (= "." pre) "" pre) post relative))]
        :when name]
    [(length pre) name]))

(defn- module-name-of
  ``Invert module/paths: the module name a source path was found under,
  or nil when no template accounts for it. Several templates may:
  `void` run at the repository root (cli/init's `add-project-paths!`)
  and scripts/dry-run put `<repo>/:all:.janet` *before* the packages'
  own `<repo>/http/:all:.janet`, and the first textual match would
  name the same lambda `http/void/http/router` there and
  `void/http/router` everywhere else — one lock, two hashes. So the
  most specific template wins, the one with the longest literal
  prefix, whatever its position; a tie keeps module/paths order.``
  [src]
  (get (extreme (fn more-specific? [a b] (> (a 0) (b 0))) (candidates src)) 1))

(defn origin
  ``The module a function was compiled from, as its module name
  (`"void/http"`, `"main"`) — the function's source path inverted
  through module/paths, so it reads the same on every machine that
  loaded the same code; nil for a cfunction, for a function evaluated
  at the REPL, or for a source no template accounts for.``
  [f]
  (when (function? f)
    (when-let [src (get (disasm f) :source)]
      (when (string? src)
        (module-name-of src)))))

(defn describe
  ``One string for a handler declaration in a table: a symbol as
  written, a named function as `<fn name>`, an anonymous one as
  `<fn>` — never an address.``
  [x]
  (cond
    (symbol? x) (string x)
    (util/callable? x) (if-let [n (fn-name x)] (string "<fn " n ">") "<fn>")
    (string/format "%q" x)))
