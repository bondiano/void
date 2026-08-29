### The policies, as a table of cases — with no database, no HTTP and
### no system anywhere.
###
### That is the whole argument for `defpolicy` (ADR-0024 §1): a policy
### is a **pure function of a context**, so the interesting half of
### authorization is tested the way arithmetic is. What the routes then
### do with it (which policy, over which resource) is checked once, in
### the suites that boot the application.
###
### Note what these cases never mention: a request, a session, a route,
### a plugin. `:subject/id` falls back to the id half of the subject
### string and `:resource/customer-id` to a key of the row, so a
### "context" here is two literals.

(import ../test-support/paths)
(import void/core/log :as log)
(import void/authz :as authz)
# loaded for their effect: a policy is declared by the module it is
# about, and these two are the whole of this application's
(import ../src/modules/customers/customers.policy)
(import ../src/modules/orders/orders.policy)

# every denial below is deliberate, and a decision is logged
(log/set-sinks! [(fn [_])])

(defn- customer
  ``An identity, the shape void/auth-db builds one in: the subject
  string plus the claims copied off the row at sign-in ([:auth-db
  :users :claims-columns] in config/default.janet).

  The role is a claim here for the same reason it is one in a session:
  it is already known. A **token**-borne identity has no such claim,
  and the attribute provider in customers.policy reads the row when a policy
  asks — that path needs a database, so it is tested where there is
  one (test/api-test.janet).``
  [id role]
  {:subject (string "customer:" id)
   :claims {:role role}})

(def ada (customer 1 "customer"))
(def mallory (customer 2 "customer"))
(def desk (customer 3 "staff"))

(def order {:number "SH-0001" :customer-id 1 :total-cents 1400})

# -- :orders/own ---------------------------------------------------------

(def cases
  [[ada order true "the customer who placed it"]
   [mallory order false "anybody else"]
   [desk order true "the desk, because :staff is part of the same policy"]
   [nil order false "and a request with no identity at all"]])

(each [subject resource allowed why] cases
  (def decision (authz/decide :orders/own {:subject subject :resource resource}))
  (assert (= allowed (decision :allow))
          (string ":orders/own — " why))
  (unless allowed
    (assert (string? (decision :reason))
            "a denial carries a reason, and it is the one the log and `void authz explain` print")))

# the reason a policy gives is a string a person can read, and it never
# reaches the response body (ADR-0024 §4)
(assert (= "not your order"
           ((authz/decide :orders/own {:subject mallory :resource order}) :reason)))

# -- :staff --------------------------------------------------------------

(assert (authz/can? :staff {:subject desk}))
(assert (not (authz/can? :staff {:subject ada})))
(assert (not (authz/can? :staff {:subject nil})))

# -- what a decision looked at -------------------------------------------
#
# Attributes are pulled, so a decision knows what it read — which is
# how the cost of a policy is read off it rather than guessed.

(def ctx (authz/make-context {:subject mallory :resource order}))
(authz/decide :orders/own {:context ctx})
(def read-attrs (authz/used-attributes ctx))
(assert (index-of :subject/id read-attrs))
(assert (index-of :resource/customer-id read-attrs))
(assert (nil? (index-of :subject/email read-attrs))
        "and it did not read the address, because no policy asked — which is what pull-based attributes buy")

(log/set-sinks! nil)
(print "shop policy-test ok")
