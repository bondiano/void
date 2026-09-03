(declare-project
  :name "void-security"
  :description "void/security — CSRF bound to whatever carries the credential, security headers and a CSP built from data, rate limiting over the :void/cache-store contract, CORS answered at the edge, and a client IP that is computed rather than believed."
  :version "0.0.1")

# One plugin: everything here is HTTP-shaped, so the void/cache —
# void/cache-redis split has nothing to divide. void/crypto is the one
# hard prerequisite (every token is signed); void/auth, void/authz and
# void/cache each add a capability and none is required.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
