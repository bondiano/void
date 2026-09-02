### auth/dto — what the forms submit.
###
### Projections of the entity rather than copies of it: a field added to
### `auth.model` shows up in the sign-up form with its validation
### already attached, because the schema the form renders *is* the
### schema the table declared (ADR-0008).
(import void/core/schema :as schema)
(import ./auth.model :as model)

(def Registration
  ``The sign-up form. `schema/merge` composes the projection of the
  entity with the one field that has no place in it — the hash is what
  the table stores, and the plaintext exists for exactly the length of
  one request (ADR-0023 §4).``
  (schema/merge (schema/select model/User [:email])
                {:password [:string {:min 8 :max 200}]}))

(def Credentials
  "What the sign-in form submits."
  {:email [:string {:format :email}]
   :password [:string {:min 1 :max 200}]})

(def EmailOnly
  "What the \"mail me a reset link\" form submits — an address, and
  deliberately nothing else."
  {:email [:string {:format :email}]})

(def NewPassword
  "What the change-password form submits."
  {:password [:string {:min 8 :max 200}]})
