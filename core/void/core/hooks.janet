### void/core/hooks — lifecycle hooks.
###
### Synchronous and ordered: handlers are registered per hook name
### (:config-loaded, :before-start, ... or any custom keyword), placed
### by `:after`/`:before` edges to the hook's named anchors
### (`lifecycle-anchors`) or to another handler of the same hook, and
### run on the caller's fiber — bootstrap wiring, not messaging. A
### handler with no edge runs after the placed ones, by name (ADR-0051:
### there is no number to pick). Application events (:user/created ...)
### are void/bus's business (ADR-0012); the in-process pub/sub that
### used to live here had no consumer left.
###
### A hook is *declared* by the plugin that fires it — `:hooks [...]` in
### its manifest — so a registry built by bootstrap knows every name
### that can ever run. Firing an undeclared name is a warning rather
### than an error (a hook is a notification, and a typo in it must not
### take the process down), and a handler registered for one is
### reported at boot with a did-you-mean, the way extension points are.

(import ./order :as order)
(import ./util :as util)

(def lifecycle-hooks
  "Hooks fired by the core lifecycle itself: :config-loaded,
  :before-start and :after-start by plugin/start!, :before-stop and
  :after-stop by plugin/shutdown!. Every handler receives the boot
  value. Any other keyword is a valid custom hook."
  [:config-loaded :before-start :after-start :before-stop :after-stop])

(def lifecycle-anchors
  ``The named places inside a lifecycle hook a handler is put by
  `:after`/`:before`, in order; a hook not named here has none.

    :before-start  :void.core/configured — before it, every reader of
                   a config slice and every context builder; after it,
                   what reads those (http/build-table)
    :after-start   :void.core/checked — before it, the checks that
                   refuse a composition; after it, the work (consumers,
                   seeds, instrumentation) — then :void.core/started,
                   after which the process says it is up
    :before-stop   :void.core/drained — before it, what stops taking
                   work; after it, what stops doing it``
  {:before-start [:void.core/configured]
   :after-start [:void.core/checked :void.core/started]
   :before-stop [:void.core/drained]})

# -- hook registry -------------------------------------------------------

(def- allowed-handler-opts
  {:after true :before true :name true :plugin true :doc true})

(defn namespace-of
  {:params [:keyword] :ret :string?}
  "The namespace of a hook name: :void.http/listening -> \"void.http\";
  a bare :after-start -> nil."
  [hook]
  (def s (string hook))
  (when-let [slash (string/find "/" s)]
    (string/slice s 0 slash)))

(defn owner-namespace
  {:params [:keyword] :ret :string}
  "The hook namespace a plugin name owns: :void/http -> \"void.http\",
  :shop/app -> \"shop.app\"."
  [plugin]
  (string/replace-all "/" "." (string plugin)))

