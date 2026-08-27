(declare-project
  :name "void-redis"
  :description "void/redis — RESP2/RESP3 in pure Janet on the ev loop: a fiber-aware pool, pipelining, Lua scripts and pub/sub (SPEC §5.10, ROADMAP 2.2)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# No native module and no client library: a redis connection is a
# net/ stream, which is the whole reason this plugin installs
# anywhere Janet does. spork is here for one thing — the :json codec.
#
# void-core (../core) must be on the module path, and void-http
# (../http) as well for void/redis-http, which contributes the session
# store; the test suite wires them up itself via
# test-support/paths.janet.

(declare-source
  :source ["void"])
