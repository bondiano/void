(import ../void/core/keys :as keys)

# The names are the keywords they always were: a package that reads one
# through this module and a package that still writes the literal meet
# in the same place, which is what makes the migration safe.
(assert (= :void.auth/identity keys/identity))
(assert (= :void.html/csrf keys/csrf-field))
(assert (= :void/route keys/route))
(assert (= :void.db/row keys/row))
(assert (= :request-id keys/request-id))

(assert (deep= {} (keys/route-meta {})) "no route matched: an empty table, not nil")
(assert (deep= {} (keys/route-meta {:void/route {}})) "a route with no metadata")
(assert (= true (get (keys/route-meta {:void/route {:meta {:void.db/txn true}}})
                     :void.db/txn))
        "and the metadata when there is some")

(print "keys-test: all assertions passed")
