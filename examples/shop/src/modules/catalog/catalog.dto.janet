### shop/catalog/dto — what a product looks like on the way out.
###
### The schema says what the document promised; the function under it
### is the projection that keeps the promise. They are in one file on
### purpose: a response shape that is declared in one place and built
### in another is a response shape that drifts, and the drift is only
### found by whoever is reading the JSON.
###
### Note what the DTO is not: the columns. `price-cents` becomes a
### `:Money` object, `stock` becomes `in-stock`, and `status` does not
### appear at all — an archived product is simply not returned
### (catalog.service/on-sale). A client should not have to know the
### shape of a table to read a catalog.
(import void/core/schema :as schema)
(import ../../shared/dto :as shared)

(schema/defschema ProductView
  "One product, as the API shows it."
  {:id [:int {:min 1}]
   :sku :string
   :name :string
   :description :string
   :price [:ref :Money]
   :in-stock :int})

(schema/defschema ProductList
  "A page of products."
  {:data [:vector [:ref :ProductView]]
   :page [:ref :Page]})

(defn product-view
  "One product row, in the shape :ProductView describes."
  [p]
  {:id (p :id)
   :sku (p :sku)
   :name (p :name)
   :description (p :description)
   :price (shared/money (p :price-cents))
   :in-stock (p :stock)})
