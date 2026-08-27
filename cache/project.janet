(declare-project
  :name "void-cache"
  :description "void/cache — the :void/cache interface, an in-process TTL+LRU store, the (cache/wrap f) decorator and a redis backend (SPEC §5.11, ROADMAP 2.3)."
  :version "0.0.1")

# No dependencies. The kernel and the memory store are plain Janet;
# the redis backend (void/cache-redis) imports void/redis, and the
# response cache (void/cache-http) imports void/http — both are
# separate plugins in this package, so an application that wants
# neither pays for neither.
#
# void-core (../core) must be on the module path, plus ../redis and
# ../http for those two plugins; the test suite wires them up itself
# via test-support/paths.janet.

(declare-source
  :source ["void"])
