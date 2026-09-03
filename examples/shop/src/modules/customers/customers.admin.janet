### shop/customers/admin — the accounts, and the one action this
### application narrows.
###
### **A column left out of `:form` is left out of everywhere.** The
### password hash is a column on `customers` — void/auth-db reads it,
### `void shop seed` writes it — and it is in no list, no detail page,
### no form and no MCP tool, because a declaration is one value and
### both projections read it. Adding it to `:form` is the only way it
### could appear, which is the property worth having.
###
### **Narrowing an action is a `defpolicy` and nothing else.** Every
### admin route already carries `:admin.<resource>/<action>` next to
### the gate; void/admin registers an allowing policy under that name
### only where the application has not defined one. So the two
### policies below change what the desk may do without touching the
### declaration above them, without touching a route, and without a
### single `if` in a handler — and `void authz routes` prints the
### result.
(import void/authz :as authz)
(import void/admin :as admin)
(import ./customers.model :as model)

(admin/defresource-admin customers model/Customer
  :title "Customers"
  # an account is opened at /register by whoever wants one, and it is
  # not deleted from here: orders point at it, and a shop that deleted
  # a customer would be a shop whose invoices lost their buyer
  :only [:index :show :edit :update]
  :list [:id :name :email :role :created-at]
  :detail [:id :name :email :role :created-at]
  :search [:name :email]
  :filters [:role]
  :sortable [:id :name :created-at]
  # `:role` is the whole of this shop's RBAC (customers.model), so the
  # form that edits it *is* the promotion screen — the enum's two
  # members come off the schema, which is why there is no list of them
  # here to fall out of date
  :form [:name :email :role])

(defn- not-yourself
  ``The desk may edit any account but the one it is signed in as.

  A pure function of a context, like every other policy in this
  application: `:subject/id` falls back to the id half of the subject
  string (`customer:7`) and `:resource/id` to a key of the row, so this
  needs no provider, no configuration and no database —
  `test/policy-test.janet` runs it next to `:orders/own`.

  It is a real rule and not a decoration. `role` is the only thing
  standing between a customer and this desk, so the account editing
  it is the one account whose role must not be edited here: a member
  of staff demoting themselves locks the desk behind them, and one
  promoting themselves would not have needed to.``
  [ctx]
  (or (not= (authz/attr ctx :subject/id)
            (string (authz/attr ctx :resource/id)))
      "not your own account — ask another member of staff"))

# One rule, two names, because two routes ask it: the form must not
# open, and the write must not happen even if the form was open when
# the rule changed.
(each action [:edit :update]
  (authz/register-policy!
    {:name (admin/policy-name :customers action)
     :doc "The desk edits any account but its own"
     :fn not-yourself}))
