### shop/customers/policy — the role, and where a decision gets it from.
###
### A policy is a **pure function of a context** (ADR-0024 §1), which
### is why it lives next to the model it is about rather than in the
### routes that enforce it: `test/policy-test.janet` runs the ones in
### this application as a table of cases with no database, no HTTP and
### no system anywhere.
(import void/authz :as authz)
(import void/auth :as auth)
(import ./customers.repository :as repo)

(authz/register-policy!
  {:name :staff
   :doc "The admin desk: whoever holds the staff role (the `role` column on customers)"
   :fn (authz/role-policy :staff)})

(authz/register-provider!
  {:name :shop/customer
   :for :subject
   # the full keys, the way a decision asks for them
   :keys [:subject/role :subject/email]
   :doc "The role and address of the customer behind the subject, read when a policy asks and not before"
   :fn
   (fn customer-attrs [ctx]
     ``Attributes are **pulled** (ADR-0024 §2), and this provider is
     why that matters here.

     A session identity already carries `role` as a claim: void/auth-db
     copied it off the row at sign-in ([:auth-db :users
     :claims-columns]), so the nav bar and the admin routes decide
     without a query, and this provider returns nothing.

     An **API token** does not. A token minted a month ago carries
     whatever was true a month ago, and a role that changed yesterday
     has to win — so when the claim is absent the row is read, once per
     decision, only for the requests whose policy actually asks about a
     role. A design that pushed the role into every context would pay
     for the query on every catalog request; one that trusted the token
     would let a demoted account keep the desk.``
     (def id (get ctx :subject))
     (def claimed (get-in id [:claims :role]))
     (if claimed
       {}
       (when-let [subject (get id :subject)
                  cid (scan-number (last (auth/subject-of subject)))
                  row (repo/find-by-id cid)]
         {:role (row :role) :email (row :email)})))})
