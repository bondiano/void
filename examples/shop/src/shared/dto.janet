### shop/shared/dto — the two response shapes every module's API uses.
###
### A **DTO** in this application is a `defschema`: a declaration of
### what crosses a boundary, registered by name. A **model** (the
### `defentity` in each module) is a declaration of what a table holds.
### They are deliberately different things — the API's `price` is a
### `{:cents :currency}` object, the column is one integer — and the
### projection between them lives in each module's `*.dto.janet`, next
### to the schema it has to satisfy.
###
### `defschema` registering by name is what lets a route say
### `:response {200 :ProductList}` and void/openapi resolve it into a
### component: one declaration, read by the validation middleware and
### by the document.
(import void/core/schema :as schema)

(schema/defschema Money
  "A price, as the two things a client needs to render it."
  {:cents [:int {:min 0}]
   :currency [:string {:min 3 :max 3}]})

(schema/defschema Page
  "The paging block void/rest's pagination convention puts on a list."
  {:page :int :per-page :int :total :int :pages :int})

(defn money
  "Cents, as the API's money value — the constructor for :Money above."
  [cents]
  {:cents cents :currency "EUR"})
