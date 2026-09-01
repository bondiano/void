(declare-project
  :name "void-redis"
  :description "void/redis — RESP2/RESP3 in pure Janet on the ev loop: a fiber-aware pool, pipelining, Lua scripts and pub/sub (SPEC §5.10)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# No native module and no client library: a redis connection is a
# net/ stream, which is the whole reason this plugin installs
# anywhere Janet does. spork is here for one thing — the :json codec.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
