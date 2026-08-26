(import ../void/core/system :as system)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat)))

# -- component definition validation ------------------------------------

(expect-error "missing :start" ":start"
  |(system/component :a :deps []))
(expect-error "unknown option" "unknown option"
  |(system/component :a :start (fn [d c] 1) :strat 2))
(expect-error "odd option count" "odd"
  |(system/component :a :start))
(expect-error "bad scope" ":scope"
  |(system/component :a :start (fn [d c] 1) :scope :global))
(expect-error "suspend without resume" ":resume"
  |(system/component :a :start (fn [d c] 1) :suspend (fn [i] i)))
(expect-error "non-keyword key" "keyword"
  |(system/component "a" :start (fn [d c] 1)))
(expect-error "bad :deps" ":deps"
  |(system/component :a :start (fn [d c] 1) :deps [:x "y"]))
(expect-error "bad :config spec" ":config"
  |(system/component :a :start (fn [d c] 1) :config {:schema nil}))

# -- basic lifecycle: order, config slice, dep instances ----------------

(def log @[])

(def sys
  (system/init
    [(system/component :config
       :config {:key :database}
       :start (fn [deps cfg]
                (array/push log [:start :config])
                {:db-host (get cfg :host)})
       :stop (fn [inst] (array/push log [:stop :config])))
     (system/component :db/pool
       :deps [:config]
       :start (fn [deps cfg]
                (array/push log [:start :db/pool])
                @{:config-dep (get deps :config)})
       :stop (fn [inst] (array/push log [:stop :db/pool])))]
    {:database {:host "localhost"}}))

(system/start sys)
(assert (= (freeze log) [[:start :config] [:start :db/pool]])
        "start follows dependency order")
(assert (= (get (system/instance sys :config) :db-host) "localhost")
        "config slice reaches :start")
(assert (= (get-in (system/instance sys :db/pool) [:config-dep :db-host]) "localhost")
        "dependency instance is passed to dependent")
(array/clear log)
(system/start sys)
(assert (empty? log) "start is idempotent for running components")
(system/stop sys)
(assert (= (freeze log) [[:stop :db/pool] [:stop :config]])
        "stop runs in reverse order")

# -- graph errors --------------------------------------------------------

(expect-error "missing dependency" "neither a component"
  |(system/init [(system/component :a :deps [:nope] :start (fn [d c] 1))]))

(expect-error "dependency cycle" "cycle"
  |(system/init [(system/component :a :deps [:b] :start (fn [d c] 1))
                 (system/component :b :deps [:c] :start (fn [d c] 1))
                 (system/component :c :deps [:a] :start (fn [d c] 1))]))

(def [dup-ok dup-err]
  (protect
    (system/init [(system/component :a :start (fn [d c] 1) :plugin :p1)
                  (system/component :a :start (fn [d c] 1) :plugin :p2)])))
(assert (not dup-ok) "duplicate key is an error")
(assert (and (string/find "duplicate" (string dup-err))
             (string/find ":p1" (string dup-err))
             (string/find ":p2" (string dup-err)))
        "duplicate error names the conflicting plugins")

# -- :provides interfaces ------------------------------------------------

(defn cache-comp [key plugin]
  (system/component key
    :provides [:void/cache]
    :plugin plugin
    :start (fn [d c] key)))

(def sys2
  (system/init
    [(cache-comp :memory-cache :void/memory)
     (system/component :user
       :deps [:void/cache]
       :start (fn [deps cfg] (deps :void/cache)))]))
(system/start sys2)
(assert (= (system/instance sys2 :user) :memory-cache)
        "single interface provider is auto-selected")
(assert (= (system/instance sys2 :void/cache) :memory-cache)
        "instance lookup works by interface")

(def [iface-ok iface-err]
  (protect
    (system/init [(cache-comp :memory-cache :void/memory)
                  (cache-comp :redis-cache :void/redis)
                  (system/component :user
                    :deps [:void/cache]
                    :start (fn [d c] nil))])))
(assert (not iface-ok) "two implementations without a config choice is an error")
(assert (and (string/find "provided by multiple" (string iface-err))
             (string/find ":memory-cache" (string iface-err))
             (string/find ":void/redis" (string iface-err)))
        "interface conflict lists candidates and their plugins")

(def sys3
  (system/init
    [(cache-comp :memory-cache :void/memory)
     (cache-comp :redis-cache :void/redis)
     (system/component :user
       :deps [:void/cache]
       :start (fn [deps cfg] (deps :void/cache)))]
    {:void/cache {:impl :redis-cache}}))
(system/start sys3)
(assert (= (system/instance sys3 :user) :redis-cache)
        "config {:impl ...} selects the interface implementation")

(expect-error "impl not a candidate" "candidates"
  |(system/init [(cache-comp :memory-cache :void/memory)
                 (cache-comp :redis-cache :void/redis)
                 (system/component :user :deps [:void/cache] :start (fn [d c] nil))]
                {:void/cache {:impl :missing}}))

(expect-error "conflict without a dependent" "provided by multiple"
  |(system/init [(cache-comp :memory-cache :void/memory)
                 (cache-comp :redis-cache :void/redis)]))

(def sys3b
  (system/init [(cache-comp :memory-cache :void/memory)
                (cache-comp :redis-cache :void/redis)]
               {:void/cache {:impl :memory-cache}}))
