### void/core/hooks — lifecycle hooks.
###
### Synchronous and ordered: handlers are registered per hook name
### (:config-loaded, :before-start, ... or any custom keyword), sorted by
### :phase then :name and run on the caller's fiber — bootstrap wiring,
### not messaging. Application events (:user/created ...) are void/bus's
### business (ADR-0012); the in-process pub/sub that used to live here
### had no consumer left.
###
### A hook is *declared* by the plugin that fires it — `:hooks [...]` in
### its manifest — so a registry built by bootstrap knows every name
### that can ever run. Firing an undeclared name is a warning rather
### than an error (a hook is a notification, and a typo in it must not
### take the process down), and a handler registered for one is
### reported at boot with a did-you-mean, the way extension points are.

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(defn- names-str [names]
  (string/join (map |(string/format "%q" $) (sorted names)) " "))

(def lifecycle-hooks
  "Hooks fired by the core lifecycle itself: :config-loaded,
  :before-start and :after-start by plugin/start!, :before-stop and
  :after-stop by plugin/shutdown!. Every handler receives the boot
  value. Any other keyword is a valid custom hook."
  [:config-loaded :before-start :after-start :before-stop :after-stop])

# -- hook registry -------------------------------------------------------

(def- allowed-handler-opts {:phase true :name true :plugin true :doc true})

(defn namespace-of
  "The namespace of a hook name: :void.http/listening -> \"void.http\";
  a bare :after-start -> nil."
  [hook]
  (def s (string hook))
  (when-let [slash (string/find "/" s)]
    (string/slice s 0 slash)))

(defn owner-namespace
  "The hook namespace a plugin name owns: :void/http -> \"void.http\",
  :shop/app -> \"shop.app\"."
  [plugin]
  (string/replace-all "/" "." (string plugin)))

(defn registry
  ``Create an empty hook registry: hook name -> handler name -> entry.

  Bootstrap builds one with two sets, and a test's bare
  `(hooks/registry)` has neither and runs anything silently:

    declared  the hook names that can be fired through this registry —
              the lifecycle hooks plus every `:hooks` an active plugin
              declares
    owners    the active plugins (names), whose hook namespaces are
              thereby *owned*: :void/http owns :void.http/*

  A name is suspect when its namespace is owned and nobody declared
  it — :void.http/listenng with void/http active. A name in a namespace
  nobody owns (:void.dev/reloaded in a composition without void/dev)
  is a hook of a plugin that is simply not here, and neither firing it
  nor handling it is a mistake. The sets live on the table's prototype
  so that `keys`/`values`/`each` over the registry still see hooks alone.``
  [&opt declared owners]
  (if (and (nil? declared) (nil? owners))
    @{}
    (table/setproto @{} @{:hooks/declared (tabseq [h :in (or declared [])] h true)
                          :hooks/owned (tabseq [o :in (or owners [])]
                                         (owner-namespace o) true)
                          :hooks/warned @{}})))

(defn declared?
  "Is `hook` declared on this registry — or is the registry undeclared,
  in which case every name is. Lifecycle hooks always are."
  [reg hook]
  (def d (get reg :hooks/declared))
  (or (nil? d) (in d hook) (not (nil? (index-of hook lifecycle-hooks)))))

(defn suspect?
  "An undeclared hook in a namespace an active plugin owns — the
  shape of a typo, or of a plugin firing what it never declared."
  [reg hook]
  (and (not (declared? reg hook))
       (let [ns (namespace-of hook)]
         (and ns (in (get reg :hooks/owned {}) ns)))))

(defn- warn-undeclared! [reg hook]
  (when (suspect? reg hook)
    (def warned (get reg :hooks/warned))
    (unless (in warned hook)
      (put warned hook true)
      (eprintf "warning: hook %q is fired but no active plugin declares it (:hooks in the manifest) — handlers registered for it run, and a typo in the name never will"
               hook))))

(defn add!
  ``Register a synchronous handler for a hook:

      (hooks/add! reg :after-start
        (fn [boot] (print "up"))
        :phase 500 :name :banner)

  Options: :phase (int, default 1000 — lower runs earlier), :name
  (keyword, default a gensym; re-adding the same name replaces the
  handler — REPL-friendly), :plugin (source attribution for errors),
  :doc. Returns the entry.``
  [reg hook f & kvs]
  (unless (keyword? hook)
    (errorf "hook name must be a keyword, got %q" hook))
  (unless (callable? f)
    (errorf "hook %q: handler must be a function, got %q" hook f))
  (when (odd? (length kvs))
    (errorf "hook %q: expected key-value option pairs" hook))
  # nil-valued options vanish in the table constructor, so callers may
  # pass e.g. :plugin nil to mean "unattributed"
  (def opts (table ;kvs))
  (eachk k opts
    (unless (in allowed-handler-opts k)
      (errorf "hook %q: unknown option %q (allowed: %s)"
              hook k (names-str (keys allowed-handler-opts)))))
  (def name (get opts :name (keyword (gensym))))
  (unless (keyword? name)
    (errorf "hook %q: :name must be a keyword, got %q" hook name))
  (def phase (get opts :phase 1000))
  (unless (and (number? phase) (= phase (math/trunc phase)))
    (errorf "hook %q: :phase must be an integer, got %q" hook phase))
  (def entry
    (freeze {:hook hook :name name :fn f :phase phase
             :plugin (get opts :plugin) :doc (get opts :doc)}))
  (def handlers (or (get reg hook) (let [t @{}] (put reg hook t) t)))
  (put handlers name entry)
  entry)

(defn remove!
  "Remove the handler registered under `name` for `hook`; returns the
  removed entry or nil."
  [reg hook name]
  (when-let [entry (get-in reg [hook name])]
    (put (reg hook) name nil)
    entry))

(defn handlers
  "Handlers for one hook (or, without `hook`, for every hook), in
  execution order: sorted by :phase, ties broken by :name."
  [reg &opt hook]
  (def entries
    (if hook
      (values (get reg hook {}))
      (mapcat values (values reg))))
  (sorted-by (fn [e] [(e :phase) (string (e :hook)) (string (e :name))])
             entries))

(defn- fail [entry e]
  (errorf "hook %q handler %q%s failed: %s"
          (entry :hook) (entry :name)
          (if-let [p (entry :plugin)] (string/format " (plugin %q)" p) "")
          (if (string? e) e (describe e))))

(defn run!
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
