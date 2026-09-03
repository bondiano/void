### shop/catalog/model — what the shop sells, declared once.
###
### `defentity` is a schema plus a db-mapping: the binding
### *is* the normalized schema, so `schema/select` projects a form off
### it, while the table, the primary key, the columns and the relations
### live in a descriptor the repository, `:preload`, `void db erd` and
### void/openapi all read.
###
### The `:db/*` props are annotations: parsed and stored, never consulted
### by validation. `:db/type` is the column type the migration actually
### created, so `void db erd` says `text` and not `value`.
###
### This file is the only one in the module that names a table. Every
### query about a product is in ./catalog.repository, and nothing above
### the repository knows the word "products".
### The import of `void/storage` below is not decoration: `:file` is a
### schema type this package registers when its module loads, and a
### `defentity` normalizes its schema right there — so the entity that
### uses the type has to have loaded the module that registers it
### (the void/proto pose).
(import void/db :as db)
(import void/storage)

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
   :status [:enum "active" "archived"]
   # The picture, and the whole of what this application says about
   # uploads. What the column holds is a storage **key**, so the same row
   # works against a disk in development and against the minio bucket the
   # compose file runs — `storage/url` is what turns it into an address.
   # The three annotations are read by the form projection and by the
   # admin widget and ignored by validation, exactly like the `:db/*` ones
   # above: the accept list is enforced on the server as well as rendered
   # into the input, because a browser filters politely and a request is
   # bytes anybody assembled.
   :image [:optional [:file {:db/type "text"
                             :storage/prefix "products"
                             :storage/accept ["image/png" "image/jpeg" "image/webp"]
                             :storage/max-bytes 2097152}]]}
  :db/table "products"
  :db/rels {:cart-items [:has-many :CartItem :product-id]})
