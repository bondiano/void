(declare-project
  :name "void-tls"
  :description "void/tls — outbound TLS from the system libssl through ffi: a memory-BIO pump on the ev loop, verification and SNI on by construction, and the seams that make https://, rediss://, STARTTLS and smtps work across the framework.")

# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet): see test-support/paths.janet.

(declare-source
  :source ["void"])
