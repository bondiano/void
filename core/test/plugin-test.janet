(import ../void/core/plugin :as plugin)
(import ../void/core/system :as system)
(import ../void/core/schema :as schema)
(import ../void/core/hooks :as hooks)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat))
  (string err))

# -- semver --------------------------------------------------------------

(assert (= [1 2 3] (plugin/parse-version "1.2.3")))
(assert (= [0 1 0] (plugin/parse-version "v0.1")))
(expect-error "bad version" "version" |(plugin/parse-version "abc"))
(expect-error "non-string version" "version" |(plugin/parse-version 12))

(assert (plugin/satisfies? "1.2.3" ">=1.0"))
(assert (not (plugin/satisfies? "1.2.3" ">=1.3")))
(assert (plugin/satisfies? "1.2.3" ">=1.0 <2.0"))
(assert (not (plugin/satisfies? "2.0.0" ">=1.0 <2.0")))
(assert (plugin/satisfies? "1.9.0" "^1.1"))
(assert (not (plugin/satisfies? "2.0.0" "^1.1")))
(assert (plugin/satisfies? "0.1.5" "^0.1"))
(assert (not (plugin/satisfies? "0.2.0" "^0.1")))
(assert (plugin/satisfies? "1.2.5" "~1.2"))
(assert (not (plugin/satisfies? "1.3.0" "~1.2")))
(assert (plugin/satisfies? "1.2.3" "1.2.3"))
(assert (not (plugin/satisfies? "1.2.4" "1.2.3")))

# -- manifest validation -------------------------------------------------

