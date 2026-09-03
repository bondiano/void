(declare-project
  :name "void-ws"
  :description "void/ws — WebSocket (RFC 6455) over the void/http kernel: handshake, framing, ping/pong, close, a fiber per connection, rooms and broadcast."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# spork is here for base64, which the handshake needs as an alphabet
# rather than as cryptography — the same reason void/crypto declares it.
# void/ws-htmx imports void/html and void/htmx and is a separate plugin in
# this package, so an application whose sockets carry JSON never drags a
# template engine in — what void/cache-http is to void/cache.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
