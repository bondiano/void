### void/bus/router — `defhandler`, the subscription registry, and the
### chain a delivered message runs through (SPEC.md §5.22, ADR-0012,
### ROADMAP 3.6).
###
###     (bus/defhandler user-created
###       "Index a new user."
###       {:topic :user/created}
###       [msg]
###       (search/index (msg :payload)))
###
### A handler is a name, a topic pattern and a function. The name is a
### keyword and the function is held as a **binding** rather than as a
### value (ADR-0002) — the defining module's environment plus the
### symbol, read at delivery time — so a `defhandler` redefined in the
### REPL, or reloaded by void/dev's watcher, is live for the next
### message without a restart. `defjob` and void/http's symbol
### handlers resolve the same way, for the same reason.
###
### **One consumer, many handlers.** The router registers a *single*
### subscription with the backend — one consumer group for this
### process — and fans the message out to every handler whose pattern
### matches, in name order, on the consuming fiber. Which is what
### makes the guarantees legible: a group's messages arrive in order
### because there is one reader, and two handlers on the same topic
### cannot interleave. It is also the cost: a handler that blocks
### blocks the group, and a consumer that needs concurrency runs
### `[:bus :groups]` of them or hands the work to void/jobs, which is
### the layer whose whole subject is "do this, and take your time"
### (ADR-0012).
###
### **A partial fan-out fails the message.** If two handlers match and
### the second throws, the message is nacked — and an at-least-once
### backend will hand it to *both* again. That is not an oversight and
### it cannot be fixed at this layer: a per-handler cursor is a
### per-handler group, which is what `:group` on a handler declares
### when a consumer needs it. Handlers should be idempotent; the dedup
### middleware makes "it arrived twice" cheap, and this docstring is
### where a reader finds out before production does.

(import void/core/log :as log)
(import ./message :as message)
(import ./middleware :as middleware)

(def log-ns "void.bus")

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(defn- names-str [names]
  (string/join (map |(string/format "%q" $) (sorted names)) " "))

# -- definitions ---------------------------------------------------------

(def- allowed-opts
  {:topic true :group true :middleware true :retry true :schema true
   :timeout true})

(defn normalize-opts
  ``Validate a handler's options. Nothing is filled in — what a
  handler does not say is decided by the [:bus] slice when the chain
  is built, so a default changed in a config file reaches handlers
  that never mentioned it.``
  [who opts0]
  (def opts (or opts0 {}))
  (unless (dictionary? opts)
    (errorf "%s: options must be a dictionary, got %q" who opts))
  (eachk k opts
    (unless (in allowed-opts k)
      (errorf "%s: unknown option %q (allowed: %s)"
              who k (names-str (keys allowed-opts)))))
  (def topic (get opts :topic))
  (unless topic
    (errorf "%s: a handler needs a :topic — an exact topic (:user/created), a namespace (:user/*) or :*" who))
  (message/check-pattern! topic who)
  (when-let [g (get opts :group)]
    (unless (keyword? g)
      (errorf "%s: :group must be a keyword, got %q" who g)))
  (when-let [ms (get opts :middleware)]
    (unless (and (indexed? ms) (all keyword? ms))
      (errorf "%s: :middleware must be a tuple of middleware names, got %q" who ms)))
  (when-let [t (get opts :timeout)]
    (unless (and (number? t) (pos? t))
      (errorf "%s: :timeout must be a positive number of seconds, got %q" who t)))
  (table/to-struct (merge @{} opts)))

(def registry
  ``Handler definitions by name. Global on purpose, like void/jobs's:
  a topic is what travels between processes, and the process consuming
  it finds the handler here without the publisher telling it where.
  Redefining a name replaces the definition — which is what makes a
  reload live.``
  @{})

(defn define!
  ``Register a handler definition (the runtime half of `defhandler`).
  The function is named either by :binding + :env — the late-binding
  form — or by :fn, which is what a handler defined at the REPL or
  built by a factory gets and which a reload does not reach.``
  [name opts binding]
  (unless (keyword? name)
    (errorf "bus handler name must be a keyword, got %q" name))
  (def who (string/format "bus handler %q" name))
  # the handler's own name travels in its options, so that a
  # middleware's :when predicate and its errors can say which handler
  # they are about (the options are all a :wrap ever sees)
  (def o (table/to-struct (merge @{} (normalize-opts who opts) {:name name})))
  (unless (dictionary? binding)
    (errorf "%s: expected {:env ... :binding ...} or {:fn ...}, got %q" who binding))
  (def f (get binding :fn))
  (def sym (get binding :binding))
  (when f
    (unless (callable? f)
      (errorf "%s: :fn must be a function, got %q" who f)))
  (when sym
    (unless (dictionary? (get binding :env))
      (errorf "%s: :binding %q needs the :env it lives in" who sym)))
  (unless (or f sym)
    (errorf "%s: a definition needs :fn or :binding + :env" who))
  (def d
    (table/to-struct
      @{:name name
        :topic (o :topic)
        :opts o
        :fn f
        :binding sym
        # shallow, deliberately: :env is the defining module's own
        # environment, and a deep copy of it is a walk that does not end
        :env (get binding :env)
        :doc (get binding :doc)}))
  (put registry name d)
  d)

(defn lookup
  "The definition registered under `name`, or nil."
  [name]
  (get registry name))

(defn defined
  "Names of every registered handler."
  []
  (sorted (keys registry)))

(defn forget!
  "Drop a handler definition — for tests, and for a REPL that renamed
  one."
  [name]
  (put registry name nil))

