(declare-project
  :name "void-cache"
  :description "void/cache — the :void/cache interface, an in-process TTL+LRU store, the (cache/wrap f) decorator and a redis backend."
  :version "0.0.1")

# No dependencies. The kernel and the memory store are plain Janet;
# the redis backend (void/cache-redis) imports void/redis, and the
# response cache (void/cache-http) imports void/http — both are
# separate plugins in this package, so an application that wants
# neither pays for neither.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
