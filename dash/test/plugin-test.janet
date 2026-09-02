### The plugin's declarations (Definition of Done, CONTRIBUTING).
###
### Three claims. The manifest passes plugin/dry-run in a full web
### composition, on :prod as well as :dev — the dashboard must not be
### the plugin that only boots on a laptop. A wrong [:dash] slice is a
### batched config error naming the plugin, not a surprise at request
### time. And plugin/inspect shows every contribution — the route
### source, the log sink, the lifecycle hooks — with the :void.dash/tile
### point owned by this plugin.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)

(log/set-level! nil :error)

(def plugins
  ["void/http/init" "void/html/init" "void/htmx/init" "void/dash/init"])

(defn- boot-opts [&opt dash-cfg profile]
  {:plugins plugins
   :profile (or profile :dev)
   :config {:env @{} :cli {:http {:port 0}
                           :dash (or dash-cfg {})}}})

# -- dry-run, both profiles ----------------------------------------------

(def report (plugin/dry-run (boot-opts)))
(assert (report :ok) "the composition dry-runs on :dev")
(assert (index-of :void/dash (report :active)) "void/dash is active")
(assert (index-of :dash/state (report :components))
        "the :dash/state component is in the graph")

(def prod-report (plugin/dry-run (boot-opts {} :prod)))
(assert (prod-report :ok) "and on :prod — shut is a posture, not a boot failure")

# -- the declarations, inspected -----------------------------------------

(def boot (plugin/bootstrap (boot-opts) true))

(def tile-point (get-in boot [:extensions :void.dash/tile]))
(assert tile-point "the :void.dash/tile point is declared")
(assert (= :void/dash (tile-point :owner)) "and owned by void/dash")

(defn- contributes? [point name]
  (some |(= name (get-in $ [:value :name]))
        (get-in boot [:extensions point :contributions] [])))

(assert (contributes? :void.http/route-source :void/dash)
        "the route source is contributed")
(assert (contributes? :void.core/log-sink :void.dash/ring)
        "the log ring sink is contributed")
(assert (some |(= :dash/build-context (get-in $ [:value :name]))
              (get-in boot [:extensions :void.core/hooks :contributions]))
        "the context builds at :before-start")

(def rows (plugin/inspect boot))
(def dash-row (find |(= :void/dash ($ :plugin)) rows))
(assert dash-row "plugin/inspect lists void/dash")
(assert (dash-row :active))
(assert (= [:dash/state] (dash-row :components))
        "one component, the state holder")

# -- wrong configs are boot errors, batched and named --------------------

(defn- refused? [dash-cfg]
  (def [ok err] (protect (plugin/bootstrap (boot-opts dash-cfg) true)))
  (and (not ok)
       (string/find "void/dash" (string err))))

(assert (refused? {:log-buffer 0}) "a zero log ring is refused")
(assert (refused? {:tap-buffer 0}) "a zero tap ring is refused")
(assert (refused? {:prefix 42}) "a non-string prefix is refused")
(assert (refused? {:history {:samples 1}}) "a one-sample history cannot draw a line")
(assert (refused? {:allow-actions "yes"}) "allow-actions is a boolean, not a word")

(print "plugin-test: ok")