(defn handler-fn
  ``The function behind a definition, resolved now rather than when it
  was declared: a `defhandler` whose module has been reloaded runs the
  new body, and one whose binding has stopped being a function says so
  here rather than in the middle of a delivery.``
  [d]
  (def b (when (and (d :env) (d :binding)) (get (d :env) (d :binding))))
  (cond
    (and b (callable? (get b :value))) (b :value)
    (callable? (d :fn)) (d :fn)
    (errorf "bus handler %q: %q no longer names a function in its module — was it renamed?"
            (d :name) (d :binding))))

(defn for-group
  ``Every handler belonging to consumer group `group` — the ones that
  named it, plus the ones that named nothing when `group` is the
  composition's default. In name order, which is the order a message
  reaches them.``
  [group default-group]
  (seq [name :in (defined)
        :let [d (registry name)]
        :when (= group (get-in d [:opts :group] default-group))]
    d))

(defn groups
  "Every consumer group the declared handlers ask for."
  [default-group]
  (def seen @{})
  (each name (defined)
    (put seen (get-in (registry name) [:opts :group] default-group) true))
  (sorted (keys seen)))

(defn topics
  "The topic patterns a set of handler definitions covers."
  [defs]
  (def seen @{})
  (each d defs (put seen (d :topic) true))
  (sorted (keys seen)))

(defn exact-topics
  ``The topics of `defs` when every one of them is exact, else nil —
  what lets a backend narrow its read to `topic IN (...)`. A single
  wildcard among them makes the whole set unnarrowable, which is the
  honest answer: a group that subscribes to `:user/*` wants topics
  that do not exist yet.``
  [defs]
  (def ts (topics defs))
  (when (all message/exact? ts) ts))

(defn matches
  "The handlers of `defs` whose pattern matches `topic`, in name
  order."
  [defs topic]
  (filter |(message/matches? ($ :topic) topic) defs))

# -- compiled handlers ---------------------------------------------------

(defn compile
  ``Build one handler's chain: the middleware selected for it, wrapped
  around a call of its (late-bound) function. Done once, when the
  consumer starts — a chain rebuilt per message would put the
  selection, the sort and the predicate evaluation on the hot path,
  which is the mistake void/http does not make either.

  The *function* is still resolved per message, so a reload is live
  while the chain is not rebuilt: a handler whose middleware changed
  needs a restart, and a handler whose body changed does not.``
  [d contribs]
  (def call
    (fn call-handler [msg]
      ((handler-fn d) msg)))
  (def wrapped
    (middleware/chain (middleware/select contribs (d :opts)) call (d :opts)))
  (def timeout (get-in d [:opts :timeout]))
  {:name (d :name)
   :topic (d :topic)
   :fn (if timeout
         (fn with-deadline [msg]
           (ev/with-deadline timeout (wrapped msg)))
         wrapped)})

(defn compile-group
  "Compile every handler of a group, keeping them in name order."
  [defs contribs]
  (tuple ;(map |(compile $ contribs) defs)))

(defn dispatch
  ``Run a message through every compiled handler whose pattern
  matches. Returns the number of handlers that saw it.

  An error from any handler propagates — the message is nacked, and
  what that means is the backend's declared guarantee. The handlers
  that already ran are not undone: see the module docstring on why
  idempotence is the contract here and not an aspiration.``
  [compiled msg]
  (var n 0)
  (each h compiled
    (when (message/matches? (h :topic) (msg :topic))
      ((h :fn) msg)
      (++ n)))
  (when (zero? n)
    (log/debug "message reached a group with no handler for it" :ns log-ns
               :topic (msg :topic) :id (msg :id)))
  n)

# -- the macro -----------------------------------------------------------

(defn defhandler-form
  ``The expansion of `defhandler`, as a function — so that the macro
  can exist both here and on `void/bus` (which is what applications
  import) without being written twice.``
  [name more]
  (var rest more)
  (var doc nil)
  (when (string? (first rest))
    (set doc (first rest))
    (set rest (tuple ;(drop 1 rest))))
  (var opts nil)
  (when (and (dictionary? (first rest)) (not (indexed? (first rest))))
    (set opts (first rest))
    (set rest (tuple ;(drop 1 rest))))
  (def params (first rest))
  (unless (and (indexed? params) (all symbol? params))
    (errorf "defhandler %q: expected a parameter list after the name%s, got %q"
            name (if doc " and docstring" "") params))
  (unless (= 1 (length params))
    (errorf "defhandler %q: a handler takes exactly one parameter, the message, got %q"
            name params))
  (def body (drop 1 rest))
  ~(upscope
     (defn ,name ,;(if doc [doc] []) ,params ,;body)
     (,define! ,(keyword name) ,opts
               {:env (,curenv) :binding ',name :fn ,name :doc ,doc})))

(defmacro defhandler
  ``Subscribe a function to a topic:

      (bus/defhandler order-paid
        "Ship what was paid for."
        {:topic :order/paid}
        [msg]
        (shipping/schedule (get-in msg [:payload "order_id"])))

  The docstring and the options map are both optional and both come
  before the parameter list, exactly where `defn` would put the
  docstring. The name of the handler is the name of the function as a
  keyword, and the function stays an ordinary function — calling it
  with a message runs the body inline, without a chain, which is
  usually what a unit test wants.

  Options: :topic (required), :group, :middleware, :schema, :timeout —
  see `normalize-opts`.

  Declare handlers at the top level of a module. One declared inside a
  function still works, but its body is then the value captured right
  there rather than a module binding, so a reload does not reach it.``
  [name & more]
  (defhandler-form name more))
