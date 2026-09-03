(declare-project
  :name "void-mail"
  :description "void/mail — a message is data, templates are void/html views, delivery is a transport contribution, and the queue is a plugin rather than a call-site decision."
  :version "0.0.1")

# Three plugins in one package, split by what an application composes:
# `void/mail` needs void/html and nothing else, `void/mail-jobs` adds
# void/jobs (delivery off the request path), `void/mail-auth` adds
# void/auth (magic links and one-time codes go out as mail). The
# void/cache — void/cache-redis split, for the same reason: a plugin
# that is not composed cannot demand a dependency nobody has.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
