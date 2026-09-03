(declare-project
  :name "void-authz"
  :description "void/authz — ABAC: policies as pure functions under names, attributes pulled through providers when a policy asks, decisions as values with an explanation, and enforcement in phase 5000 from route metadata."
  :version "0.0.1")

# Two plugins: void/authz (the registry, the context and the decision —
# core only, so a job or an RPC handler can authorize) and
# void/authz-http (the middleware and :void.authz/policy). Neither
# depends on void/auth: the current identity is read from the
# :void.auth/identity dyn key, which is data rather than a module.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
