### void/authz/policy — the registry of named policies (ADR-0024 §1).
###
### A policy is a **pure function of one context** registered under a
### keyword:
###
###     (defpolicy :orders/read
###       "An order is visible inside its own brand; support reads all."
###       [ctx]
###       (or (authz/has-role? ctx :support)
###           (= (authz/attr ctx :subject/brand-id)
###              (authz/attr ctx :resource/brand-id))))
###
### The body is ordinary Janet rather than a data-expression language,
### because "more expressive" and "a second language to debug" are the
### same decision made twice (ADR-0004). What makes the system
### inspectable is the **registry**, not the shape of the body:
### `(authz/policies)` lists what exists, `void authz policies` prints
### it, and route metadata refers to a policy by keyword, so the route
### table shows where each one is enforced.
###
### Purity is a contract, not a wish: a policy does not query anything.
### Whatever needs I/O arrives as an attribute (./context), which is
### what lets a policy be tested as a table of cases with no system
### running and no database anywhere.
###
### A policy answers `true`, `false`, or a **string** — the string is
### the reason it said no, and it is for the decision log and
### `void authz explain`, never for the client (ADR-0024 §3).

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

(def registry
  "Registered policies, by name."
  @{})

(defn normalize
  "Validate a policy declaration: {:name :fn :doc?}."
  [p]
  (unless (dictionary? p)
    (errorf "a policy must be a dictionary, got %q" p))
  (def name (get p :name))
  (unless (keyword? name)
    (errorf "a policy needs a keyword :name, got %q" name))
  (unless (callable? (get p :fn))
    (errorf "policy %q: :fn must be a function, got %q" name (get p :fn)))
  (freeze (merge @{:doc nil} p)))

(defn register!
  "Register (or replace) a policy. Returns its name — replacing is how
  a REPL redefinition takes effect without a restart (ADR-0002)."
  [p]
  (def n (normalize p))
  (put registry (n :name) n)
  (n :name))

(defn deregister!
  "Remove a policy."
  [name]
  (put registry name nil)
  nil)

(defn lookup
  "One policy by name, or nil."
  [name]
  (get registry name))

(defn policy!
  "One policy by name, or an error naming what is registered — the
  message a typo in route metadata deserves."
  [name]
  (or (lookup name)
      (errorf "unknown policy %q (registered: %s)" name
              (string/join (map string (sorted (keys registry))) " "))))

(defn policies
  "Every registered policy name, sorted."
  []
  (sorted (keys registry)))

(defn describe
  "Name, docstring and source of every policy — what `void authz
  policies` prints and what an audit reads."
  []
  (seq [name :in (policies) :let [p (lookup name)]]
    {:name name :doc (p :doc)}))

(defmacro defpolicy
  ``Define and register a policy:

      (defpolicy :orders/read
        "docstring"
        [ctx]
        body...)

  Sugar over `register!` (ADR-0004): the macro adds nothing the data
  form cannot express, and the function it registers is an ordinary
  one — testable by calling it with a context.``
  [name & body]
  (def doc (when (string? (first body)) (first body)))
  (def rest (if doc (tuple ;(slice body 1)) body))
  (def params (first rest))
  (unless (and (indexed? params) (= 1 (length params)))
    (errorf "defpolicy %q takes exactly one parameter, the context" name))
  ~(,register! {:name ,name
                :doc ,doc
                :fn (fn ,(symbol "policy" (string name)) ,params ,;(tuple ;(slice rest 1)))}))
