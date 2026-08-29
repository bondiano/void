### shop/customers/dto — the three ways in, as three schemas.
###
### `Registration` is the one worth reading: `schema/merge` composes a
### **projection of the model** with the one field that has no place in
### it. The hash is what the table stores, and the plaintext exists for
### exactly the length of one request (ADR-0023 §4) — so it is in the
### DTO and not in the model, which is precisely the distinction the
### two files are for.
(import void/core/schema :as schema)
(import ./customers.model :as model)

(def Registration
  "What the sign-up form submits: a customer, plus a password that is
  not a column."
  (schema/merge (schema/select model/Customer [:name :email])
                {:password [:string {:min 8 :max 200}]}))

(def Credentials
  "What the sign-in form submits."
  {:email [:string {:format :email}]
   :password [:string {:min 1 :max 200}]})

(def MagicLink
  ``What the "mail me a link" form submits — an address and nothing
  else. There is no password here on purpose: this is the form for the
  customer who does not have one to hand.``
  {:email [:string {:format :email}]})
