### shop/cart/dto — what the two cart forms submit.
###
### These are the inbound half of the DTO story: a schema the form is
### *projected from* (`form/form` in ./cart.view renders the fields off
### it) and *validated against* (`form/check` in ./cart.controller
### coerces the strings a browser sends). One declaration, both ends.
###
### The price is deliberately absent from both. A form that carried one
### would be a form the customer could edit, and the checkout re-reads
### every price from the products table anyway
### (orders/orders.service).

(def AddToCart
  "What the \"add to cart\" form submits."
  {:product-id [:int {:min 1}]
   :quantity [:int {:min 1 :max 99}]})

(def SetQuantity
  "What the quantity control on the cart page submits (0 removes)."
  {:quantity [:int {:min 0 :max 99}]})
