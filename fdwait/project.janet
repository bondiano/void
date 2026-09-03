(declare-project
  :name "void-fdwait"
  :description "void/fdwait — readiness on a foreign file descriptor: park a fiber until a descriptor owned by a C library is readable or writable, without touching it (Appendix A). The primitive void/db-postgres is built on."
  :version "0.0.1")

# The only native module in the monorepo, and deliberately small: what
# Janet cannot express, and nothing else. Building it needs a C
# compiler and janet.h — a plugin that depends on it says so.

(declare-native
  :name "void/fdwait/native"
  :source ["src/fdwait.c"])

(declare-source
  :source ["void"])
