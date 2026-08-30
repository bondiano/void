(declare-project
  :name "void-proto"
  :description "void/proto — protobuf in pure Janet: the wire format, a codec over descriptors as data, the proto3 JSON mapping, a `.proto` parser on PEG, and the schema layer projected in both directions (SPEC §5.7, ADR-0013)."
  :version "0.0.1"
  :dependencies ["https://github.com/janet-lang/spork.git"])

# spork is here for json (the proto3 JSON mapping is JSON, and the
# repository has one encoder) and for base64, which is how that mapping
# spells a `bytes` field — an alphabet rather than cryptography, the
# same reason void/ws declares it.
#
# There is no edge to void/http: a protobuf codec has no transport, and
# the one that does is void/grpc. void/core is here for the schema layer
# — void/proto/schema registers two custom types and the :proto
# projection, which is SPEC §3.3's "protobuf descriptor" row.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet, ADR-0020), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
