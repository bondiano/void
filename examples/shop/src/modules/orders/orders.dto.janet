### shop/orders/dto — what an order looks like on the way out.
###
### The schemas and the projections that satisfy them, in one file. The
### shapes are not the columns: `total-cents` becomes a `:Money`, the
### line total is computed rather than stored, and `customer-id` never
### appears — a client reading its own orders does not need to be told
### whose they are.
(import void/core/schema :as schema)
(import ../../shared/dto :as shared)

(schema/defschema OrderLineView
  "One line of an order, as the API shows it."
  {:sku :string
   :name :string
   :quantity :int
   :unit-price [:ref :Money]
   :line-total [:ref :Money]})

(schema/defschema OrderView
  "One order, as the API shows it."
  {:number :string
   :status [:enum "placed" "paid" "shipped" "cancelled"]
   :placed-at :string
   :total [:ref :Money]
   :items [:vector [:ref :OrderLineView]]})

(schema/defschema OrderList
  "Every order of the caller, newest first."
  {:data [:vector [:ref :OrderView]]})

(defn order-line-view [item]
  {:sku (item :sku)
   :name (item :name)
   :quantity (item :quantity)
   :unit-price (shared/money (item :unit-price-cents))
   :line-total (shared/money (* (item :quantity) (item :unit-price-cents)))})

(defn order-view [order items]
  {:number (order :number)
   :status (order :status)
   :placed-at (order :placed-at)
   :total (shared/money (order :total-cents))
   :items (map order-line-view items)})
