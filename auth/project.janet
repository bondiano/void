(declare-project
  :name "void-auth"
  :description "void/auth — authentication: identity as data, strategies as an extension point (session, password, API tokens, JWT, magic link/OTP), the user store as a contract, and :void.auth/access enforcement in phase 4000 (SPEC §5.14, ADR-0023)."
  :version "0.0.1")

# Three plugins live here, and an application composes what it needs:
#
#   void/auth       identity, strategies, hashing — core + void/crypto
#   void/auth-http  the middleware and :void.auth/access — + void/http
#   void/auth-db    the user, token and challenge stores over void/db
#
# the same split void/cache and void/cache-redis make: a worker that
# only has to know who a job belongs to does not drag in the HTTP
# kernel, and an application with its own user table does not drag in a
# database.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
