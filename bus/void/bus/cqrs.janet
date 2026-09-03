### void/bus/cqrs — commands and events, with the shape declared once.
###
### An optional layer, and a thin one: it adds no transport and no
### second registry of handlers. What it adds is a **name with a
### schema on it**, so that the shape of a command and the shape of an
### event are written down in one place and checked at both ends —
### which is the whole of what CQRS buys a codebase that already has a
### message bus underneath.
###
###     (bus/defevent account-debited
###       {:topic :account/debited
###        :schema {:account :string :amount :number}})
###
###     (bus/emit-tx! :account-debited {:account id :amount amt})
###
###     (bus/defevent-handler notify-customer
###       {:event :account-debited}
###       [msg]
###       (mail/send ...))          # (msg :payload) is coerced and valid
###
### **A command is dispatched in this process, and returns.** Exactly
### one handler and a reply is a *call*, not a publication: over an
### asynchronous transport it would need a reply topic, a correlation
### wait and a timeout — which is a request/response protocol, and void
### already has one of those (`void/http`, and `void/grpc` in wave 4).
### So `send` finds the single handler registered under the command
### name **here**, validates the payload against the command's schema
### and calls it on the caller's fiber; a command with no handler in
### this process is an error naming the command, not a message that
### goes off to be lost. What crosses a process boundary is the
### *event* the command handler emits, which is the direction the
### asymmetry actually runs in.
###
### **Two handlers for one command is a declaration error**, checked
### where the second one is declared. That is the one rule that
### separates a command bus from an event bus, and enforcing it at
### declaration is what makes it a rule rather than a race.

(import void/core/log :as log)
(import void/core/schema :as schema)
(import ./router :as router)
(import ./state :as state)

(def log-ns "void.bus.cqrs")

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(defn- names-str [names]
  (string/join (map |(string/format "%q" $) (sorted names)) " "))

# -- events --------------------------------------------------------------

(def events
  ``Declared events by name: `{:topic :schema :doc}`. An event's name
  and its topic are two different things on purpose — the name is what
  this codebase calls it, the topic is what goes on the wire, and a
  topic that has to be renamed for another consumer should not rename
  every call site.``
  @{})

(defn define-event!
  "Register an event declaration (the runtime half of `defevent`)."
  [name opts]
  (unless (keyword? name)
    (errorf "bus event name must be a keyword, got %q" name))
  (def topic (get opts :topic name))
  (unless (keyword? topic)
    (errorf "bus event %q: :topic must be a keyword, got %q" name topic))
  (when-let [sch (get opts :schema)]
    # normalized now, so a schema that cannot be read is a load error
    # rather than a failure on the first message of the month
    (def [ok err] (protect (schema/normalize sch)))
    (unless ok
      (errorf "bus event %q: :schema is not a schema: %s"
              name (if (string? err) err (describe err)))))
  (def d (table/to-struct
           @{:name name :topic topic
             :schema (get opts :schema)
             :doc (get opts :doc)}))
  (put events name d)
  d)

(defn event
  "The declaration behind an event name; throws naming what is
  declared when there is none."
  [name]
  (or (get events name)
      (errorf "no bus event named %q is declared in this process (declared: %s)"
              name (names-str (keys events)))))

(defn declared-events
  "Names of every declared event."
  []
  (sorted (keys events)))

(defn forget-event!
  "Drop an event declaration — for tests, and for a REPL that renamed
  one."
  [name]
  (put events name nil))

(defn- checked [d payload who]
  (if-let [sch (d :schema)]
    (let [[ok res] (protect (schema/validate sch payload {:coerce true}))]
      (unless ok
        (errorf "%s %q does not match its declared schema: %s"
                who (d :name) (if (string? res) res (describe res))))
      res)
    payload))

(defn emit!
  ``Publish a declared event after checking its payload against the
  schema the declaration carries. The check is on the *publishing*
  side, which is where a shape can still be fixed by the person who
  broke it.``
  [name payload &opt opts]
  (def d (event name))
  (state/publish (d :topic) (checked d payload "event") opts))

(defn emit-tx!
  ``The same as `emit!`, through the transactional outbox — the
  spelling an event about money uses: the message is written in the
  transaction that made the change it announces.``
  [name payload &opt opts]
  (def d (event name))
  (state/publish-tx! (d :topic) (checked d payload "event") opts))

(defn event-handler-opts
  ``Turn `{:event :account-debited}` into the `defhandler` options it
  stands for — the event's topic and its schema, so that a consumer
  declares which event it handles and never repeats the shape.``
  [opts]
  (def name (get opts :event))
  (unless name
    (error "a defevent-handler needs :event — the name of a declared event"))
  (def d (event name))
  (def rest (table ;(kvs opts)))
  (put rest :event nil)
  (table/to-struct
    (merge @{:topic (d :topic)}
           (if (d :schema) {:schema (d :schema)} {})
           rest)))

# -- commands ------------------------------------------------------------

(def commands
  "Declared command handlers by name: `{:schema :fn :binding :env}`."
  @{})

(defn define-command!
  ``Register a command handler (the runtime half of `defcommand`). A
  second handler for the same name is an error — that rule is the
  whole difference between a command and an event, and it is checked
  where the second declaration is, so the message names both.``
  [name opts binding]
  (unless (keyword? name)
    (errorf "bus command name must be a keyword, got %q" name))
  (def who (string/format "bus command %q" name))
  (when-let [prev (get commands name)]
    # a redefinition of the *same* binding is a reload, not a conflict
    (when (and (prev :binding) (not= (prev :binding) (get binding :binding)))
      (errorf "%s already has a handler (%q) — a command has exactly one, which is the whole difference between a command and an event. Publish an event if several things should happen"
              who (prev :binding))))
  (when-let [sch (get opts :schema)]
    (def [ok err] (protect (schema/normalize sch)))
    (unless ok
      (errorf "%s: :schema is not a schema: %s" who (if (string? err) err (describe err)))))
  (def f (get binding :fn))
  (when f
    (unless (callable? f)
      (errorf "%s: :fn must be a function, got %q" who f)))
  (def d (table/to-struct
           @{:name name
             :schema (get opts :schema)
             :fn f
             :binding (get binding :binding)
             :env (get binding :env)
             :doc (get binding :doc)}))
  (put commands name d)
  d)

