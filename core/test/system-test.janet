(import ../void/core/system :as system)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat))
  (string err))

# -- component definition validation ------------------------------------

(expect-error "missing :start" ":start"
  |(system/component :a :deps []))
(expect-error "unknown option" "unknown option"
  |(system/component :a :start (fn [d c] 1) :strat 2))
(expect-error "odd option count" "odd"
  |(system/component :a :start))
(expect-error "bad :ambient" ":ambient"
  |(system/component :a :start (fn [d c] 1) :ambient @{:dyn :x}))
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

# -- restart brings the dependent back with the new dependency ----------

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
       :stop (fn [i] (array/push slog :stop-server)))]))
(system/start sys5)
(array/clear slog)
(system/restart sys5 :conn)
(assert (= (freeze slog) [:stop-server :start-conn :start-server])
        "restart takes the dependent down and brings it back around the new dependency")
(assert (= (get (system/instance sys5 :server) :conn) (system/instance sys5 :conn))
        "the restarted dependent holds the freshly started dependency")

# -- stop-key: one component and its dependents, nothing else ------------

(def klog @[])
(defn- kcomp [key deps]
  (system/component key
    :deps deps
    :start (fn [d c] (array/push klog [:start key]) key)
    :stop (fn [i] (array/push klog [:stop key]))))

(def sys6 (system/init [(kcomp :base []) (kcomp :mid [:base]) (kcomp :leaf [:mid]) (kcomp :side [])]))
(system/start sys6)
(array/clear klog)
(system/stop-key sys6 :mid)
(assert (= (freeze klog) [[:stop :leaf] [:stop :mid]])
        "stop-key stops the component and its dependents, in reverse order")
(assert (= :running (get-in sys6 [:states :base])) "what it depended on is left running")
(assert (= :running (get-in sys6 [:states :side])) "and so is everything unrelated")
(expect-error "stop-key on an unknown component" "unknown component"
  |(system/stop-key sys6 :nope))
(system/stop sys6)

# -- ambients ------------------------------------------------------------

(def probe (system/ambient :test/probe :of "the probe" :from :test/plugin))
(assert (nil? (system/current probe)) "an ambient starts empty")
(expect-error "an empty ambient names what is not started" ":test/plugin is not started"
  |(system/active probe))

(def sys13
  (system/init
    [(system/component :prober
       :ambient probe
       :start (fn [d c] @{:live true})
       :stop (fn [i]
               (assert (= i (system/active probe))
                       ":stop still sees the ambient it is about to release")
               (put i :live false)))]))
(system/start sys13)
(assert (= (system/instance sys13 :prober) (system/active probe))
        "the system holds the started instance in the component's ambient")
(system/with-ambient probe :override
  (assert (= :override (system/current probe)) "the dyn overrides the held value"))
(assert (= (system/instance sys13 :prober) (system/current probe))
        "and only for the scope")
(system/stop sys13)
(assert (nil? (system/current probe)) "a stopped component leaves its ambient empty")

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
       :start (fn [d c] :i))
     (system/component :throws
       :start (fn [d c] :i)
       :health (fn [i] (error "the probe itself broke")))]))
(system/start sys7)
(def h (system/health sys7))
(assert (= (h :status) :down) "one :down component makes the aggregate :down")
(assert (= (get-in h [:components :throws :status]) :down)
        "a :health function that throws counts as down")
(assert (string/find "the probe itself broke" (get-in h [:components :throws :reason]))
        "with the throw as its reason")
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

# a failing start undoes *this call*, not the process: the subset path
# starts a second time over a system that is already partly up, and a
# failure there used to take the first call's components down with it
(def rlog2 @[])
(defn- rc [key deps]
  (system/component key
    :deps deps
    :start (fn [d c]
             (when (= key :late-boom) (error "late boom"))
             (array/push rlog2 [:start key]) key)
    :stop (fn [i] (array/push rlog2 [:stop key]))))

(def sys8b (system/init [(rc :early []) (rc :late []) (rc :late-boom [:late])]))
(system/start sys8b [:early])
(array/clear rlog2)
(expect-error "the second start fails" "late boom" |(system/start sys8b [:late-boom]))
(assert (= (freeze rlog2) [[:start :late] [:stop :late]])
        "the failed call rolls back only what it started")
(assert (= :running (get-in sys8b [:states :early]))
        "what was already running before the call is left running")
(system/stop sys8b)

# -- :void/boot, the pseudo-dependency -----------------------------------

(def sys14
  (system/init
    [(system/component :needs-boot
       :deps [:void/boot]
       :start (fn [deps cfg] (get (deps :void/boot) :profile)))]))
(assert (nil? (get-in sys14 [:resolution :needs-boot :void/boot]))
        ":void/boot is not resolved as a component — it is not in the graph")
(assert (deep= (sorted (keys (system/needed-keys sys14 [:needs-boot]))) @[:needs-boot])
        "and it is not in the dependency closure either")
(expect-error "a system with no boot says so" "never attached to one"
  |(system/start sys14))

(def fake-boot @{:profile :test})
(system/attach-boot! sys14 fake-boot)
(assert (= fake-boot (system/current system/running-boot))
        "attach-boot! makes it the running boot")
