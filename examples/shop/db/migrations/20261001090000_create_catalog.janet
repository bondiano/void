# Migrations are SQL as data, DDL included: `void/db/builder` compiles
# this for whichever engine is running, so `[:id :serial {:primary-key
# true}]` is `"id" integer PRIMARY KEY` on sqlite and `"id" serial
# PRIMARY KEY` on Postgres and the file says neither.
#
# They are also deliberately self-contained — they run against the
# database as it was, not against today's entities. A migration that
# projected `defentity` would rewrite its own history every time a field
# changed (generation from the entity registry is a v2 story).

(defn up []
  [{:create-table "customers"
    :columns [[:id :serial {:primary-key true}]
              [:name :text {:null false}]
              [:email :text {:null false :unique true}]
              # "customer" or "staff" — this shop's whole RBAC, and a
              # column rather than a table because there are two of them
              [:role :text {:null false :default "customer"}]
              # a PHC string; nullable, because a customer who signs in
              # by the link in a letter never sets a password
              [:password-hash :text]
              # text, not :timestamptz, on purpose: the application
              # writes ISO-8601 strings so that a row reads the same on
              # both engines (see src/shared/values.janet)
              [:created-at :text {:null false}]]}

   {:create-table "products"
    :columns [[:id :serial {:primary-key true}]
              [:sku :text {:null false :unique true}]
              [:name :text {:null false}]
              [:description :text {:null false}]
              # money is an integer number of cents everywhere in this
              # application, including here
              [:price-cents :int {:null false}]
              [:stock :int {:null false :default 0}]
              [:status :text {:null false :default "active"}]]}

   {:create-index "products_status_idx" :on "products" :columns [:status]}])

(defn down []
  [{:drop-table "products"}
   {:drop-table "customers"}])
