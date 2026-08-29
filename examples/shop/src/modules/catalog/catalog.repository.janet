### shop/catalog/repository — every query about a product, and nothing
### else.
###
### The repository is the layer that knows there is a database. It
### takes and returns rows and numbers, it never sees a request, a
### session or an identity, and it holds no rule that a shop could
### change its mind about — that is ./catalog.service.
###
### Two functions here are not lookups, and they are the interesting
### ones: `reserve-stock!` and `release-stock!` are the two halves of
### what a checkout does to a shelf, written as SQL because the
### statement *is* the guarantee.
(import void/db :as db)
(import ./catalog.model :as model)

(defn find-by-id
  "One product by primary key, or nil."
  [id]
  (db/find model/Product id))

(defn find-by-sku
  "One product by the code a human quotes, or nil."
  [sku]
  (db/one model/Product {:where [:= :sku sku]}))

(defn active
  "Every product on sale, in sku order — the storefront's whole list."
  []
  (db/query model/Product {:where [:= :status "active"]
                           :order-by [[:sku :asc]]}))

(defn count-active
  "How many products are on sale — the total the API's paging block
  needs."
  []
  (db/count model/Product {:where [:= :status "active"]}))

(defn page-active
  ``One page of the catalog: `{:order-by :limit :offset}` the way
  void/rest's pagination convention produced it.``
  [opts]
  (db/query model/Product
            {:where [:= :status "active"]
             :order-by (get opts :order-by [[:sku :asc]])
             :limit (get opts :limit 25)
             :offset (get opts :offset 0)}))

(defn create!
  "Put a product on sale. Used by the seed, and by nobody else."
  [spec]
  (db/insert! model/Product (merge spec {:status "active"})))

(defn reserve-stock!
  ``Take `quantity` off the shelf, or answer false.

  Not read-modify-write:

      UPDATE products SET stock = stock - 2
       WHERE id = ? AND status = 'active' AND stock >= 2

  Either the row is written or it is not, the database decides, and
  the answer is the affected-row count. Two checkouts racing for the
  last unit both run this statement; exactly one of them writes.
  Reading the stock first and deciding in janet is the version of this
  code that oversells on a Friday.

  The quantity is an integer that came through a schema
  (`cart.dto/AddToCart`), which is why it can be spliced into the
  expression — the builder puts values in parameters and has no
  arithmetic, and `[:raw]` is the seam for the SQL it does not
  generate.``
  [product-id quantity]
  (pos?
    (db/execute!
      {:update "products"
       :set {:stock [:raw (string "stock - " quantity)]}
       :where [:and
               [:= :id product-id]
               [:= :status "active"]
               [:>= :stock [:val quantity]]]})))

(defn release-stock!
  ``Put `quantity` back on the shelf. The mirror image of
  `reserve-stock!`, and the reason it needs no condition: giving stock
  back can always succeed.``
  [product-id quantity]
  (db/execute! {:update "products"
                :set {:stock [:raw (string "stock + " quantity)]}
                :where [:= :id product-id]}))
