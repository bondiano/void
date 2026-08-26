# Wave-0 exit criterion 2: the toy demo plugin (examples/demo) passes
# the full cycle — config schema + defaults, a component providing an
# interface, cli/health contributions — and disappears without a trace
# when its single :plugins entry is removed.
#
# The demo plugin imports void/core by bare name, so put this package
# on the module path first (jpm test runs with cwd = core/).
(array/insert module/paths 0 [(string (os/cwd) "/:all:/init.janet") :source])
(array/insert module/paths 0 [(string (os/cwd) "/:all:.janet") :source])

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import ../../examples/demo/plugin :as demo)

(defn expect-error [name pat thunk]
  (def [ok err] (protect (thunk)))
  (assert (not ok) (string name ": expected an error"))
  (assert (string/find pat (string err))
          (string/format "%s: error %q does not mention %q" name (string err) pat))
  (string err))

# -- full cycle: one :plugins entry enables everything -------------------

(def boot (plugin/start! {:plugins [:demo/greeter]}))
(assert (= :ready (boot :phase)))
(assert (= "hello" (get-in boot [:config :values :greeter :greeting]))
        ":config-defaults land in the config")

(def inst (system/instance (boot :system) :demo/greeter))
(assert inst "the component is reachable through its :provides interface")
(assert (= "hello, world!" (demo/greet inst "world")))

(def cli (plugin/extension boot :void.core/cli))
(assert (= [:demo/greet] (freeze (map |($ :name) cli)))
        "the cli command is contributed")
(assert (= [:demo/greeter-service] (get-in cli [0 :needs])))

(def checks (plugin/extension boot :void.core/health))
(assert (= [:demo/greeter-check] (freeze (map |($ :name) checks)))
        "the health check is contributed")
(assert (= {:status :up} (((first checks) :fn))))

(def h (system/health (boot :system)))
(assert (= :up (get-in h [:components :demo/greeter-service :status])))
(assert (= 1 (get-in h [:components :demo/greeter-service :greeted]))
        "component health sees the instance state")

(plugin/shutdown! boot)
(assert (= :stopped (boot :phase)))

# -- config: override and schema validation ------------------------------

(def boot2 (plugin/bootstrap {:plugins [:demo/greeter]
                              :config {:cli {:greeter {:greeting "ahoy"}}}}
                             true))
(system/start (boot2 :system))
(assert (= "ahoy, crew!" (demo/greet (system/instance (boot2 :system) :demo/greeter) "crew"))
        "config layers override the plugin defaults")
(system/stop (boot2 :system))

(def cfg-err
  (expect-error "config schema guards the slice" "demo/greeter"
    |(plugin/dry-run {:plugins [:demo/greeter]
                      :config {:cli {:greeter {:greeting 42}}}})))
(assert (string/find "plugin files:" cfg-err)
        "the config error points at the plugin's defining file")
(assert (string/find "examples/demo/plugin.janet" cfg-err))

# -- removal: deleting the :plugins entry leaves no trace ----------------

(def bare (plugin/bootstrap {:plugins []} true))
(assert (empty? (get-in bare [:system :order])) "no components")
(assert (nil? (get-in bare [:config :values :greeter])) "no config slice")
(assert (empty? (get-in bare [:extensions :void.core/cli :contributions]))
        "no cli contributions")
(assert (empty? (get-in bare [:extensions :void.core/health :contributions]))
        "no health contributions")
(assert (nil? (get-in bare [:extensions :void.core/interface :resolved :demo/greeter]))
        "no interface declaration")

(print "demo-test: all assertions passed")