(system/start sys14)
(assert (= :test (system/instance sys14 :needs-boot))
        "the component is handed the boot the system was attached to")
(system/stop sys14)
(system/detach-boot! sys14)
(assert (nil? (system/current system/running-boot))
        "detach-boot! leaves no running boot behind")

(expect-error ":void/boot cannot be a component key" "reserved"
  |(system/init [(system/component :void/boot :start (fn [d c] 1))]))
(expect-error ":void/boot cannot be provided" "reserved"
  |(system/init [(system/component :impostor :provides [:void/boot]
                                   :start (fn [d c] 1))]))

# -- config schema hook --------------------------------------------------

# deprecated on a component (ADR-0046: the manifest's :config-schema is
# where a plugin's slice is validated), but honoured: `init` checks it
# through the same config/validate, before anything starts
(defn db-schema [cfg] (string? (get cfg :host)))

(def sys9-err
  (expect-error "schema rejects bad config" "schema"
    |(system/init
       [(system/component :db
          :config {:key :database :schema db-schema}
          :start (fn [d c] c))
        (system/component :other
          :config {:key :other :schema {:n :int}}
          :start (fn [d c] c))]
       {:database {:host 123} :other {:n "x"}})))
(assert (and (string/find "component :db" sys9-err) (string/find "component :other" sys9-err))
        "every component's schema failure is in the one error, not first-fail")
(assert (string/find "[:other :n] (component :other): expected :int" sys9-err)
        "with the path from the config root")

(def sys9b
  (system/init
    [(system/component :db
       :config {:key :database :schema db-schema}
       :start (fn [d c] c))]
    {:database {:host "h"}}))
(system/start sys9b)
(assert (= (get (system/instance sys9b :db) :host) "h") "valid config passes the schema")

# the documented common case: the schema is data (a Config struct),
# validated through void/core/schema exactly like a plugin's
# :config-schema — not silently skipped for not being callable, and
# closed the same way
(expect-error "a data schema rejects bad config" "expected :string, got 123"
  |(system/init
     [(system/component :db
        :config {:key :database :schema {:host :string}}
        :start (fn [d c] c))]
     {:database {:host 123}}))
(expect-error "a data schema is closed, like a manifest's" "did you mean :host?"
  |(system/init
     [(system/component :db
        :config {:key :database :schema {:host :string}}
        :start (fn [d c] c))]
     {:database {:host "h" :hots "typo"}}))

(def sys9d
  (system/init
    [(system/component :db
       :config {:key :database :schema {:host :string}}
       :start (fn [d c] c))]
    {:database {:host "h"}}))
(system/start sys9d)
(assert (= (get (system/instance sys9d :db) :host) "h")
        "a data schema passes valid config through")

# -- a failed restart is remembered and retried --------------------------

(var flaky-broken false)
(def sys12
  (system/init
    [(system/component :flaky
       :start (fn [d c]
                (when flaky-broken (error "still broken"))
                :flaky)
       :stop (fn [i] nil))
     (system/component :leaf
       :deps [:flaky]
       :start (fn [d c] :leaf)
       :stop (fn [i] nil))]))
(system/start sys12)
(set flaky-broken true)
(expect-error "the failing restart propagates" "still broken"
  |(system/restart sys12 :flaky))
(assert (= :stopped (get-in sys12 [:states :flaky])) "the component is down, honestly")
(assert (= :stopped (get-in sys12 [:states :leaf])) "and so is its dependent")
(assert (get-in sys12 [:restart-pending :leaf])
        "what the failed restart took down is remembered on the system")
(set flaky-broken false)
(system/restart sys12 :flaky)
(assert (= :running (get-in sys12 [:states :flaky])) "the retry brings the component back")
(assert (= :running (get-in sys12 [:states :leaf]))
        "and the dependent the failed attempt had left stopped")
(assert (nil? (sys12 :restart-pending)) "the pending set is cleared on success")
(system/stop sys12)

# -- subset start (:needs bootstrap for CLI commands) --------------------

(def subset-log @[])
(defn- track [k]
  (system/component k
    :deps (case k :b [:a] :c [:b] [])
    :start (fn [d c] (array/push subset-log [:start k]) k)
    :stop (fn [i] (array/push subset-log [:stop k]))))

(def sys11 (system/init [(track :a) (track :b) (track :c) (track :d)]))
(assert (deep= (sorted (keys (system/needed-keys sys11 [:b]))) @[:a :b])
        "needed-keys expands transitive deps")
(expect-error "needed-keys rejects unknown keys" "unknown component"
  |(system/needed-keys sys11 [:nope]))

(system/start sys11 [:b])
(assert (deep= subset-log @[[:start :a] [:start :b]])
        "subset start touches only the closure, in dependency order")
(assert (nil? (get-in sys11 [:states :c])) ":c never started")
(assert (nil? (get-in sys11 [:states :d])) ":d never started")
(system/stop sys11)
(assert (deep= subset-log @[[:start :a] [:start :b] [:stop :b] [:stop :a]])
        "stop after a subset start stops only what ran, in reverse")

# a later full start picks up the not-yet-running rest
(array/clear subset-log)
(system/start sys11)
(assert (deep= (sorted (map |($ 1) subset-log)) @[:a :b :c :d])
        "full start after subset start starts everything")
(system/stop sys11)

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
