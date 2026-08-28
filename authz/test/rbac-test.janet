(import ../test-support/paths)
(import void/authz/context :as context)
(import void/authz/policy :as policy)
(import void/authz/decide :as decide)
(import void/authz/rbac :as rbac)
(import void/core/log :as log)

(log/set-level! "void.authz" :error)

(set rbac/roles {:admin [:*]
                 :manager [:orders/read :orders/write]
                 :support [:orders/read]})

(defn- ctx-for [claims]
  (context/make {:subject {:subject "user:1" :claims claims}}))

# -- roles are an attribute of the subject -------------------------------

(assert (deep= [:manager] (tuple ;(rbac/roles-of (ctx-for {:role :manager})))))
(assert (deep= [:manager :support]
               (tuple ;(rbac/roles-of (ctx-for {:roles [:manager :support]}))))
        ":subject/roles wins when there is one")
(assert (empty? (rbac/roles-of (ctx-for {}))) "and a subject with neither holds none")
(assert (deep= [:manager] (tuple ;(rbac/roles-of (ctx-for {:role "manager"}))))
        "a role that arrived as a string from a database column is still a role")

(assert (rbac/has-role? (ctx-for {:role :manager}) :manager))
(assert (not (rbac/has-role? (ctx-for {:role :manager}) :admin)))
(assert (rbac/has-role? (ctx-for {:role :manager}) [:admin :manager]) "any of these")
(assert (not (rbac/has-role? (ctx-for {}) :manager)))

# -- permissions come from the table -------------------------------------

(assert (rbac/permitted? (ctx-for {:role :manager}) :orders/read))
(assert (rbac/permitted? (ctx-for {:role :manager}) :orders/write))
(assert (not (rbac/permitted? (ctx-for {:role :support}) :orders/write)))
(assert (rbac/permitted? (ctx-for {:role :admin}) :anything/at-all) ":* grants everything")
(assert (not (rbac/permitted? (ctx-for {:role :nobody}) :orders/read))
        "a role that is not in the table grants nothing")
(assert (rbac/permitted? (ctx-for {:roles [:support :manager]}) :orders/write)
        "several roles are the union of their permissions")

# -- and they are ordinary policies --------------------------------------

(policy/register! {:name :admin-only :fn (rbac/role-policy :admin)})
(policy/register! {:name :can-write :fn (rbac/permission-policy :orders/write)})

(assert (decide/can? :admin-only {:subject {:subject "u:1" :claims {:role :admin}}}))
(def denied (decide/decide :admin-only {:subject {:subject "u:1" :claims {:role :support}}}))
(assert (not (denied :allow)))
(assert (string/find "admin" (denied :reason)) "with a reason a human can read")

(assert (decide/can? :can-write {:subject {:subject "u:1" :claims {:role :manager}}}))
(assert (not (decide/can? :can-write {:subject {:subject "u:1" :claims {:role :support}}})))

# a role policy is a policy like any other: it explains the same way
(def out (decide/explain [:admin-only] {:subject {:subject "u:1" :claims {:role :support}}}))
(assert (not (out :allow)))
(assert (= :admin-only (out :policy)))
(assert (index-of :subject/role (out :attrs))
        "and it reads the role through the attribute machinery, so a provider can replace where roles come from")

(print "rbac-test ok")
