# Types of void/core's values, named where they recur. The framework's own
# vocabulary, so no prefix.

# The error envelope: built and frozen by `errors/make` (and `errors/of`, which keeps a
# foreign dictionary's own keys, hence open); `:status` and `:http/status` only when
# the kind has one.
(def VoidError :typedef
  {:void/error :keyword :message :string? :data {:any :any} :status :number? & r})

# An ambient declaration: the struct `system/ambient` returns, its cell a closure.
(def Ambient :typedef
  {:void.system/ambient :boolean :dyn :keyword :of :string
   :from :keyword? :component :keyword?
   :held (fn [] :any) :hold (fn [:any] :any)})

# A component definition: built by `system/component` from its allowed options only;
# a manifest stamps `:plugin` onto it.
(def Component :typedef
  {:key :keyword :deps [:keyword] :provides [:keyword] :doc :string? :plugin :keyword?
   :ambient Ambient?
   :config (or {:key :keyword & r} :nil)
   :start (fn [:any :any] :any)
   :stop (or (fn [:any] :any) :nil)
   :health (or (fn [:any] :any) :nil)})

# The system value: built by `system/init`; `attach-boot!` adds `:boot`, a failed
# `restart` `:restart-pending` — hence open.
(def System :typedef
  @{:components @{:keyword Component}
    :providers @{:keyword @[:keyword]}
    :resolution @{:keyword @{:keyword :keyword}}
    :order @[:keyword]
    :config {:keyword :any}
    :instances @{:keyword :any}
    :states @{:keyword (enum :running :stopped)}
    :boot Boot?
    :restart-pending (or @{:keyword :boolean} :nil)
    & r})

# A schema node: the struct `schema/normalize` builds (`:children` are nodes, or
# `[key node]` pairs under `:map`).
(def SchemaNode :typedef
  {:type :keyword :props {:any :any} :children [:any]})

# One validation error, pushed by `schema/check`: the path and code, plus the
# code's own keys (`:value`, `:expected`, `:min`, …).
(def SchemaError :typedef
  {:path [:any] :code :keyword & r})

# An extension point contract: what `extension/extension-point` freezes, from its
# allowed options only.
(def ExtensionPoint :typedef
  {:name :keyword
   :cardinality (enum :many :single :single-required)
   :schema SchemaNode?
   :schema-source :any
   :aliases [:keyword]
   :what :string?
   :key :keyword?
   :index (or :boolean (fn [:any] :any) :nil)
   :reduce (or (fn [:any] :any) :nil)
   :validate (or (fn [:any] :any) :nil)
   :conformance :string?
   :doc :string?})

# One contribution to a point, attributed: built by `extension/resolve` (and boot's
# config sources) from a manifest's `:contributes`.
(def Contribution :typedef
  {:plugin :keyword :value :any})

# A resolved extension point, one entry of the boot's `:extensions`: built by
# `extension/resolve`.
(def Extension :typedef
  @{:owner :keyword :point ExtensionPoint :contributions [Contribution] :resolved :any})

# A plugin manifest: the struct `manifest/manifest` freezes (and `defplugin` refreezes
# with the module's queued points and contributions).
(def Manifest :typedef
  {:name :keyword
   :doc :string?
   :void-api :number
   :version :string
   :requires {:keyword (or :boolean :string)}
   :config-key :keyword?
   :config-schema :any
   :config-defaults (or {:keyword :any} :nil)
   :when (or (fn [:any] :boolean) :nil)
   :components [Component]
   :contributes {:keyword [:any]}
   :extension-points {:keyword ExtensionPoint}
   :hooks [:keyword]
   :on-load (or (fn [:any] :any) :nil)
   :source :string?})

# Where a config value came from: the struct `config/load` records per layer.
(def ConfigSource :typedef
  {:layer (enum :defaults :file :env :cli)
   :plugin :any :path :string? :var :string? :prefix :string? :arg :string?})

