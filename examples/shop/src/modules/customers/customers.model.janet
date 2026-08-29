### shop/customers/model — who buys things, and who works here.
###
### `role` is the whole of this shop's RBAC: void/auth-db copies the
### column onto the identity's claims at sign-in
### (`[:auth-db :users :claims-columns]` in config/default.janet),
### void/authz reads it back as `:subject/role`, and
### `(authz/role-policy :staff)` is what the admin routes name. No
### table of roles, because there are two.
###
### void/auth-db reads this table; it does not own one. The columns it
### needs are named in the config, and the ones this application added
### for its own reasons (`name`, `created_at`) are none of its
### business.
(import void/db :as db)

(db/defentity Customer
  {:id [:int {:db/pk true :db/type "integer"}]
   :name [:string {:min 1 :max 60 :db/type "text"}]
   :email [:string {:format :email :db/unique true :db/type "text"}]
   :role [:enum "customer" "staff"]
   # a PHC string (`$scrypt$ln=14,r=8,p=1$…`), written by
   # `auth/hash-password` and read by void/auth-db's user store.
   # Optional, because a customer who only ever signs in by the link
   # in a letter never sets one.
   :password-hash [:optional [:string {:db/type "text"}]]
   :created-at [:string {:db/type "text"}]}
  :db/table "customers"
  :db/rels {:orders [:has-many :Order :customer-id]
            :carts [:has-many :Cart :customer-id]})
