(declare-project
  :name "void-crypto"
  :description "void/crypto — every cryptographic primitive void has, from the system libcrypto through ffi: SHA-2, HMAC, scrypt/argon2id/PBKDF2 off the event loop, RS256/ES256 signatures, constant-time comparison and OS randomness."
  :version "0.0.1")

# libcrypto is not a jpm dependency and nothing here is compiled: the
# library is opened at runtime through ffi/ from a configured path
# ([:crypto :libcrypto]), so the plugin installs on a machine without
# OpenSSL and says so at :start rather than at install time — the same
# arrangement void/db-postgres has with libpq.
#
# What has to be on the module path is a projection of the package graph
# (scripts/packages.janet), not prose: see
# test-support/paths.janet.

(declare-source
  :source ["void"])
