### void/core/boot — the phases, the lifecycle and the REPL tools.
###
### Owns the boot value and everything that produces or reads it:
### phases 1-5 of bootstrap (load -> config -> conditional -> extension
### resolution -> graph), each collecting its errors and failing in one
### batch that names the source plugin; phases 6-7 (`start!`: the
### logger, the lifecycle hooks, the component graph, the deploy
### survey) and `shutdown!`; `dry-run`, phases 1-5 alone as CI's
### validation of a composition; the two ways to name a boot without
### being handed one — `running-boot`, the one this process has up,
### and `last-boot`, the most recent bootstrap, which is the REPL's
### fallback and nothing else's; and the REPL tools that read a boot —
### `extension`, `health`, `inspect`, `why`. The seam is here because
### this is the only module that sequences the others: semver answers
### compatibility, manifest says what a plugin is, extension resolves
### the points — and boot is where they meet, in order, with the
### config and the component graph. Nothing below it knows a boot
### exists.

(import ./init :as core)
(import ./system :as system)
(import ./config :as config)
(import ./hooks :as hooks)
(import ./log :as log)
(import ./deploy :as deploy)
(import ./util :as util)
(import ./semver :as semver)
(import ./manifest :as manifest)
(import ./extension :as extension)

# -- bootstrap phases ----------------------------------------------------

(def- allowed-boot-opts {:plugins true :profile true :config true})

(defn- checked
  "Throw the batched phase errors, if any. `sources` (plugin name ->
  :source file) adds a `plugin files:` footer for the plugins the
  errors mention, pointing at the defining files."
  [phase errors &opt sources]
  (unless (empty? errors)
    (def files
      (seq [name :in (sorted (keys (or sources {})))
            :when (some |(string/find (string/format "%q" name) $) errors)]
        (string/format "%q -> %s" name (in sources name))))
    (errorf "plugin bootstrap failed at phase %q:\n  - %s%s"
            phase (string/join errors "\n  - ")
            (if (empty? files)
              ""
              (string "\n  plugin files:\n    " (string/join files "\n    "))))))