(defn command
  "The handler declaration behind a command name; throws naming what
  is declared when there is none."
  [name]
  (or (get commands name)
      (errorf "no bus command named %q is declared in this process (declared: %s) — a command is dispatched here, so the module that declares it has to be imported here"
              name (names-str (keys commands)))))

(defn declared-commands
  "Names of every declared command."
  []
  (sorted (keys commands)))

(defn forget-command!
  "Drop a command declaration."
  [name]
  (put commands name nil))

(defn command-fn
  "The function behind a command, resolved now — late-bound the way a
  handler's is, so a reload is live."
  [d]
  (def b (when (and (d :env) (d :binding)) (get (d :env) (d :binding))))
  (cond
    (and b (callable? (get b :value))) (b :value)
    (callable? (d :fn)) (d :fn)
    (errorf "bus command %q: %q no longer names a function in its module — was it renamed?"
            (d :name) (d :binding))))

(defn send
  ``Dispatch a command to its one handler and return what the handler
  returned. The payload is validated (and coerced) against the
  command's schema first, so a handler's body may assume the shape it
  declared.

  Synchronous, on the caller's fiber, in this process — see the module
  docstring on why a command bus that crossed processes would be a
  request/response protocol wearing a bus for a hat.``
  [name payload]
  (def d (command name))
  (def checked-payload (checked d payload "command"))
  (log/debug "command dispatched" :ns log-ns :command name)
  ((command-fn d) checked-payload))

# -- the macros ----------------------------------------------------------

(defn defevent-form
  "The expansion of `defevent`, as a function."
  [name more]
  (var rest more)
  (var doc nil)
  (when (string? (first rest))
    (set doc (first rest))
    (set rest (tuple ;(drop 1 rest))))
  (def opts (first rest))
  (unless (dictionary? opts)
    (errorf "defevent %q: expected an options map%s, got %q"
            name (if doc " after the docstring" "") opts))
  ~(def ,name
     ,;(if doc [doc] [])
     (,define-event! ,(keyword name)
                     (,merge @{:doc ,doc} ,opts))))

(defn defevent-handler-form
  "The expansion of `defevent-handler`, as a function: the event's
  topic and schema are looked up at declaration and handed to the
  ordinary handler registry, so there is one kind of handler and not
  two."
  [name more]
  (var rest more)
  (var doc nil)
  (when (string? (first rest))
    (set doc (first rest))
    (set rest (tuple ;(drop 1 rest))))
  (def opts (first rest))
  (unless (and (dictionary? opts) (not (indexed? opts)))
    (errorf "defevent-handler %q: expected an options map with :event, got %q" name opts))
  (def params (get rest 1))
  (unless (and (indexed? params) (= 1 (length params)) (all symbol? params))
    (errorf "defevent-handler %q: expected a one-parameter list after the options, got %q"
            name params))
  (def body (drop 2 rest))
  ~(upscope
     (defn ,name ,;(if doc [doc] []) ,params ,;body)
     (,router/define! ,(keyword name) (,event-handler-opts ,opts)
                      {:env (,curenv) :binding ',name :fn ,name :doc ,doc})))

(defn defcommand-form
  "The expansion of `defcommand`, as a function."
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
  (unless (and (indexed? params) (= 1 (length params)) (all symbol? params))
    (errorf "defcommand %q: expected a one-parameter list after the name%s, got %q"
            name (if doc " and docstring" "") params))
  (def body (drop 1 rest))
  ~(upscope
     (defn ,name ,;(if doc [doc] []) ,params ,;body)
     (,define-command! ,(keyword name) ,opts
                       {:env (,curenv) :binding ',name :fn ,name :doc ,doc})))

(defmacro defevent
  ``Declare an event: the name this codebase calls it, the topic it
  goes out on and the shape of its payload.

      (bus/defevent account-debited
        "Money left an account."
        {:topic :account/debited
         :schema {:account :string :amount :number}})

  `:topic` defaults to the name. The declaration is a value — `(pp
  account-debited)` prints it — and `bus/emit!` is what publishes.``
  [name & more]
  (defevent-form name more))

(defmacro defevent-handler
  ``Handle a declared event, taking its topic and its schema from the
  declaration:

      (bus/defevent-handler notify-customer
        {:event :account-debited}
        [msg]
        (mail/send (msg :payload)))

  Every `defhandler` option except `:topic` and `:schema` may be
  given as well — `:group`, `:middleware`, `:timeout`.``
  [name & more]
  (defevent-handler-form name more))

(defmacro defcommand
  ``Declare the one handler of a command:

      (bus/defcommand debit-account
        "Take money off an account, or refuse."
        {:schema {:account :string :amount [:number {:min 0}]}}
        [cmd]
        (db/with-tx
          (accounts/debit! (cmd :account) (cmd :amount))
          (bus/emit-tx! :account-debited cmd)))

      (bus/send :debit-account {:account "42" :amount 10})

  The function stays an ordinary function: calling it directly skips
  the schema check, which is what a unit test of the body usually
  wants.``
  [name & more]
  (defcommand-form name more))