# The loaded config: the table `config/load` returns.
(def LoadedConfig :typedef
  @{:profile :keyword
    :values @{:any :any}
    :provenance @{:any @[ConfigSource]}
    :layers @[ConfigSource]})

# The resolved deployment: the struct `deploy/resolve!` installs.
(def Deployment :typedef
  {:shape (enum :single :fleet) :reason :string})

# One row of the store survey: `deploy/survey` merges a declaration's `:ask` answer
# into a table (open: the answer is the declaration's), or records a throwing `:ask`
# as a struct.
(def StoreSurvey :typedef
  (or @{:name :keyword :what :string
        :shared? (or :boolean (enum :by-design) :nil)
        :store :keyword? :why :string? :replacement :string? & r}
      {:name :keyword :what :string :shared? (enum :unknown) :error :string}))

# A hook handler entry: the struct `hooks/add!` freezes.
(def HookHandler :typedef
  {:hook :keyword :name :keyword :fn (or :function :cfunction)
   :phase :number :plugin :any :doc :string?})

# The boot value: the table `boot/bootstrap*` assembles; `start!` adds `:stores`,
# `void/run!` `:stop-chan` and `:stop-reason` — hence open.
(def Boot :typedef
  @{:phase (enum :validated :ready :stopped)
    :profile :keyword
    :deploy Deployment
    :plugins [:keyword]
    :manifests @{:keyword Manifest}
    :active [:keyword]
    :inactive [:keyword]
    :config LoadedConfig?
    :extensions @{:keyword Extension}
    :hooks @{:keyword @{:keyword HookHandler}}
    :system System?
    :stores (or @[StoreSurvey] :nil)
    & r})

# A connection pool: the table `pool/make` builds.
(def Pool :typedef
  @{:connect :function :close :function
    :reusable? (fn [:any] :boolean)
    :validate (or (fn [:any] :any) :nil)
    :name :string :timeout-kind :keyword
    :size :number :checkout-timeout :number
    :idle @[:any] :waiters @[PoolWaiter]
    :created :number :in-use :number :closed :boolean
    :stats @{:keyword :number}})

# One parked checkout: the record `pool/await` pushes onto the pool's `:waiters`.
(def PoolWaiter :typedef
  @{:chan :abstract :live :boolean :value :any :retry :boolean})

# A log record: the table `log/emit` builds — the context and the call's key-value
# pairs are added to it, hence open.
(def LogRecord :typedef
  @{:ts :number :level :keyword :ns :string :msg :any & r})

# A resolved handler binding: the struct `bind/resolve` returns.
(def Binding :typedef
  {:call (fn [& :any] :any) :no-reload :boolean :symbol :symbol?
   :name :symbol? :env :table? :what :string})

# A CLI command: a `:void.core/cli` contribution, written by a plugin as data and read
# by `cli/parse` and the help renderers.
(def Command :typedef
  {:name :keyword
   :fn (or :function :cfunction :symbol)
   :doc :string?
   :args (or @[:string] [:string] :nil)
   :flags (or {:string {:key :keyword :type :keyword? :doc :string? & r}} :nil)
   :needs (or @[:keyword] [:keyword] :nil)
   :read-only? :boolean?
   & r})

# A metadata key declaration: the struct `meta/declare-key` freezes.
(def MetaDeclaration :typedef
  {:key :keyword
   :merge (enum :replace :concat :deep-merge :restrict)
   :schema :any
   :doc :string?
   :allow? (or (fn [:any :any] :boolean) :nil)})

# Merged metadata with its provenance: the table `meta/merge-layers` returns.
(def MergedMeta :typedef
  @{:value @{:keyword :any}
    :provenance @{:keyword @[{:source :any :value :any}]}
    :errors [:string]
    :warnings [:string]})

# One entry of a package's own text table: a string, or English plural forms. Read by
# `text/render`.
(def TextEntry :typedef
  (or :string {:other :string :one :string? & r}))
