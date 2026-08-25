(import ../void/core/init :as core)

(assert (= core/void-api 1) "plugin API protocol version is 1")
(assert (string? core/version) "version is a string")

(print "void/core smoke test OK")
