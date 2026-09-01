(declare-project
  :name "void-notify"
  :description "void/notify — one notification, several channels: the :void.notify/channel point, a mail channel, an in-app bell over void/db, a signed webhook over void/http/client, and delivery through void/jobs (ADR-0040).")

# Five plugins in one package, the void/cache — void/cache-http split:
# the kernel is core-only (void/notify), and each channel is the one
# plugin that carries its dependency — void/notify-mail (void/mail),
# void/notify-inapp (void/db + void/http + void/html),
# void/notify-webhook (void/http/client), void/notify-jobs (void/jobs).
# An application that only mails composes one of them.
#
# What has to be on the module path is a projection of the package
# graph (scripts/packages.janet, ADR-0020): see test-support/paths.janet.

(declare-source
  :source ["void"])
