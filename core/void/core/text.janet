### void/core/text — the framework's own words, and the seam a catalog
### binds itself into.
###
### void/admin, void/dash and the error pages have text of their own —
### "Save", "Nothing here.", "There is nothing at this address." — and
### none of them may import void/i18n: i18n is a leaf plugin an
### application composes or does not, and a back office that stopped
### working without it would be a back office with a translation
### dependency. The same problem `void/core/schema` had for validation
### messages in wave 0, and the same answer: a **dyn the catalog binds**,
### read by whoever renders.
###
### A package keeps its own `:en` table and asks `t` with it. With a
### catalog bound, the catalog answers — an application's dictionary
### overrides any key of any package without that package knowing. With
### nothing bound, the package's own table answers, which is why
### composing the back office alone still shows English words and not
### keyword names.
###
### The words live in exactly one place per package: the table. Nothing
### is spelled twice, so nothing can drift — a call site carries the key
### and never a fallback string.
###
### The price, said out loud: a catalog does not know these keys exist,
### so `void i18n check` cannot report how much of a package is still
### untranslated. Teaching it would mean registering every table with
### the catalog — a second place the words live — and the package reads
### in English either way, which is the property that matters.
###
### **A refusal renders outside every middleware.** The panic guard is
### phase 0, so by the time a 403 becomes a page the dyns the locale
### middleware bound are gone with the stack that threw. The request
### survives that unwind, so it carries its own scope (`scope-key`) and
### the renderer puts it back with `in-scope`.

# -- the seam ------------------------------------------------------------

(def locale-dyn
  ``The locale of the current scope, as a normalized tag (`:ru`,
  `:pt-BR`) or nil. Declared here rather than in void/i18n because a
  package that renders a page may read it — an error page picks its
  `<html lang>` from it — without depending on the package that sets
  it.``
  :void.i18n/locale)

(def t-dyn
  ``The bound translator: `(fn [key params] string-or-nil)`, nil for a
  key the catalog does not carry. void/i18n binds it to its own `t?`;
  a test binds it to a table lookup. It answers for *every* key,
  including the ones a package owns, which is what makes an
  application's dictionary able to override the framework's words.``
  :void.i18n/t)

(def scope-key
  ``Where a request carries its own locale scope: `(fn [thunk])` that
  binds everything a locale binds, for code that runs after the stack
  which bound them is gone. See `in-scope`.``
  :void.i18n/scope)

(defn locale
  {:params [] :ret :keyword?}
  "The locale of the current scope, or nil when nothing bound one."
  []
  (dyn locale-dyn))

# -- rendering -----------------------------------------------------------

(def- interp-peg
  (peg/compile
    ~{:main (any (+ :esc :ph :text :brace))
      :esc (+ (/ '"{{" "{") (/ '"}}" "}"))
      :ph (group (* "{" '(some (if-not (set "{}") 1)) "}"))
      :text '(some (if-not (set "{}") 1))
      :brace '(set "{}")}))

(defn interpolate
  {:params [:string (or {:keyword :any} :nil)] :ret :string}
  ``Render {name} placeholders of a template from params (keyword
  keys); a missing parameter stays {name} verbatim, {{ and }} are
  literal braces. Positions were rejected in ADR-0036 — a translation
  reorders words, and with them printf's argument order — and a
  missing parameter is visible on the page rather than a crash,
  because an error message renders from attacker-controlled values
  and has no right to reach a 500.``
  [tmpl params]
  (def out @"")
  (each part (peg/match interp-peg tmpl)
    (if (bytes? part)
      (buffer/push out part)
      (let [name (first part)
            v (get (or params {}) (keyword name))]
        (buffer/push out (if (nil? v) (string "{" name "}") (string v))))))
  (string out))

(defn render
  {:params [(or :string {:other :string :one :string? & r}) (or {:keyword :any} :nil)]
   :ret :string}
  ``One entry of a package's own table to a string. A plural entry is
  `{:one "1 row" :other "{count} rows"}` and selects on `(params
  :count)` by **English**'s rule, because a package's own table is
  English: a locale with three plural forms is a locale that has a
  catalog, and the catalog selects by CLDR (void/i18n/plural).``
  [msg params]
  (if (dictionary? msg)
    (interpolate (or (get msg (if (= 1 (get (or params {}) :count)) :one :other))
                     (msg :other))
                 params)
    (interpolate msg params)))

# -- lookup --------------------------------------------------------------

(defn t?
  {:params [:keyword (or {:keyword :any} :nil)] :ret :string?}
  ``What the bound catalog says about `key`, or nil — no fallback of
  any kind. This is how a package translates a key it does **not**
  own: a schema's `:label`, whose words belong to the application that
  wrote the schema, so there is no table here to fall back to.``
  [key &opt params]
  (when-let [f (dyn t-dyn)]
    (f key params)))

(defn t
  {:params [{:keyword (or :string {:other :string :one :string? & r})}
            :keyword (or {:keyword :any} :nil)]
   :ret :string}
  ``One of a package's own strings: the bound catalog first, then
  `dict` — the package's `:en` table — then the key's own name, which
  is visible on the page the way a missing translation is.

  `dict` is passed rather than registered: the table is an ordinary
  value in the package that owns it, and a registry would be a second
  place where the words live.``
  [dict key &opt params]
  (or (t? key params)
      (when-let [msg (get dict key)] (render msg params))
      (string key)))

(defn translator
  {:params [{:keyword (or :string {:other :string :one :string? & r})}]
   :ret (fn [:keyword (or {:keyword :any} :nil)] :string)}
  ``The `t` of one package, with its table closed over:

      (def t (text/translator en))
      (t :void.admin/save)

  Sugar, so a call site carries a key and nothing else.``
  [dict]
  (fn package-t [key &opt params] (t dict key params)))

# -- the scope a refusal is rendered in ----------------------------------

(defn in-scope
  {:params [(or {:keyword :any} :nil) (fn [] a)] :ret a}
  ``Run `thunk` inside the locale scope `req` carries, or plainly when
  it carries none. What puts a locale back for code that runs outside
  the middleware chain: the error renderers, which the phase-0 panic
  guard calls after the stack that bound the locale has unwound.``
  [req thunk]
  (if-let [f (and (dictionary? req) (get req scope-key))]
    (f thunk)
    (thunk)))

(defn humanize
  {:params [:keyword] :ret :string}
  ``A key as a label: `:first-name` -> "First name". The one reading of
  a key as words the framework has — void/html/form re-exports it and
  void/admin titles resources with it — and the fallback under every
  `:label`.``
  [k]
  (def s (string/replace-all "-" " " (string k)))
  (if (empty? s)
    s
    (string (string/ascii-upper (string/slice s 0 1)) (string/slice s 1))))

(defn label-of
  {:params [(or :keyword :string :nil) :keyword] :ret :string}
  ``The words of a `:label` annotation: a keyword is a translation key
  (the application owns those words, so only the catalog answers, and
  without one the fallback is the field's own name), a string is the
  words themselves, and nothing at all humanizes the key.``
  [label key]
  (cond
    (keyword? label) (or (t? label) (humanize key))
    (nil? label) (humanize key)
    (string label)))