(system/start sys3b)
(assert (= (system/instance sys3b :void/cache) :memory-cache)
        "config choice resolves the conflict even with no dependent")

# -- restart: transitive dependents only --------------------------------

(def rlog @[])
(defn rcomp [key deps]
  (system/component key
    :deps deps
    :start (fn [d c] (array/push rlog [:start key]) (gensym))
    :stop (fn [i] (array/push rlog [:stop key]))))

(def sys4 (system/init [(rcomp :a []) (rcomp :b [:a]) (rcomp :c [:b]) (rcomp :d [])]))
(system/start sys4)
(def a-inst (system/instance sys4 :a))
(def d-inst (system/instance sys4 :d))
(array/clear rlog)
(system/restart sys4 :b)
(assert (= (freeze rlog) [[:stop :c] [:stop :b] [:start :b] [:start :c]])
        "restart stops and starts the component plus transitive dependents")
(assert (= (system/instance sys4 :a) a-inst) "dependency of restarted component untouched")
(assert (= (system/instance sys4 :d) d-inst) "unrelated component untouched")

(expect-error "restart unknown component" "unknown component"
  |(system/restart sys4 :nope))

# -- restart with :suspend/:resume --------------------------------------

(def slog @[])
(def sys5
  (system/init
    [(system/component :conn
       :start (fn [d c] (array/push slog :start-conn) (gensym)))
     (system/component :server
       :deps [:conn]
       :start (fn [deps cfg]
                (array/push slog :start-server)
                @{:conn (deps :conn)})
       :stop (fn [i] (array/push slog :stop-server))
       :suspend (fn [inst] (array/push slog :suspend-server) inst)
       :resume (fn [inst deps cfg]
                 (array/push slog :resume-server)
                 (put inst :conn (deps :conn))
                 inst))]))
(system/start sys5)
(def server-before (system/instance sys5 :server))
(array/clear slog)
(system/restart sys5 :conn)
(assert (= (freeze slog) [:suspend-server :start-conn :resume-server])
        "dependent with :suspend/:resume is suspended, not stopped")
(assert (= (system/instance sys5 :server) server-before)
        "suspended instance survives the restart")
(assert (= (get server-before :conn) (system/instance sys5 :conn))
        "resume receives the freshly started dependency")

# -- :factory scope ------------------------------------------------------

(var made 0)
(def sys6
  (system/init
    [(system/component :maker
       :scope :factory
       :start (fn [d c] (++ made) made))
     (system/component :consumer
       :deps [:maker]
       :start (fn [deps cfg] (deps :maker)))]))
(system/start sys6)
(assert (= made 0) "factory component is not started with the system")
(def make (system/instance sys6 :consumer))
(assert (= (make) 1) "dependent receives a constructor for factory deps")
(assert (= (make) 2) "each constructor call makes a fresh instance")
(assert (= (system/instance sys6 :maker) 3)
        "instance lookup on a factory makes a fresh instance")
(expect-error "restart factory" ":factory"
  |(system/restart sys6 :maker))

# -- health --------------------------------------------------------------

(def sys7
  (system/init
    [(system/component :ok
       :start (fn [d c] :i)
       :health (fn [i] {:status :up :latency-ms 1}))
     (system/component :bad
       :start (fn [d c] :i)
       :health (fn [i] {:status :down}))
     (system/component :plain
       :start (fn [d c] :i))]))
(system/start sys7)
(def h (system/health sys7))
(assert (= (h :status) :down) "one :down component makes the aggregate :down")
(assert (= (get-in h [:components :plain :status]) :up)
        "running component without :health reports :up")
(assert (= (get-in h [:components :ok :latency-ms]) 1)
        "health payload is passed through")
(system/stop sys7)
(assert (= ((system/health sys7) :status) :up)
        "stopped components do not report health")

# -- start failure rolls back -------------------------------------------

(def flog @[])
(def sys8
  (system/init
    [(system/component :first
       :start (fn [d c] (array/push flog :start-first) :i)
       :stop (fn [i] (array/push flog :stop-first)))
     (system/component :boom
       :deps [:first]
       :start (fn [d c] (error "boom")))]))
(expect-error "start failure propagates" "boom" |(system/start sys8))
(assert (= (freeze flog) [:start-first :stop-first])
        "already-started components are stopped on start failure")
(assert (= (get-in sys8 [:states :first]) :stopped) "rollback updates state")

# -- config schema hook --------------------------------------------------

(defn db-schema [cfg] (string? (get cfg :host)))

(def sys9
  (system/init
    [(system/component :db
       :config {:key :database :schema db-schema}
       :start (fn [d c] c))]
    {:database {:host 123}}))
(expect-error "schema rejects bad config" "schema" |(system/start sys9))

(def sys9b
  (system/init
    [(system/component :db
       :config {:key :database :schema db-schema}
       :start (fn [d c] c))]
    {:database {:host "h"}}))
(system/start sys9b)
(assert (= (get (system/instance sys9b :db) :host) "h") "valid config passes the schema")

# -- defcomponent + registry --------------------------------------------

(def reg (system/registry))
(with-dyns [system/registry-dyn reg]
  (system/defcomponent :from-macro
    :start (fn [d c] :ok)))
(assert (get reg :from-macro) "defcomponent registers into the dyn registry")
(def sys10 (system/init reg))
(system/start sys10)
(assert (= (system/instance sys10 :from-macro) :ok) "registry table is accepted by init")

(print "void/core/system tests OK")
