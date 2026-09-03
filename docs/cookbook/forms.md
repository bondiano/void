# Forms → validation → htmx

One map schema is the whole feature: it renders the form, validates
and coerces the submission, and re-renders the same markup with
per-field errors. Nothing is declared twice, so nothing drifts.

The code below is the `void new` scaffold — the same application as
[examples/guestbook](../../examples/guestbook); the fuller version
with entities and a database is
[examples/blog](../../examples/blog/app.janet).

## The schema

```janet
(def Entry
  "A guestbook entry — drives both form/check and form/form."
  {:name [:string {:min 1 :max 40}]
   :message [:string {:min 1 :max 400}]})
```

## The form is a projection

`form/form` renders labeled controls, previous values and error
annotations straight off the schema — and the htmx attributes come
from `hx/post`, so the submit swaps a fragment instead of reloading:

```janet
(defn guestbook-view
  [&opt values errors]
  [:div {:id "guestbook"}
   (form/form Entry
     {:action "/entries"
      :values values
      :errors errors
      :fields {:message {:control :textarea}}
      :submit "Sign"
      :attrs (hx/post "/entries" :target "#guestbook" :swap :outer-html)})
   ...])
```

## The handler validates against the same value

`form/check` coerces and validates the submitted map against `Entry`.
Invalid input re-renders the same view with the raw values and the
errors passed back in — the annotated-form loop is two lines:

```janet
(defn create-entry
  [req]
  (def result (form/check Entry (req :form)))
  (if (empty? (result :errors))
    (do (array/push entries (result :value))
        (html/page (guestbook-view) {:layout layout}))
    (html/page (guestbook-view (req :form) (result :errors))
               {:layout layout})))
```

## The route answers both kinds of request

`:void.htmx/partial` on the route means an htmx swap gets the bare
fragment while a plain form POST (JavaScript off, first load) still
gets the full page — the handler does not branch:

```janet
(router/defroutes :demo/routes
  (GET "/" home)
  (POST "/entries" create-entry
        {:name :entries/create :void.htmx/partial true}))
```

## With a database

In [examples/blog](../../examples/blog/entities.janet) the schema is a
`db/defentity` — the same node is also the table mapping, and the form
DTO is `schema/select` over it, so a renamed field updates the form, the
validation and the migration comparison in one edit. `void make
resource` ([Getting started](../GETTING-STARTED.md)) scaffolds exactly
this arrangement.

Two things the scaffold already handled that you would otherwise meet
later: CSRF — with `void/security` composed, the signed token is
spliced into every non-GET form through a slot `form/form` has carried
since wave 1; and translated error messages — `void/i18n` swaps the
schema-error texts per request locale with zero changes in the form
code.