(defn- load-manifests
  "Phase 1 (load): resolve :plugins entries — manifest values, keywords
  looked up in manifest-registry, or module paths to require."
  [entries errors]
  (def out @[])
  (def seen @{})
  (each entry entries
    (def m
      (cond
        (and (dictionary? entry) (keyword? (get entry :name))) entry

        (keyword? entry)
        (or (get manifest/manifest-registry entry)
            (do (array/push errors (string/format "plugin %q is not registered — require its module first or pass its manifest" entry))
                nil))

        (or (string? entry) (symbol? entry))
        (let [[ok env] (protect (require (string entry)))]
          (if ok
            (or (get-in env ['manifest :value])
                (do (array/push errors (string/format "module %q does not export a manifest (use defplugin)" entry))
                    nil))
            (do (array/push errors (string/format "cannot load plugin module %q: %s" entry (util/err-str env)))
                nil)))

        (do (array/push errors (string/format "invalid :plugins entry %q — expected a manifest, a registered plugin keyword or a module path" entry))
            nil)))
    (when m
      (if (in seen (m :name))
        (array/push errors (string/format "plugin %q appears twice in :plugins" (m :name)))
        (do (put seen (m :name) true)
            (array/push out m)))))
  out)

(defn- check-compat
  "Phase 1 (load): :void-api compatibility and :requires (semver)."
  [ms errors]
  (def versions @{:void/core core/version})
  (each m ms (put versions (m :name) (m :version)))
  (each m ms
    (unless (= (m :void-api) core/void-api)
      (array/push errors
                  (string/format "plugin %q targets :void-api %d, this void/core implements %d"
                                 (m :name) (m :void-api) core/void-api)))
    (each r (sorted (keys (m :requires)))
      (def c (get-in m [:requires r]))
      (cond
        (nil? (versions r))
        (array/push errors
                    (string/format "plugin %q requires %q, which is not in the plugin list"
                                   (m :name) r))
        (and (string? c) (not (semver/satisfies? (versions r) c)))
        (array/push errors
                    (string/format "plugin %q requires %q %s, but version %s is loaded"
                                   (m :name) r c (versions r)))))))

(defn- run-on-load
  "Phase 1 (load), last step: call every manifest's :on-load with
  {:name :manifest :plugins :profile} — codegen and the like, before
  any config is read. A throwing hook is one batched error naming
  the plugin."
  [ms profile errors]
  (def names (tuple ;(map |($ :name) ms)))
  (each m ms
    (when-let [f (m :on-load)]
      (def [ok e] (protect (f {:name (m :name) :manifest m
                               :plugins names :profile profile})))
      (unless ok
        (array/push errors
                    (string/format "plugin %q: :on-load failed: %s" (m :name) (util/err-str e)))))))

(def core-slices
  ``The config slices void/core itself reads — [:log] and [:deploy] —
  in the shape `load-boot-config` derives from every plugin manifest's
  :config-key / :config-schema: the built-in manifest's entries. They
  are declared here rather than in a manifest in the :plugins list
  because the core is not a plugin there: its extension points are
  injected by extension/declared-points and its version is seeded by
  check-compat, and 8.5 (boot as a dependency) left it that way: the
  boot reaches a component through `:deps [:void/boot]`, which needs
  no :void/core entry in every lock file and plugin list.
  Both slices are validated by the same config/validate call as every
  plugin's, in phase 2, before anything starts (ADR-0046).``
  [{:plugin :void/core :key log/config-key :schema log/Config}
   {:plugin :void/core :key deploy/config-key :schema deploy/Config}])

(defn- manifest-slice
  "A manifest's config slice, {:plugin :key :schema :defaults}, or nil
  for a plugin without a :config-key."
  [m]
  (when-let [k (m :config-key)]
    {:plugin (m :name) :key k
     :schema (m :config-schema) :defaults (m :config-defaults)}))

(defn- config-sources
  ``Phase 2 (config): the :void.core/config-source contributions of
  every loaded manifest, resolved through the point's own contract
  (schema, unique :name, :priority order) into the functions
  config/load tries first for a {:secret NAME} reference. Every loaded
  plugin, not the active ones: :when reads the config these sources
  help build, so activation cannot gate them — a source from a plugin
  its :when later switches off has been consulted once, at load. A bad
  contribution is a phase-2 error naming the plugin.``
  [ms errors]
  (def name :void.core/config-source)
  (def cs (seq [m :in (sorted-by |($ :name) ms)
                c :in (get-in m [:contributes name] [])]
            {:plugin (m :name) :value c}))
  (def [resolved point-errors]
    (extension/resolve-point name (extension/core-points name) cs))
  (array/concat errors point-errors)
  (map |($ :fn) (or resolved [])))

(defn- load-boot-config
  "Phase 2 (config): layered load with plugin defaults, secret
  references resolved through the contributed config sources, then
  batch validation of every slice — the core's and each manifest's
  :config-key — against its schema, in one config/validate call."
  [ms opts errors]
  (def slices (array/concat (array ;core-slices) ;(keep manifest-slice ms)))
  (def copts (merge-into @{} (get opts :config {})))
  (when (get copts :defaults)
    (array/push errors ":config :defaults is reserved — plugin defaults come from manifests (:config-defaults)"))
  (put copts :defaults
       (seq [s :in slices :when (s :defaults)]
         {:plugin (s :plugin) :key (s :key) :defaults (s :defaults)}))
  (put copts :profile (get opts :profile :dev))
  # explicit :secret-sources in the options are tried before the
  # contributed ones — what the caller wrote beats what a plugin adds
  (put copts :secret-sources
       (array/concat (array ;(get copts :secret-sources []))
                     ;(config-sources ms errors)))
  (def [ok cfg] (protect (config/load copts)))
  (if ok
    (do
      # a data schema goes through as it is: config/validate closes its
      # maps and reports each failure with the layer that set the value
      (array/concat errors (config/validate cfg slices))
      cfg)
    (do (array/push errors (util/err-str cfg))
        nil)))

(defn- split-active
  "Phase 3 (conditional): evaluate :when against the config values; an
  inactive plugin contributes neither components nor contributions. An
  active plugin requiring a deactivated one is an error."
  [ms cfg errors]
  (def active @[])
  (def inactive @[])
  (each m ms
    (if-let [w (m :when)]
      (let [[ok r] (protect (w (cfg :values)))]
        (cond
          (not ok)
          (array/push errors (string/format "plugin %q: :when failed: %s" (m :name) (util/err-str r)))
          r (array/push active m)
          (array/push inactive m)))
      (array/push active m)))
  (def active? (tabseq [m :in active] (m :name) true))
  (def loaded? (tabseq [m :in ms] (m :name) true))
  (each m active
    (each r (sorted (keys (m :requires)))
      (when (and (in loaded? r) (not (in active? r)))
        (array/push errors
                    (string/format "plugin %q requires %q, but it was deactivated by its :when condition"
                                   (m :name) r)))))
  [active inactive])

(defn- warn-component-schemas
  "The deprecation notice for `:config :schema` on a component
  (ADR-0046), once per plugin per boot, naming the components: the
  schema is still honoured — system/init validates it through the same
  config/validate — but a plugin's slice belongs in the manifest's
  :config-schema, where phase 2 checks it with every other slice, and
  a component repeating the manifest's schema validates the slice
  twice."
  [active]
  (each m active
    (def keyed
      (seq [c :in (m :components) :when (get-in c [:config :schema])] (c :key)))
    (unless (empty? keyed)
      (def repeated?
        (and (m :config-schema)
             (all |(= (m :config-key) (get-in $ [:config :key]))
                  (filter |(get-in $ [:config :schema]) (m :components)))))
      (log/warn (if repeated?
                  "component :config :schema is deprecated — the manifest's :config-schema already validates the slice, drop the component's"
                  "component :config :schema is deprecated — move the schema to the manifest's :config-schema, where phase 2 validates it with every other slice")
                :ns "void.core.boot" :plugin (m :name) :components keyed))))

(defn- build-system
  "Phase 5 (graph): components of active plugins -> system/init (dups,
  missing deps, interface conflicts, cycles, deprecated component
  config schemas). Every :provides interface must be declared via
  :void.core/interface."
  [active extensions cfg errors]
  (warn-component-schemas active)
  (def comps (mapcat |($ :components) active))
  (def declared (or (get-in extensions [:void.core/interface :resolved]) {}))
  (each c comps
    (each iface (c :provides)
      (unless (in declared iface)
        (array/push errors
                    (string/format "component %q (plugin %q) provides undeclared interface %q — contribute a declaration to :void.core/interface"
                                   (c :key) (c :plugin) iface)))))
  (when (empty? errors)
    (def [ok sys] (protect (system/init comps (cfg :values))))
    (if ok
      sys
      (do (array/push errors (util/err-str sys))
          nil))))

(var last-boot
  ``The boot value of the most recent bootstrap/start! in this process,
  and nothing more: the fallback subject of the zero-argument REPL
  tools (inspect, why, extension) when nothing is running.

  Code that needs "the boot in force" wants `running-boot`. The
  difference is the reason this binding is named the way it is: the
  most recent bootstrap is not the running one under a test suite
  (test bootstraps are untracked on purpose) and not the right one in
  any process that bootstraps twice.``
  nil)

(defn running-boot
  ``The boot this process is running — what `plugin/start!` attached and
  has not shut down, or the `:void/boot` dyn where a scope overrides
  it. Nil when nothing is up.

  This is the reader for a package's module-level functions: the hook
  registry an event fires on, a resolved extension point, a config
  slice. A component does not use it — it declares `:deps [:void/boot]`
  and is handed the boot of *its* system, which is the same value here
  and a stricter statement about where it came from.``
  []
  (system/current system/running-boot))

(defn- build-hooks
  ``Fold the :void.core/hooks contributions into a hooks/registry, each
  handler attributed to its source plugin. The registry is declared
  with every hook the active plugins say they fire (plus the lifecycle
  hooks) and owned by the active plugins' namespaces; a handler for a
  suspect name — undeclared, in a namespace an active plugin owns — is
  reported here with a did-you-mean, since it would otherwise wait
  forever. A handler for an absent plugin's hook is not suspect.``
  [active extensions]
  (def declared (tabseq [h :in hooks/lifecycle-hooks] h true))
  (each m active
    (each h (get m :hooks []) (put declared h true)))
  (def reg (hooks/registry (keys declared) (map |($ :name) active)))
  (each c (get-in extensions [:void.core/hooks :contributions] [])
    (def v (c :value))
    (when (hooks/suspect? reg (v :hook))
      (eprintf "warning: plugin %q registers a handler for hook %q, which no active plugin declares — it will never run%s"
               (c :plugin) (v :hook) (util/suggest (v :hook) (keys declared))))
    (hooks/add! reg (v :hook) (v :fn)
                :phase (get v :phase 1000)
                :name (get v :name)
                :doc (get v :doc)
                :plugin (c :plugin)))
  reg)

(defn- bootstrap*
  "Phases 1-5 in order, each `checked` before the next runs on its
  output; the boot value is assembled at the end and, with `track?`,
  becomes `last-boot`. `bootstrap` tracks unless told otherwise,
  `start!` always does, `dry-run` never."
  [opts track?]
  (unless (dictionary? opts)
    (errorf "bootstrap expects an options dictionary, got %q" opts))
  (eachk k opts
    (unless (in allowed-boot-opts k)
      (errorf "bootstrap: unknown option %q (allowed: %s)"
              k (util/names-str (keys allowed-boot-opts)))))
  (def profile (get opts :profile :dev))
  (def errors @[])

  (def ms (load-manifests (get opts :plugins []) errors))
  (def sources (tabseq [m :in ms :when (m :source)] (m :name) (m :source)))
  (check-compat ms errors)
  (when (empty? errors)
    (run-on-load ms profile errors))
  (checked :load errors sources)

  (def cfg (load-boot-config ms opts errors))
  # the deployment is resolved with the config and travels on the boot:
  # `dry-run` and `void deploy check` need the shape without starting
  # anything, and a bad [:deploy :shape] is a config error like any other
  (def dep (deploy/resolve! (if cfg (cfg :values) {}) profile))
  (checked :config errors sources)

  # the profile is reachable from a :when as (dyn :void/profile), the
  # same way config files already see it (config/load-file) — a plugin
  # that only belongs in some profiles (void/dev) deactivates itself
  (def [active inactive]
    (with-dyns [:void/profile profile]
      (split-active ms cfg errors)))
  (checked :conditional errors sources)

  (def extensions (extension/resolve active ms errors))
  (checked :extension-resolution errors sources)

  (def sys (build-system active extensions cfg errors))
  (checked :graph errors sources)

  (def boot
    @{:phase :validated
      :profile profile
      :deploy dep
      :plugins (tuple ;(map |($ :name) ms))
      :manifests (tabseq [m :in ms] (m :name) m)
      :active (tuple ;(map |($ :name) active))
      :inactive (tuple ;(map |($ :name) inactive))
      :config cfg
      :extensions extensions
      :hooks (build-hooks active extensions)
      :system sys})
  (when track?
    (set last-boot boot))
  boot)

(defn bootstrap
  ``Run bootstrap phases 1-5 (load -> config -> conditional ->
  extension resolution -> graph) and return the boot value — nothing is
  started yet. Any error stops the run at its phase with the full batch
  of failures for that phase.

  Options:
    :plugins  manifests, registered plugin keywords or module paths
    :profile  :dev (default), :test, :prod, ...
    :config   options forwarded to config/load (:dir :files :env :cli
              ...); :defaults is reserved for manifest
              :config-defaults

  The boot value is plain data: :phase :profile :deploy :plugins
  :manifests :active :inactive :config :extensions :hooks :system.
  With a truthy
  `untracked` the boot is not recorded as the REPL tools' default
  subject (test bootstraps).``
  [opts &opt untracked]
  (bootstrap* opts (not untracked)))

# -- lifecycle -----------------------------------------------------------

(defn start!
  ``Phases 6-7: run the :config-loaded and :before-start hooks, start
  the component graph in dependency order, mark the boot :ready, run
  the :after-start hooks (see hooks/lifecycle-hooks; every handler
  receives the boot value), then survey the composition's stores
  against `[:deploy :shape]` — under `:fleet` a store living in one
  process's heap stops the boot with every violation in one error
, and the survey is left on the boot as :stores. Accepts a
  boot value from `bootstrap` or bootstrap options. Returns the boot
  value.``
  [boot-or-opts]
  (def boot (if (get boot-or-opts :system)
              boot-or-opts
              (bootstrap* boot-or-opts true)))
  # the logger comes up first: the [:log] slice (validated in phase 2
  # as one of `core-slices`) + profile pick the built-in sink,
  # contributed sinks/serializers install alongside
  (log/configure! (get-in boot [:config :values log/config-key]) (boot :profile))
  (when-let [sinks (get-in boot [:extensions :void.core/log-sink :resolved])]
    (unless (empty? sinks)
      (log/set-sinks! (array/concat (array ;(or (log/sinks) []))
                                    ;(map |($ :fn) sinks)))))
  (log/set-serializers!
    (or (get-in boot [:extensions :void.core/log-serializer :resolved]) {}))
  # from here this boot is the one in force: components asking for
  # `:deps [:void/boot]` get it, and module-level code reads it through
  # plugin/running-boot. Before the hooks, because a :config-loaded
  # handler is already code of the composition being started
  (system/attach-boot! (boot :system) boot)
  (hooks/run! (boot :hooks) :config-loaded boot)
  (hooks/run! (boot :hooks) :before-start boot)
  (system/start (boot :system))
  (put boot :phase :ready)
  # a failure past this line — an :after-start hook, the deploy check —
  # happens with every component already :running, and the error is
  # about to escape to a caller who will exit: stop the system and
  # flush the logger before it does, or the sockets, pools and workers
  # it survived keep running with nobody left to stop them
  (try
    (do
      (hooks/run! (boot :hooks) :after-start boot)
      # last, because it asks the stores that are now resolved — including
      # the ones a plugin resolves in an :after-start hook of its own
      # (void/security's limiter). Under [:deploy :shape] :fleet a store
      # living in one process's heap stops the boot here, with every
      # violation in one error
      (put boot :stores (deploy/check! boot)))
    ([e f]
      (try (system/stop (boot :system)) ([_]))
      (system/detach-boot! (boot :system))
      (put boot :phase :stopped)
      (log/close!)
      (propagate e f)))
  boot)

(defn shutdown!
  "Run the :before-stop hooks, stop the system in reverse dependency
  order — each component's :stop under a deadline of `timeout` seconds
  (default 5); a hung stop is cancelled and reported instead of
  blocking shutdown — then run the :after-stop hooks. Stop hooks are
  protected: a failing handler is reported on stderr but never blocks
  the shutdown. Returns the boot value."
  [boot &opt timeout]
  (default timeout 5)
  (each e (hooks/run-protected! (boot :hooks) :before-stop boot)
    (eprint e))
  (system/stop (boot :system) timeout)
  (put boot :phase :stopped)
  (each e (hooks/run-protected! (boot :hooks) :after-stop boot)
    (eprint e))
  # the :after-stop handlers are still code of this composition, so the
  # boot stops being the one in force only once they have run
  (system/detach-boot! (boot :system))
  (log/close!)                    # stop async log writers
  boot)

(defn dry-run
  ``Phases 1-5 without starting anything — the full validation of a
  system configuration for CI: :void-api and :requires compatibility,
  config schemas, broken contributions, cardinality and :provides
  conflicts, dependency cycles. Throws with the batched error list on any
  failure; returns a summary report on success. Options as in
  `bootstrap`.``
  [opts]
  (def boot (bootstrap* opts false))
  {:ok true
   :profile (boot :profile)
   :deploy (boot :deploy)
   :plugins (boot :plugins)
   :active (boot :active)
   :inactive (boot :inactive)
   :components (tuple ;(get-in boot [:system :order] []))
   :extensions (tabseq [name :keys (boot :extensions)]
                 name {:owner (get-in boot [:extensions name :owner])
                       :contributions (length (get-in boot [:extensions name :contributions]))})})

# -- REPL tools ----------------------------------------------------------

(defn- pick-boot
  "The boot a REPL tool works on: the one given, else the one this
  process is running, else the most recent bootstrap, else an error
  saying nothing has been bootstrapped in this process."
  [boot]
  (or boot (running-boot) last-boot
      (error "no bootstrapped system — run plugin/bootstrap or plugin/start! first")))

(defn extension
  ``Resolved value of an extension point — what the point owner reads
  in its component's :start:

      (plugin/extension :void.core/cli)         # most recent boot
      (plugin/extension boot :void.core/cli)``
  [& args]
  (def [boot name]
    (case (length args)
      1 [nil (args 0)]
      2 args
      (error "usage: (extension point) or (extension boot point)")))
  (def b (pick-boot boot))
  (def e (get-in b [:extensions name]))
  (unless e
    (errorf "unknown extension point %q%s" name (util/suggest name (keys (b :extensions)))))
  (e :resolved))

(defn- check-value
  "One :void.core/health contribution's answer: what its :fn returns,
  or `{:status :down :reason <the throw>}` — a check that fails is a
  failure, never an exception out of the health endpoint."
  [c]
  (def [ok v] (protect ((c :fn))))
  (if ok v {:status :down :reason (if (string? v) v (describe v))}))

(defn health
  ``The health of a composition as data: every running component's
  `:health` folded together with every `:void.core/health`
  contribution, plus the aggregate.

      (plugin/health)        # most recent boot
      (plugin/health boot)

  `:down` anywhere is `:down` here; `:degraded` (what void/pressure
  reports while it sheds) is not down — a process refusing some
  requests on purpose is still the process a load balancer should
  keep. A health function that throws counts as down with the throw as
  its `:reason`: an endpoint that fails because a check failed fails
  exactly when something is already wrong.

  It lives here because it has two readers and neither owns it —
  void/obs-http answers `GET /health` with it and void/mcp publishes
  it as a resource. Both are projections; the fold is the core's.``
  [&opt boot]
  (def b (pick-boot boot))
  (def sys (get b :system))
  (def base (if sys (system/health sys) {:status :up :components {}}))
  (def checks
    (tabseq [c :in (get-in b [:extensions :void.core/health :resolved] [])]
      (c :name) (check-value c)))
  (def all (merge (base :components) checks))
  {:status (if (some |(= :down (get $ :status)) (values all)) :down :up)
   :components all})

(defn inspect
  ``Who registered what.

      (plugin/inspect)                    # plugin -> active? -> components -> contributions
      (plugin/inspect :void.core/cli)     # one point: owner, contributions with sources, resolved value
      (plugin/inspect boot)               # same, for an explicit boot value
      (plugin/inspect boot :void.core/cli)``
  [&opt a b]
  (def [boot sel]
    (cond
      (nil? a) [nil nil]
      (keyword? a) [nil a]
      [a b]))
  (def bt (pick-boot boot))
  (if sel
    (do
      (def e (get-in bt [:extensions sel]))
      (unless e
        (errorf "unknown extension point %q%s" sel (util/suggest sel (keys (bt :extensions)))))
      {:point sel
       :owner (e :owner)
       :doc (get-in e [:point :doc])
       :cardinality (get-in e [:point :cardinality])
       :schema (get-in e [:point :schema-source])
       :aliases (get-in e [:point :aliases])
       :contributions (e :contributions)
       :resolved (e :resolved)})
    (seq [name :in (sorted (keys (bt :manifests)))]
      (def m (get-in bt [:manifests name]))
      {:plugin name
       :version (m :version)
       :active (not (nil? (index-of name (bt :active))))
       :components (tuple ;(map |($ :key) (m :components)))
       :extension-points (tuple ;(sorted (keys (m :extension-points))))
       :contributes (tabseq [[p vs] :pairs (m :contributes)] p (length vs))})))

(defn why
  ``Why is a component in the graph, and who depends on it:

      (plugin/why :redis/pool)      # component: source plugin, deps, dependents
      (plugin/why :void/cache)      # interface: providers and the selected one
      (plugin/why boot :redis/pool)``
  [& args]
  (def [boot k]
    (case (length args)
      1 [nil (args 0)]
      2 args
      (error "usage: (why key) or (why boot key)")))
  (def bt (pick-boot boot))
  (def sys (bt :system))
  (cond
    (get-in sys [:components k])
    (do
      (def comp (get-in sys [:components k]))
      (def dependents @[])
      (eachp [c res] (sys :resolution)
        (eachp [ref rk] res
          (when (= rk k)
            (array/push dependents {:component c :via ref}))))
      {:key k
       :plugin (comp :plugin)
       :state (get-in sys [:states k] :not-started)
       :deps (get-in sys [:resolution k])
       :provides (comp :provides)
       :dependents (tuple ;(sorted-by |($ :component) dependents))})

    (get-in sys [:providers k])
    {:interface k
     :providers (tuple ;(get-in sys [:providers k]))
     :selected (get-in sys [:config k :impl])}

    (errorf "unknown component or interface %q%s"
            k (util/suggest k (keys (sys :components))))))
