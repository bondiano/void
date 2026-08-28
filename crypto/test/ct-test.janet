(import ../test-support/paths)
(import void/crypto/lib :as lib)
(import void/crypto/ct :as ct)

(lib/load!)

(assert (ct/equal? "abc" "abc"))
(assert (ct/equal? "" ""))
(assert (not (ct/equal? "abc" "abd")) "one byte apart at the end")
(assert (not (ct/equal? "abc" "bbc")) "one byte apart at the start")
(assert (not (ct/equal? "abc" "abcd")) "a prefix is not equal")
(assert (not (ct/equal? "abcd" "abc")))

# buffers and strings compare by content — every token in void arrives
# as one and is stored as the other
(assert (ct/equal? @"secret" "secret"))
(assert (ct/equal? (string/repeat "\x00" 32) (string/repeat "\x00" 32))
        "and a NUL is a byte like any other, not a terminator")
(assert (not (ct/equal? (string "a\x00b") (string "a\x00c"))))

(print "ct-test ok")