(expect-error "unknown manifest option" "unknown option"
  |(plugin/manifest 'test/x :vresion "1.0.0"))
(expect-error "odd option count" "key-value"
  |(plugin/manifest 'test/x :version))
(expect-error "bad component entry" "component"
  |(plugin/manifest 'test/x :components [42]))
(expect-error ":config-schema without :config-key" ":config-key"
  |(plugin/manifest 'test/x :config-schema {:a :int}))
(expect-error "bad :requires" ":requires"
  |(plugin/manifest 'test/x :requires "void/core"))
(expect-error "bad :requires constraint" "version"
  |(plugin/manifest 'test/x :requires {:test/y ">=abc"}))
(expect-error "bad :when" ":when"
  |(plugin/manifest 'test/x :when 5))
(expect-error "bad :version" "version"
  |(plugin/manifest 'test/x :version "one.two"))
(expect-error "bad config schema form" ":config-schema"
  |(plugin/manifest 'test/x :config-key :x :config-schema [:wat]))

(def m0 (plugin/manifest 'test/frozen :version "1.0.0"))
(assert (struct? m0) "manifest is a frozen struct")
(assert (= :test/frozen (m0 :name)))

# -- extension point validation ------------------------------------------

(expect-error "bad cardinality" ":cardinality"
  |(plugin/extension-point :x/p :cardinality :twice))
(expect-error "unknown point option" "unknown option"
  |(plugin/extension-point :x/p :shema {}))
(expect-error "bad point schema" ":schema"
  |(plugin/extension-point :x/p :schema [:wat]))
(expect-error "bad reduce" ":reduce"
  |(plugin/extension-point :x/p :reduce 5))

# -- happy path: points, contributions, reduce, extension access ---------

(def started @[])

(def registry-plugin
  (plugin/manifest 'test/registry
    :version "1.0.0"
    :extension-points {:test/commands {:doc "test commands"
                                       :schema {:name :keyword :fn :function}
                                       :cardinality :many
                                       :reduce (fn [cs] (sorted-by |($ :name) cs))}}
    :components [(system/component :test/host
                   :start (fn [deps cfg]
                            (array/push started :host)
                            (plugin/extension :test/commands)))]))

(def contrib-plugin
  (plugin/manifest 'test/contrib
    :version "0.2.0"
    :requires {:test/registry ">=1.0" :void/core true}
    :contributes {:test/commands [{:name :b-cmd :fn (fn [] :b)}
                                  {:name :a-cmd :fn (fn [] :a)}]}))

(def boot (plugin/start! {:plugins [registry-plugin contrib-plugin]}))
(assert (= :ready (boot :phase)) "start! reaches :ready")
(assert (= [:host] (freeze started)) "component started once")
(def host-inst (system/instance (boot :system) :test/host))
(assert (= [:a-cmd :b-cmd] (freeze (map |($ :name) host-inst)))
        "owner reads the reduced (sorted) contributions in :start")
(assert (= host-inst (plugin/extension boot :test/commands))
        "extension accessor returns the resolved value")
(plugin/shutdown! boot)
(assert (= :stopped (boot :phase)))

# -- inspect / why -------------------------------------------------------

(def iboot (plugin/bootstrap {:plugins [registry-plugin contrib-plugin]}))
(def summary (plugin/inspect iboot))
(def contrib-row (find |(= :test/contrib ($ :plugin)) summary))
(assert contrib-row "inspect lists every plugin")
(assert (contrib-row :active))
(assert (= 2 (get-in contrib-row [:contributes :test/commands])))

(def pt (plugin/inspect iboot :test/commands))
(assert (= :test/registry (pt :owner)))
(assert (= 2 (length (pt :contributions))))
(assert (= :test/contrib (get-in pt [:contributions 0 :plugin]))
        "contributions carry their source plugin")

(def pt2 (plugin/inspect :test/commands))
(assert (= pt2 pt) "zero-arg inspect uses the current boot")
(expect-error "inspect unknown point" "did you mean"
  |(plugin/inspect iboot :test/comands))

(def w (plugin/why iboot :test/host))
(assert (= :test/registry (w :plugin)) "why names the source plugin")
(expect-error "why unknown key" "unknown component"
  |(plugin/why iboot :test/nope))

# -- config: defaults, batch validation ----------------------------------

(def cfg-plugin
  (plugin/manifest 'test/cfg
    :config-key :cfgtest
    :config-schema {:host :string :port :int}
    :config-defaults {:host "localhost" :port 6379}))

(def cboot (plugin/bootstrap {:plugins [cfg-plugin]}))
(assert (= "localhost" (get-in cboot [:config :values :cfgtest :host]))
        "plugin :config-defaults form the lowest layer")

(def cboot2 (plugin/bootstrap {:plugins [cfg-plugin]
                               :config {:cli {:cfgtest {:port 9999}}}}))
(assert (= 9999 (get-in cboot2 [:config :values :cfgtest :port]))
        "explicit config overrides plugin defaults")

(def bad1 (plugin/manifest 'test/bad1 :config-key :b1 :config-schema {:port :int}))
(def bad2 (plugin/manifest 'test/bad2 :config-key :b2 :config-schema {:host :string}))
(def cfg-err
  (expect-error "config schema batch" ":config"
    |(plugin/dry-run {:plugins [bad1 bad2]
                      :config {:cli {:b1 {:port "x"} :b2 {:nope 1}}}})))
(assert (and (string/find "test/bad1" cfg-err) (string/find "test/bad2" cfg-err))
        "config errors are batched across plugins, not first-fail")

(expect-error "user :defaults reserved" ":config-defaults"
  |(plugin/dry-run {:plugins [] :config {:defaults {:a 1}}}))

# -- conditional activation ----------------------------------------------

(def cond-started @[])
(def cond-plugin
  (plugin/manifest 'test/cond
    :config-key :feature
    :when (fn [cfg] (get-in cfg [:feature :enabled]))
    :components [(system/component :cond/comp
                   :start (fn [d c] (array/push cond-started :yes) :inst))]
    :contributes {:void.core/health [{:name :cond-check :fn (fn [] {:status :up})}]}))

(def off (plugin/dry-run {:plugins [cond-plugin]
                          :config {:cli {:feature {:enabled false}}}}))
(assert (= [] (off :active)))
(assert (= [:test/cond] (off :inactive)))
(assert (= [] (off :components)) "inactive plugin brings no components")
(assert (zero? (get-in off [:extensions :void.core/health :contributions]))
        "inactive plugin brings no contributions")

(def on (plugin/dry-run {:plugins [cond-plugin]
                         :config {:cli {:feature {:enabled true}}}}))
(assert (= [:test/cond] (on :active)))
(assert (= [:cond/comp] (on :components)))
(assert (empty? cond-started) "dry-run never starts components")

(def needs-cond (plugin/manifest 'test/needs-cond :requires {:test/cond true}))
(expect-error "active requires inactive" "deactivated"
  |(plugin/dry-run {:plugins [cond-plugin needs-cond]
                    :config {:cli {:feature {:enabled false}}}}))

# -- load phase: void-api, requires, duplicates --------------------------

(def future-plugin (plugin/manifest 'test/future :void-api 99))
(expect-error "void-api mismatch" ":void-api"
  |(plugin/dry-run {:plugins [future-plugin]}))

(def old-plugin (plugin/manifest 'test/old :version "0.1.0"))
(def wants-new (plugin/manifest 'test/wants :requires {:test/old ">=1.0"}))
(def ver-err
  (expect-error "requires version conflict" ">=1.0"
    |(plugin/dry-run {:plugins [old-plugin wants-new]})))
(assert (string/find "0.1.0" ver-err) "version error names the loaded version")

(expect-error "requires missing plugin" "not in the plugin list"
  |(plugin/dry-run {:plugins [(plugin/manifest 'test/lonely
                                :requires {:test/ghost ">=0.1"})]}))

(expect-error "duplicate plugin" "twice"
  |(plugin/dry-run {:plugins [old-plugin old-plugin]}))

(expect-error "unregistered keyword entry" "not registered"
  |(plugin/dry-run {:plugins [:test/never-defined]}))

# -- on-load hook --------------------------------------------------------

(def on-load-log @[])
(def loader (plugin/manifest 'test/loader
              :on-load (fn [ctx] (array/push on-load-log [(ctx :name) (ctx :profile)]))))
(plugin/dry-run {:plugins [loader] :profile :test})
(assert (= (freeze on-load-log) [[:test/loader :test]])
        ":on-load runs during the load phase with its context")

(expect-error "on-load failure" ":on-load"
  |(plugin/dry-run {:plugins [(plugin/manifest 'test/boom
                                :on-load (fn [_] (error "kaboom")))]}))

# -- extension resolution errors -----------------------------------------

# typo in point name -> did-you-mean
(def typo (plugin/manifest 'test/typo
            :contributes {:void.core/helth [{:name :x :fn (fn [] 1)}]}))
(def typo-err
  (expect-error "unknown point" "did you mean"
    |(plugin/dry-run {:plugins [typo]})))
(assert (string/find ":void.core/health" typo-err))
(assert (string/find "test/typo" typo-err) "error names the contributing plugin")

# contribution to a point whose owner is inactive
(def owner-off (plugin/manifest 'test/owner-off
                 :when (fn [_] false)
                 :extension-points {:test/off-point {:cardinality :many}}))
(def contrib-off (plugin/manifest 'test/contrib-off
                   :contributes {:test/off-point [{:x 1}]}))
(expect-error "dangling contribution" "inactive"
  |(plugin/dry-run {:plugins [owner-off contrib-off]}))

# contribution failing the point schema -> error with plugin source + path
(def badc (plugin/manifest 'test/badc
            :contributes {:void.core/cli [{:name "run" :fn (fn [] 1)}]}))
(def badc-err
  (expect-error "invalid contribution" "test/badc"
    |(plugin/dry-run {:plugins [badc]})))
(assert (string/find ":name" badc-err) "schema error carries the path")

# duplicate point declaration
(expect-error "point declared twice" "declared by both"
  |(plugin/dry-run {:plugins [(plugin/manifest 'test/pa
                                :extension-points {:test/dup {}})
                              (plugin/manifest 'test/pb
                                :extension-points {:test/dup {}})]}))

# cross-check :validate (duplicate CLI command names)
(expect-error "cli name conflict" "duplicate CLI command"
  |(plugin/dry-run {:plugins [(plugin/manifest 'test/cli-a
                                :contributes {:void.core/cli [{:name :run :fn (fn [] 1)}]})
                              (plugin/manifest 'test/cli-b
                                :contributes {:void.core/cli [{:name :run :fn (fn [] 2)}]})]}))

# -- cardinality ---------------------------------------------------------

(def single-owner
  (plugin/manifest 'test/single-owner
    :extension-points {:test/single {:cardinality :single}
                       :test/required {:cardinality :single-required}}))

(def req-contrib (plugin/manifest 'test/req-contrib
                   :contributes {:test/required [{:v 1}]}))

(def sboot (plugin/bootstrap {:plugins [single-owner req-contrib]}))
(assert (= {:v 1} (plugin/extension sboot :test/required))
        ":single-required resolves to the single contribution itself")
(assert (nil? (plugin/extension sboot :test/single))
        ":single with no contributions resolves to nil")

(expect-error "single-required missing" "exactly one"
  |(plugin/dry-run {:plugins [single-owner]}))

(def s1 (plugin/manifest 'test/s1 :contributes {:test/single [{:v 1}]}))
(def s2 (plugin/manifest 'test/s2 :contributes {:test/single [{:v 2}]}))
(def card-err
  (expect-error "single cardinality violated" ":single"
    |(plugin/dry-run {:plugins [single-owner req-contrib s1 s2]})))
(assert (and (string/find "test/s1" card-err) (string/find "test/s2" card-err))
        "cardinality error lists the candidates")

# -- interfaces: :provides must be declared ------------------------------

(def impl-comp (system/component :impl/cache
                 :provides [:test/cache]
                 :start (fn [d c] :cache-inst)))

(expect-error "undeclared interface" "undeclared interface"
  |(plugin/dry-run {:plugins [(plugin/manifest 'test/iface-bad
                                :components [impl-comp])]}))

(def iface-ok
  (plugin/manifest 'test/iface-ok
    :components [impl-comp]
    :contributes {:void.core/interface [{:name :test/cache :doc "cache interface"}]}))
(def iface-report (plugin/dry-run {:plugins [iface-ok]}))
(assert (= [:impl/cache] (iface-report :components)))

# -- graph errors surface through phase 5 --------------------------------

(expect-error "dependency cycle" "cycle"
  |(plugin/dry-run
     {:plugins [(plugin/manifest 'test/cyclic
                  :components [(system/component :cyc/a :deps [:cyc/b] :start (fn [d c] 1))
                               (system/component :cyc/b :deps [:cyc/a] :start (fn [d c] 1))])]}))

(def dup-err
  (expect-error "cross-plugin duplicate component" "duplicate"
    |(plugin/dry-run
       {:plugins [(plugin/manifest 'test/dup-a
                    :components [(system/component :dup/c :start (fn [d c] 1))])
                  (plugin/manifest 'test/dup-b
                    :components [(system/component :dup/c :start (fn [d c] 1))])]})))
(assert (and (string/find "test/dup-a" dup-err) (string/find "test/dup-b" dup-err))
        "duplicate component error names both plugins")

# -- :provides conflict caught by dry-run --------------------------------

(defn store-comp [key]
  (system/component key :provides [:test/store] :start (fn [d c] key)))

(def multi-store
  (plugin/manifest 'test/multi-store
    :source "examples/fake/multi.janet"
    :components [(store-comp :store/a) (store-comp :store/b)]
    :contributes {:void.core/interface [{:name :test/store}]}))

(def multi-err
  (expect-error "provides conflict, no consumer" "provided by multiple"
    |(plugin/dry-run {:plugins [multi-store]})))
(assert (string/find "plugin files:" multi-err)
        "phase error carries a plugin-files footer")
(assert (string/find "examples/fake/multi.janet" multi-err)
        "the footer points at the offending plugin's :source")

(def picked (plugin/dry-run {:plugins [multi-store]
                             :config {:cli {:test/store {:impl :store/a}}}}))
(assert (= [:store/a :store/b] (freeze (sorted (picked :components))))
        "a config {:impl ...} choice resolves the conflict in dry-run")

# -- core points: schema-type and schema-projection get registered -------

(def typer
  (plugin/manifest 'test/typer
    :contributes {:void.core/schema-type
                  [{:name :test/upper
                    :spec {:validate (fn [v _] (and (string? v)
                                                    (= v (string/ascii-upper v))))}}]
                  :void.core/schema-projection
                  [{:name :test/keys
                    :fn (fn [sch] (map first (sch :children)))}]}))
(plugin/dry-run {:plugins [typer]})
(assert (schema/valid? :test/upper "ABC") "schema-type contribution is registered")
(assert (not (schema/valid? :test/upper "abc")))
(assert (= [:a :b] (freeze (schema/project :test/keys {:a :int :b :string})))
        "schema-projection contribution is registered")

# -- hooks + lifecycle order ---------------------------------------------

(def hook-log @[])
(def hooky
  (plugin/manifest 'test/hooky
    :components [(system/component :hooky/c
                   :start (fn [d c] (array/push hook-log :start) :i)
                   :stop (fn [i] (array/push hook-log :stop)))]
    :contributes {:void.core/hooks
                  [{:hook :after-start :fn (fn [b] (array/push hook-log :after)) :phase 2000}
                   {:hook :config-loaded :fn (fn [b] (array/push hook-log :cfg)) :name :cfg-hook}
                   {:hook :before-start :fn (fn [b] (array/push hook-log :before))}]}))
(def hboot (plugin/start! {:plugins [hooky]}))
(assert (= (freeze hook-log) [:cfg :before :start :after])
        "hooks fire in lifecycle order around system start")
(def cfg-entry (first (hooks/handlers (hboot :hooks) :config-loaded)))
(assert (= :test/hooky (cfg-entry :plugin))
        "boot :hooks registry attributes handlers to their plugin")
(hooks/add! (hboot :hooks) :before-stop
            (fn [b] (array/push hook-log :pre-stop)) :name :late)
(plugin/shutdown! hboot)
(assert (= (freeze (slice hook-log 4)) [:pre-stop :stop])
        "ad-hoc :before-stop handler runs before component stops")

# -- shutdown with timeout -----------------------------------------------

(def stop-log @[])
(def hang
  (plugin/manifest 'test/hang
    :components [(system/component :hang/a
                   :start (fn [d c] :a)
                   :stop (fn [i] (ev/sleep 10)))
                 (system/component :hang/b
                   :deps [:hang/a]
                   :start (fn [d c] :b)
                   :stop (fn [i] (array/push stop-log :b)))]))
(def hang-boot (plugin/start! {:plugins [hang]}))
(def [stop-ok stop-err] (protect (plugin/shutdown! hang-boot 0.05)))
(assert (not stop-ok) "hung stop is reported")
(assert (string/find "hang/a" (string stop-err)))
(assert (= [:b] (freeze stop-log)) "the hung component does not block the others")

# -- defplugin + contribute! / defextension-point ------------------------

(plugin/contribute! :void.core/health
  {:name :dp-check :fn (fn [] {:status :up})})
(plugin/defextension-point :test/dp-point
  :doc "point declared via defextension-point"
  :cardinality :many)
(plugin/defplugin test/dp
  :version "0.0.1")

(assert (= :test/dp (manifest :name)) "defplugin defines `manifest`")
(assert (= 1 (length (get-in manifest [:contributes :void.core/health])))
        "contribute! lands in the manifest")
(assert (get-in manifest [:extension-points :test/dp-point])
        "defextension-point lands in the manifest")
(assert (= manifest (get plugin/manifest-registry :test/dp))
        "defplugin registers the manifest")
(assert (= (dyn :current-file) (manifest :source))
        "defplugin records the defining file as :source")

(def dp-report (plugin/dry-run {:plugins [:test/dp]}))
(assert (= [:test/dp] (dp-report :active))
        "keyword :plugins entries resolve through the registry")

# -- deprecation aliases (SPEC part II §1.5) -----------------------------

(expect-error "self-alias" "alias itself"
  |(plugin/extension-point :x/p :aliases [:x/p]))
(expect-error "non-keyword alias" ":aliases"
  |(plugin/extension-point :x/p :aliases ["old"]))

(def aliased-owner
  (plugin/manifest 'test/aliased-owner
    :version "1.0.0"
    :extension-points
    {:test/commands2 {:doc "renamed test commands"
                      :schema {:name :keyword :fn :function}
                      :aliases [:test/commands-old]}}))

(def legacy-contributor
  (plugin/manifest 'test/legacy
    :version "1.0.0"
    :requires {:test/aliased-owner ">=1.0"}
    # still addressing the pre-rename point name
    :contributes {:test/commands-old [{:name :old-cmd :fn (fn [] :old)}]}))

(def alias-boot
  (plugin/bootstrap {:plugins [aliased-owner legacy-contributor]}))
(assert (= 1 (length (get-in alias-boot
                             [:extensions :test/commands2 :contributions])))
        "a contribution to the deprecated alias folds into the new point")
(assert (= :test/legacy
           (get-in alias-boot
                   [:extensions :test/commands2 :contributions 0 :plugin]))
        "the folded contribution keeps its source plugin")
(assert (nil? (get-in alias-boot [:extensions :test/commands-old]))
        "the alias is not a point of its own")
(assert (deep= [:test/commands-old]
               (freeze (get (plugin/inspect alias-boot :test/commands2) :aliases)))
        "inspect shows the deprecated aliases")

# an alias validates against the new point's schema like any contribution
(def bad-legacy
  (plugin/manifest 'test/legacy-bad
    :version "1.0.0"
    :requires {:test/aliased-owner ">=1.0"}
    :contributes {:test/commands-old [{:name "not-a-keyword" :fn (fn [] nil)}]}))
(expect-error "aliased contribution is schema-checked" ":test/commands2"
  |(plugin/bootstrap {:plugins [aliased-owner bad-legacy]}))

# an alias colliding with a declared point is a bootstrap error
(def colliding-owner
  (plugin/manifest 'test/colliding
    :version "1.0.0"
    :extension-points
    {:test/other {:doc "other" :aliases [:test/commands2]}}))
(expect-error "alias vs declared point" "itself a declared point"
  |(plugin/bootstrap {:plugins [aliased-owner colliding-owner]}))

# -- a late start! failure stops what it started -------------------------
#
# :after-start hooks and deploy/check! run with every component
# :running; an error there used to escape with the sockets and pools
# still open and nobody left to stop them (the CLI exits right after).

(def late-log @[])
(def late-failure
  (plugin/manifest 'test/late-failure
    :version "1.0.0"
    :components [(system/component :late/resource
                   :start (fn [d c] (array/push late-log :opened) :resource)
                   :stop (fn [i] (array/push late-log :stopped)))]
    :contributes {:void.core/hooks
                  [{:hook :after-start
                    :name :test/boom
                    :fn (fn [b] (error "late boom"))}]}))
(expect-error "the :after-start failure propagates" "late boom"
  |(plugin/start! {:plugins [late-failure]}))
(assert (deep= late-log @[:opened :stopped])
        "the component the boot had already started was stopped before the error escaped")

(print "plugin-test: all assertions passed")
