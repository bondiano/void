(declare-project
  :name "void-grpc"
  :description "void/grpc — Connect-RPC over the void/http kernel: unary methods on HTTP/1.1 as ordinary routes, JSON and protobuf codecs, `defservice` over a .proto (SPEC §5.8, ADR-0013)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# spork is here for json — a Connect error body is JSON whatever the
# request's codec was, and the JSON codec itself is void/proto's proto3
# mapping. void/proto is the codec on both sides; void/http is the
# transport, and the only one: a method is a route, so everything that
# already protects a route protects an RPC method.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
