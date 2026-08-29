### shop/catalog/model — what the shop sells, declared once.
###
### `defentity` is a schema plus a db-mapping (ADR-0009): the binding
### *is* the normalized schema, so `schema/select` projects a form off
### it, while the table, the primary key, the columns and the relations
### live in a descriptor the repository, `:preload`, `void db erd` and
### void/openapi all read.
###
### The `:db/*` props are annotations: parsed and stored, never
### consulted by validation (ADR-0008). `:db/type` is the column type
### the migration actually created, so `void db erd` says `text` and
### not `value`.
###
### This file is the only one in the module that names a table. Every
### query about a product is in ./catalog.repository, and nothing above
### the repository knows the word "products".
(import void/db :as db)

(db/defentity Product
  {:id [:int {:db/pk true :db/type "integer"}]
   :sku [:string {:min 1 :max 40 :db/unique true :db/type "text"}]
   :name [:string {:min 1 :max 120 :db/type "text"}]
   :description [:string {:min 1 :max 2000 :db/type "text"}]
   # cents. See src/shared/values.janet.
   :price-cents [:int {:min 0 :db/type "integer"}]
   # the number the checkout is allowed to sell. Decremented by a
   # conditional UPDATE in ./catalog.repository, never by a
   # read-modify-write.
   :stock [:int {:min 0 :db/type "integer"}]
   # "active" or "archived" — text and not a boolean on purpose: the
   # two drivers disagree about what a boolean column reads back as,
   # and a demo that claims one application on two engines does not
   # get to have a `case` on the dialect in a template
   :status [:enum "active" "archived"]}
  :db/table "products"
  :db/rels {:cart-items [:has-many :CartItem :product-id]})
