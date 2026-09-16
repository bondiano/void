### void/core/keys — the keys a request and its dyns are read by.
###
### A handful of values travel on the request map (or on a dyn beside
### it) from the package that puts them there to packages that only
### read them, and reading one is deliberately *not* importing the
### writer: void/authz reads the current identity without importing
### void/auth, which is what lets an application keep its own
### authentication and still use void's authorization.
###
### The indirection is right; the way it was spelled was not. Each
### reader re-declared the keyword with its own docstring explaining
### the trick — `:void.auth/identity` four times, `:void.html/csrf` not
### at all (four literal sites and no name) — so the convention lived
### in prose and a renamed key would have been found by grep, if at
### all.
###
### Here they are named once. void/core is every package's dependency
### already, so importing this costs nothing that the literal did not,
### and a reader has one place to learn what is on a request.
###
### Route *metadata* keys are not here: they have a registry of their
### own (`:void.http/route-meta-key`, and docs/CONTRACTS.md lists
### them). This module is the request itself.

(def identity
  ``The authenticated identity of this request, as a dyn and as a
  request key. void/auth binds it (`auth/identity/dyn-key`); void/authz,
  void/mcp-http, void/notify-inapp, void/security and void/i18n read
  it. An application with its own authentication that binds this key
  gets all of them.``
  :void.auth/identity)

(def csrf-field
  ``A thunk returning the hidden CSRF input as hiccup, bound around the
  handler by void/security for the length of one request. `form/form`
  splices it into every non-GET form; void/admin and void/dash splice
  it into theirs. Unbound means no CSRF plugin is composed, and a form
  renders without the field rather than failing.``
  :void.html/csrf)

(def route
  ``The route this request matched: `{:name :meta :params ...}`, put
  there by void/http's router. `route-meta` below is how it is almost
  always read.``
  :void/route)

(def row
  ``The row a route's `:void.db/load` loaded, put there by void/db-http
  before the handler. A `:void.authz/resource` reads it instead of
  querying again.``
  :void.db/row)

(def request-id
  ``The id minted for this request by void/http (phase 50) and bound
  into the log context. void/obs puts it on a span; a handler that
  answers "which request was that?" prints it.``
  :request-id)

(defn route-meta
  ``The matched route's metadata, or an empty table when nothing
  matched — five packages had written this same `get-in` before their
  `:when` or their wrapper could ask a question of it.``
  [req]
  (get-in req [route :meta] {}))
