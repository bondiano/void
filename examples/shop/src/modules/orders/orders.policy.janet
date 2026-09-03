### shop/orders/policy — one rule, and the row it decides about.
###
### `:orders/own` is enforced on three surfaces: the HTML order page,
### the JSON endpoint and the admin desk. Before this module existed it
### was declared in one file and its resource loader was written twice;
### now both live here, and a surface that wants the rule imports it
### rather than restating it. **A rule enforced in two places is a rule
### that will disagree with itself.**
(import void/authz :as authz)
(import ./orders.repository :as repo)

(authz/defpolicy :orders/own
  ``A customer sees their own orders, the desk sees all of them.

  A pure function of a context: `:subject/id` falls back to the id
  half of the subject string, `:subject/role` to the claim
  void/auth-db copied off the `customers` row, and
  `:resource/customer-id` to a key of the order. So this policy needs
  no attribute provider and no configuration, and test/policy-test
  runs it as a table of cases with no database and no system
  anywhere.``
  [ctx]
  (or (= (authz/attr ctx :subject/id)
         (string (authz/attr ctx :resource/customer-id)))
      (authz/has-role? ctx :staff)
      "not your order"))

(defn resource
  ``What the policy on an order route decides about: the row itself.
  Route metadata carries a function rather than a symbol, because a
  route entry does not keep the environment of the module that
  declared it.``
  [req]
  (repo/find-by-number (get-in req [:params :number])))

(def own-order
  ``The three keys an order route carries: somebody must be signed in,
  the policy must allow, and this is the row it decides about. Written
  once because it is one rule, not three.``
  {:void.auth/access :required
   :void.authz/policy :orders/own
   :void.authz/resource resource})
