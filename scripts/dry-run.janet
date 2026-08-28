### CI gate: dry-run the full in-repo plugin composition — void/http +
### void/html + void/htmx + void/rest + void/openapi + void/db +
### void/db-sqlite + void/db-postgres + void/db-http + void/redis +
### void/redis-http + void/cache + void/jobs + void/pressure +
### void/dev + void/bench (+ its runtime probe) + the demo plugin on top of
### the core extension points.
### The plugin list below is the composition; the module path under it
### is a projection of scripts/packages.janet, so a package added to the
### graph is on the path here without a second edit (ADR-0020).
###
### Runs bootstrap phases 1-5 (load, config, conditional, extension
### resolution, graph) and starts nothing; any validation failure exits
### non-zero with the batched error list. Run from anywhere:
###
###     janet scripts/dry-run.janet

(import ./packages :as packages)

# Every package in the graph, on the module path — the composition gate
# is the one place that loads all of them at once (ADR-0020). void/fdwait
# is among them, so its native module has to be built first
# (janet scripts/bootstrap.janet, or cd fdwait && jpm build).
(packages/add-paths (packages/packages))

# examples/demo is a single plugin file off the repository root, not a
# package: it has no project.janet and no suite of its own.
(array/insert module/paths 0 [(string packages/root "/:all:.janet") :source])

(import void/core/plugin :as plugin)
(require "void/http/init")
(require "void/html/init")
(require "void/htmx/init")
(require "void/rest/init")
(require "void/openapi/init")
(require "void/db/init")
(require "void/db-sqlite/init")
(require "void/db-postgres/init")
(require "void/db/http")
(require "void/redis/init")
(require "void/redis/http")
(require "void/cache/init")
(require "void/cache/redis")
(require "void/cache/http")
(require "void/jobs/init")
(require "void/jobs/db")
(require "void/jobs/redis")
(require "void/pressure/init")
(require "void/pressure/http")
(require "void/dev/init")
(require "void/bench/init")
(require "void/bench/probe")
(require "examples/demo/plugin")

(def report
  (plugin/dry-run {:plugins [:void/http :void/html :void/htmx :void/rest :void/openapi
                             :void/db :void/db-sqlite :void/db-postgres :void/db-http
                             :void/redis :void/redis-http
                             :void/cache :void/cache-redis :void/cache-http
                             :void/jobs :void/jobs-db :void/jobs-redis
                             :void/pressure :void/pressure-http
                             :void/dev :void/bench :bench/probe :demo/greeter]
                   :profile :dev
   # two drivers now provide :void/db-driver, two stores provide
   # :void/cache-store, and three backends provide :void/jobs-backend —
   # exactly the ambiguity the kernel refuses to resolve on its own. The
   # gate says which, the way an application's config would (see
   # void/db-postgres, void/cache-redis, void/jobs-redis)
   :config {:cli {:void/db-driver {:impl :db.sqlite/driver}
                  :void/cache-store {:impl :cache/redis}
                  :void/jobs-backend {:impl :jobs/redis}}}}))

(printf "dry-run ok (profile %q)" (report :profile))
(printf "  plugins:    %j (active: %j)" (report :plugins) (report :active))
(printf "  components: %j" (report :components))
(printf "  extensions:")
(each name (sorted (keys (report :extensions)))
  (def e (get-in report [:extensions name]))
  (printf "    %q  owner=%q contributions=%d" name (e :owner) (e :contributions)))
