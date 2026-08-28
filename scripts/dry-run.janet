### CI gate: dry-run the full in-repo plugin composition — void/http +
### void/html + void/htmx + void/rest + void/openapi + void/db +
### void/db-sqlite + void/db-postgres + void/db-http + void/redis +
### void/redis-http + void/dev + void/bench + the demo plugin on top of
### the core extension points.
### Runs bootstrap phases 1-5 (load, config, conditional, extension
### resolution, graph) and starts nothing; any validation failure exits
### non-zero with the batched error list. Run from the repository root:
###
###     janet scripts/dry-run.janet

(defn- add-tree [root]
  (array/insert module/paths 0 [(string root "/:all:/init.janet") :source])
  (array/insert module/paths 0 [(string root "/:all:.janet") :source]))

(add-tree (os/cwd))
(add-tree (string (os/cwd) "/core"))
(add-tree (string (os/cwd) "/dev"))
(add-tree (string (os/cwd) "/http"))
(add-tree (string (os/cwd) "/html"))
(add-tree (string (os/cwd) "/htmx"))
(add-tree (string (os/cwd) "/rest"))
(add-tree (string (os/cwd) "/openapi"))
(add-tree (string (os/cwd) "/db"))
(add-tree (string (os/cwd) "/db-sqlite"))
(add-tree (string (os/cwd) "/db-postgres"))
(add-tree (string (os/cwd) "/fdwait"))
# void/db-postgres reaches libpq through void/fdwait, the monorepo's one
# native module: build it first (cd fdwait && jpm build).
(array/insert module/paths 0
              [(string (os/cwd) "/fdwait/build/:all:.so") :native])
(add-tree (string (os/cwd) "/redis"))
(add-tree (string (os/cwd) "/cache"))
(add-tree (string (os/cwd) "/jobs"))
(add-tree (string (os/cwd) "/bench"))

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
(require "void/dev/init")
(require "void/bench/init")
(require "examples/demo/plugin")

(def report
  (plugin/dry-run {:plugins [:void/http :void/html :void/htmx :void/rest :void/openapi
                             :void/db :void/db-sqlite :void/db-postgres :void/db-http
                             :void/redis :void/redis-http
                             :void/cache :void/cache-redis :void/cache-http
                             :void/jobs :void/jobs-db :void/jobs-redis
                             :void/dev :void/bench :demo/greeter]
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
