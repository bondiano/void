### void/authz/rbac — roles as sugar over ABAC (ADR-0024 §7).
###
### There is no second enforcement path here and no second kind of
### policy. A role is an **attribute of the subject** and a permission
### is a **policy**; this module is a table of roles and three
### predicates for policy bodies:
###
###     {:authz {:roles {:admin [:*]
###                      :manager [:orders/read :orders/write]
###                      :support [:orders/read]}}}
###
###     (defpolicy :orders/write
###       [ctx] (authz/permitted? ctx :orders/write))
###
### `(authz/role-policy :admin)` is the shortcut for a route that only
### needs a role, and it produces an ordinary policy function — one
### that `explain` prints like any other.
###
### The subject's roles come from `:subject/roles` (a list) or
### `:subject/role` (one), which by default read the identity's claims
### and can be replaced by a provider that goes to the database. `:*`
### is "everything" and is meant for exactly one role.

(import ./context :as context)

(var roles
  "Role -> permissions, from [:authz :roles]. Set by the plugin at
  :before-start."
  {})

(defn roles-of
  ``The roles of the context's subject: `:subject/roles` if there is
  one, else `:subject/role` as a list of one, else nothing.``
  [ctx]
  (def many (context/attr ctx :subject/roles))
  (cond
    (indexed? many) (map keyword many)
    many [(keyword many)]
    (if-let [one (context/attr ctx :subject/role)] [(keyword one)] [])))

(defn has-role?
  "Does the subject hold this role (or any of these roles)?"
  [ctx role]
  (def held (roles-of ctx))
  (if (indexed? role)
    (truthy? (some |(index-of $ held) role))
    (truthy? (index-of role held))))

(defn permissions-of
  "Every permission the subject's roles grant, as a set-shaped table."
  [ctx]
  (def out @{})
  (each r (roles-of ctx)
    (each p (get roles r [])
      (put out p true)))
  out)

(defn permitted?
  ``Does any of the subject's roles grant this permission? `:*` in a
  role's list grants everything, which is what an :admin role is for
  and what every other role should not have.``
  [ctx permission]
  (def granted (permissions-of ctx))
  (truthy? (or (granted :*) (granted permission))))

(defn role-policy
  ``A policy function that allows exactly the holders of `role` — the
  shortcut for a route that needs nothing cleverer:

      (authz/register-policy! {:name :admin :fn (authz/role-policy :admin)})``
  [role]
  (fn role-check [ctx]
    (or (has-role? ctx role)
        (string/format "subject does not hold role %q" role))))

(defn permission-policy
  "A policy function that allows whoever the role table grants
  `permission` to."
  [permission]
  (fn permission-check [ctx]
    (or (permitted? ctx permission)
        (string/format "no role of this subject grants %q" permission))))
