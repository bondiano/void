(import ../void/core/init :as core)

(assert (= core/void-api 1) "plugin API protocol version is 1")
(assert (string? core/version) "version is a string")
(assert (peg/match ~(* "v" :d+ "." :d+ (? (* "." :d+)) -1) core/release-tag)
        "release-tag is vMAJOR.MINOR[.PATCH]")
(assert (string/has-prefix? (string "v" (string/join (take 2 (string/split "." core/version)) "."))
                            core/release-tag)
        "release-tag is a projection of version")

(print "void/core smoke test OK")
