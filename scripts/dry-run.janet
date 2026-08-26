### CI gate: dry-run the full in-repo plugin composition — void/dev +
### the demo plugin on top of the core extension points. Runs bootstrap
### phases 1-5 (load, config, conditional, extension resolution, graph)
### and starts nothing; any validation failure exits non-zero with the
### batched error list. Run from the repository root:
###
###     janet scripts/dry-run.janet

(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(add-tree (os/cwd))
(add-tree (string (os/cwd) "/core"))
(add-tree (string (os/cwd) "/dev"))

(import void/core/plugin :as plugin)
(require "void/dev/init")
(require "examples/demo/plugin")

(def report
  (plugin/dry-run {:plugins [:void/dev :demo/greeter]
                   :profile :dev}))

(printf "dry-run ok (profile %q)" (report :profile))
(printf "  plugins:    %j (active: %j)" (report :plugins) (report :active))
(printf "  components: %j" (report :components))
(printf "  extensions:")
(each name (sorted (keys (report :extensions)))
  (def e (get-in report [:extensions name]))
  (printf "    %q  owner=%q contributions=%d" name (e :owner) (e :contributions)))