(defn registry
  {:params [(or [:keyword] :nil) (or [:keyword] :nil) (or {:keyword :any} :nil)]
   :ret @{:keyword :any}}
  ``Create an empty hook registry: hook name -> handler name -> entry.

  Bootstrap builds one with three sets, and a test's bare
  `(hooks/registry)` has none and runs anything silently:

    declared  the hook names that can be fired through this registry —
              the lifecycle hooks plus every `:hooks` an active plugin
              declares
    owners    the active plugins (names), whose hook namespaces are
              thereby *owned*: :void/http owns :void.http/*
    requires  each active plugin -> its manifest's `:requires`: a
              handler's edge may point at an anchor, a handler of its
              own plugin, of void/core or of a plugin it requires
              (nil skips that check)

  A name is suspect when its namespace is owned and nobody declared
  it — :void.http/listenng with void/http active. A name in a namespace
  nobody owns (:void.dev/reloaded in a composition without void/dev)
  is a hook of a plugin that is simply not here, and neither firing it
  nor handling it is a mistake. The sets, and the per-hook order
  `handlers` caches, live on the table's prototype so that
  `keys`/`values`/`each` over the registry still see hooks alone.``
  [&opt declared owners requires]
  (table/setproto
    @{}
    (merge @{:hooks/cache @{} :hooks/requires requires}
           (if (and (nil? declared) (nil? owners))
             {}
             {:hooks/declared (tabseq [h :in (or declared [])] h true)
              :hooks/owned (tabseq [o :in (or owners [])] (owner-namespace o) true)
              :hooks/warned @{}}))))

(defn declared?
  {:params [@{:keyword :any} :keyword] :ret :boolean :narrows :any}
  "Is `hook` declared on this registry — or is the registry undeclared,
  in which case every name is. Lifecycle hooks always are."
  [reg hook]
  (def d (get reg :hooks/declared))
  (or (nil? d) (in d hook) (not (nil? (index-of hook lifecycle-hooks)))))

(defn suspect?
  {:params [@{:keyword :any} :keyword] :ret :boolean :narrows :any}
  "An undeclared hook in a namespace an active plugin owns — the
  shape of a typo, or of a plugin firing what it never declared."
  [reg hook]
  (and (not (declared? reg hook))
       (let [ns (namespace-of hook)]
         (and ns (in (get reg :hooks/owned {}) ns)))))

(defn- warn-undeclared!
  {:params [@{:keyword :any} :keyword] :ret :nil}
  "Warn once per name (the registry remembers) when a fired hook is one
  no active plugin declares: the handlers still run, but a typo in a
  handler's hook name would silently never run, and this is where a
  reader learns the name is not declared."
  [reg hook]
  (when (suspect? reg hook)
    (def warned (get reg :hooks/warned))
    (unless (in warned hook)
      (put warned hook true)
      (eprintf "warning: hook %q is fired but no active plugin declares it (:hooks in the manifest) — handlers registered for it run, and a typo in the name never will"
               hook))))

(defn- forget-order!
  {:params [@{:keyword :any} :keyword] :ret :nil}
  "Drop the cached order of `hook`: a handler came or went."
  [reg hook]
  (when-let [cache (get reg :hooks/cache)]
    (put cache hook nil))
  nil)

(defn add!
  {:params [@{:keyword :any} :keyword (or :function :cfunction) :any]
   :ret HookHandler
   :throws [:string]}
  ``Register a synchronous handler for a hook:

      (hooks/add! reg :after-start
        (fn [boot] (print "up"))
        :after :void.core/started :name :banner)

  Options: :after / :before (a name or a list of names — one of the
  hook's `lifecycle-anchors` or another handler of the same hook; a
  handler with neither runs after the placed ones, by name), :name
  (keyword, default a gensym; re-adding the same name replaces the
  handler — REPL-friendly), :plugin (source attribution for errors
  and the plugin whose `:requires` bound its edges), :doc. A `:phase`
  is an error: it was removed in ADR-0051. Returns the entry.``
  [reg hook f & kvs]
  (unless (keyword? hook)
    (errorf "hook name must be a keyword, got %q" hook))
  (unless (util/callable? f)
    (errorf "hook %q: handler must be a function, got %q" hook f))
  (when (odd? (length kvs))
    (errorf "hook %q: expected key-value option pairs" hook))
  # nil-valued options vanish in the table constructor, so callers may
  # pass e.g. :plugin nil to mean "unattributed"
  (def opts (table ;kvs))
  (when (in opts :phase)
    (errorf "hook %q: :phase was removed in ADR-0051 — place the handler with :after/:before one of the hook's anchors or another handler"
            hook))
  (eachk k opts
    (unless (in allowed-handler-opts k)
      (errorf "hook %q: unknown option %q (allowed: %s)"
              hook k (util/names-str (keys allowed-handler-opts)))))
  (def name (get opts :name (keyword (gensym))))
  (unless (keyword? name)
    (errorf "hook %q: :name must be a keyword, got %q" hook name))
  (each side [:after :before]
    (def [ok e] (protect (order/edges (opts side))))
    (unless ok (errorf "hook %q handler %q: %q: %s" hook name side e)))
  (def entry
    (freeze {:hook hook :name name :fn f
             :after (opts :after) :before (opts :before)
             :plugin (get opts :plugin) :doc (get opts :doc)}))
  (def handlers (or (get reg hook) (let [t @{}] (put reg hook t) t)))
  (put handlers name entry)
  (forget-order! reg hook)
  entry)

(defn remove!
  {:params [@{:keyword :any} :keyword :keyword]
   :ret HookHandler?}
  "Remove the handler registered under `name` for `hook`; returns the
  removed entry or nil."
  [reg hook name]
  (when-let [entry (get-in reg [hook name])]
    (put (reg hook) name nil)
    (forget-order! reg hook)
    entry))

(defn- order-of
  {:params [@{:keyword :any} :keyword] :ret [HookHandler] :throws [:string]}
  "The handlers of one hook in order, anchors dropped — sorted by
  their edges around the hook's `lifecycle-anchors`."
  [reg hook]
  (tuple
    ;(filter |(nil? ($ :anchor))
             (order/sort (values (get reg hook {}))
                         {:anchors (get lifecycle-anchors hook [])
                          :what (string/format "hook %q handler" hook)
                          :owner :void/core
                          :requires (get reg :hooks/requires)
                          :unplaced :last}))))

(defn handlers
  {:params [@{:keyword :any} :keyword?]
   :ret [HookHandler]
   :throws [:string]}
  ``Handlers for one hook (or, without `hook`, for every hook, hook by
  hook in name order), in execution order: placed by their
  `:after`/`:before` edges around the hook's anchors, the unplaced
  after them by name. An edge to a name the hook does not have, to a
  handler of a plugin the contributor does not require, or a cycle
  throws — bootstrap asks for every hook's order once, so that is a
  boot error. The order is cached per hook until `add!`/`remove!`
  touches it.``
  [reg &opt hook]
  (if (nil? hook)
    (tuple ;(mapcat |(handlers reg $) (sorted (keys reg))))
    (let [cache (get reg :hooks/cache)]
      (or (and cache (in cache hook))
          (let [ordered (order-of reg hook)]
            (when cache (put cache hook ordered))
            ordered)))))

(defn- fail
  {:params [HookHandler
            :any]
   :ret :never :throws [:string]}
  "The error for a handler that threw: the hook, the handler's name,
  its plugin when known, and the throw's text."
  [entry e]
  (errorf "hook %q handler %q%s failed: %s"
          (entry :hook) (entry :name)
          (if-let [p (entry :plugin)] (string/format " (plugin %q)" p) "")
          (if (string? e) e (describe e))))

(defn run!
  {:params [@{:keyword :any} :keyword :any] :ret :number :throws [:string]}
  "Run every handler of `hook` in order on the current fiber, passing
  `args` to each. Fail-fast: the first handler error aborts the run
  with the handler and plugin named. Returns the number of handlers
  run."
  [reg hook & args]
  (warn-undeclared! reg hook)
  (var n 0)
  (each entry (handlers reg hook)
    (def [ok e] (protect ((entry :fn) ;args)))
    (unless ok (fail entry e))
    (++ n))
  n)

(defn run-protected!
  {:params [@{:keyword :any} :keyword :any] :ret [:string]}
  "Like `run!`, but a handler error never stops the remaining handlers
  — for teardown paths (:before-stop/:after-stop must not block a
  shutdown). Returns the tuple of error messages (empty on success)."
  [reg hook & args]
  (warn-undeclared! reg hook)
  (def errors @[])
  (each entry (handlers reg hook)
    (def [ok e] (protect ((entry :fn) ;args)))
    (unless ok
      (def [_ msg] (protect (fail entry e)))
      (array/push errors msg)))
  (tuple ;errors))
