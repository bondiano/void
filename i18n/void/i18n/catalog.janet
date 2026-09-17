### void/i18n/catalog — the merged dictionary index and the current
### locale.
###
### The index is data in this module, not a component: a catalog has no
### resource and no lifetime. `install!` merges the :void.i18n/messages
### contributions by ascending :precedence (default 100; the shipped
### dictionaries contribute at 0, so an application overrides them
### without naming a number — the :phase-of-middleware posture, with
### the deterministic resolution order as the tie-break), runs the
### boot gates and prebuilds one
### :void.schema/messages table per configured locale, so the
### middleware binds a table rather than building closures per request.
###
### `t` looks a key up along locale -> its primary language -> the
### default locale; a key found nowhere renders as its own name, warns
### once, and `void i18n check` is the coverage gate that turns that
### page-visible artifact into a CI failure.

(import void/core/log :as log)
(import void/core/text :as text)
(import ./locale :as locale)
(import ./plural :as plural)
(import ./message :as message)

(def- log-ns "void.i18n")

(def locale-dyn
  ``The dyn the request's locale lives in — `void/core/text`'s, so that
  a package which only *reads* a locale (an error page choosing its
  `<html lang>`) reads it from the core seam and not from this plugin.
  Named rather than passed: the render middleware, mail/send and
  anything the handler spawns see it without importing void/i18n — the
  :void.auth/identity convention.``
  text/locale-dyn)

# -- installed state -----------------------------------------------------

(var settings
  "The [:i18n] slice as installed at :before-start (locales and
  default normalized)."
  nil)

(var index
  "locale -> key -> message, merged from :void.i18n/messages by
  ascending :precedence (ties in resolution order)."
  nil)

(var plural-rules
  "Primary language -> rule: the shipped table plus :void.i18n/plural
  contributions."
  plural/rules)

(var source-hook
  "The resolved :void.i18n/locale-source contribution, or nil."
  nil)

(var schema-tables
  "locale -> {code (fn [err] string)}, prebuilt for the middleware to
  bind as (dyn :void.schema/messages)."
  nil)

(var error-tables
  "locale -> {kind (fn [envelope] string)}, prebuilt for the middleware
  to bind as (dyn :void.errors/messages)."
  nil)

# -- lookup and rendering ------------------------------------------------

(defn current-locale
  {:params [] :ret :keyword}
  "The bound locale, or the configured default, or :en."
  []
  (or (dyn locale-dyn) (get (or settings {}) :default) :en))

(defn- chain
  {:params [:keyword] :ret @[:keyword]}
  "The locale's fallback chain: itself, its primary language, the
  default locale and its primary — deduplicated, in that preference
  order."
  [loc]
  (def d (get (or settings {}) :default))
  (distinct (filter |(not (nil? $))
                    [loc (locale/primary loc) d (when d (locale/primary d))])))

(defn lookup
  {:params [:keyword :keyword] :ret (or :string {:keyword :string} :nil)}
  "The message for a key along locale -> primary -> default, or nil."
  [key loc]
  (when index
    (var found nil)
    (each l (chain loc)
      (when (nil? found)
        (set found (get-in index [l key]))))
    found))

(defn- category-of
  {:params [:keyword] :ret (fn [:number] :keyword)}
  "The plural rule for a locale's primary language, or
  `plural/one-other` when none is registered."
  [loc]
  (def rule (or (get plural-rules (locale/primary loc)) plural/one-other))
  rule)

(def- warned @{})

(defn- missing!
  {:params [:keyword :keyword] :ret :string}
  "Warn once per (key, locale) pair that a translation is missing,
  and answer the key's own name as the visible fallback."
  [key loc]
  (def wk [key loc])
  (unless (warned wk)
    (put warned wk true)
    (log/warn "missing translation" :ns log-ns :key key :locale loc))
  (string key))

(defn t
  {:params [:keyword (or {:count :number? & r} :nil)] :ret :string}
  ``Translate a key in the current locale: (t :shop.cart/empty),
  (t :shop.cart/items {:count n}). A key found nowhere along the
  fallback chain renders as its own name and warns once — visible,
  never a crash; `void i18n check` is the gate.``
  [key &opt params]
  (def loc (current-locale))
  (def msg (lookup key loc))
  (if (nil? msg)
    (missing! key loc)
    (message/render msg params (category-of loc))))

(defn t?
  {:params [:keyword (or {:count :number? & r} :nil)] :ret :string?}
  "Like `t`, but nil for a missing key — a label whose fallback lives
  in the markup."
  [key &opt params]
  (def loc (current-locale))
  (when-let [msg (lookup key loc)]
    (message/render msg params (category-of loc))))

# -- the schema-error bridge ---------------------------------------------

(def- schema-codes
  [:type :literal :enum :union :missing :unknown :key :min :max
   :min-length :max-length :pattern :format :pred :peg])

(defn- q-str
  {:params [:any] :ret :string}
  "The %q-quoted rendering of any value."
  [v] (string/format "%q" v))

(defn- err-params
  {:params [{:keyword :any}] :ret @{:keyword :string}}
  "Every error field becomes a %q-formatted {param}; :values matches
  core's names-str byte for byte, so the :en dictionary reproduces
  default-messages output exactly."
  # every error field becomes a %q-formatted {param}; :values matches
  # core's names-str byte for byte, so the :en dictionary reproduces
  # default-messages output exactly
  [e]
  (def p @{})
  (eachp [k v] e
    (case k
      :path nil
      :code nil
      :message nil
      :causes nil
      :values (put p :values (string/join (map q-str (sorted v)) " "))
      (put p k (q-str v))))
  p)

(defn- schema-key
  {:params [:keyword] :ret :keyword}
  "The dictionary key a schema error code translates through,
  namespaced under :void.schema."
  [code] (keyword "void.schema/" code))

(defn- schema-table
  {:params [:keyword] :ret {:keyword (fn [:any] :string)}}
  "Prebuild the {code (fn [err] string)} table for one locale, one
  render closure per schema-error code the catalog carries."
  [loc]
  (def tbl @{})
  (each code schema-codes
    (when-let [msg (lookup (schema-key code) loc)]
      (put tbl code
           (fn [e] (message/render msg (err-params e) (category-of loc))))))
  tbl)

(defn schema-messages
  {:params [:keyword] :ret {:keyword (fn [:any] :string)}}
  "The prebuilt :void.schema/messages table for a locale; a code the
  catalog does not carry falls through to the core defaults per code,
  the way error-str always worked."
  [loc]
  (get (or schema-tables {}) loc {}))

# -- the error-envelope bridge -------------------------------------------
#
# An error kind is a namespaced keyword (:void.db/not-found), and so is
# a dictionary key: the key *is* the kind, no prefix to learn. A
# dictionary that carries one translates every error of that kind —
# the envelope's :data fields are the {params}, :message is {message}.

(defn- env-params
  {:params [{:message :any :data (or {:keyword :any} :nil) & r}] :ret @{:message :any & r}}
  "The {message, ...params} for one error envelope: :message falls
  back to empty, and every :data field renders as text (bytes
  stringified, everything else %q-quoted)."
  [env]
  (def p @{:message (or (get env :message) "")})
  (eachp [k v] (get env :data {})
    (put p k (if (bytes? v) (string v) (q-str v))))
  p)

(defn- error-table
  {:params [:keyword] :ret {:keyword (fn [:any] :string)}}
  "Prebuild the {kind (fn [envelope] string)} table for one locale:
  every keyword key its fallback chain carries is a candidate error
  kind."
  # every key the locale's fallback chain carries is a candidate kind:
  # a kind is declared by the package that raises it, which a catalog
  # built at boot need not have loaded — the dictionary's key is the
  # whole of the declaration this side needs
  [loc]
  (def tbl @{})
  (def candidates @{})
  (each l (chain loc)
    (eachk k (get (or index {}) l {})
      (when (keyword? k) (put candidates k true))))
  (eachk kind candidates
    (when-let [msg (lookup kind loc)]
      (put tbl kind
           (fn [env] (message/render msg (env-params env) (category-of loc))))))
  tbl)

(defn error-messages
  {:params [:keyword] :ret {:keyword (fn [:any] :string)}}
  "The prebuilt :void.errors/messages table for a locale; a kind the
  catalog does not carry keeps the envelope's own message, the way
  errors/message always worked."
  [loc]
  (get (or error-tables {}) loc {}))

# -- the locale scope ----------------------------------------------------

(defn scope
  {:params [:keyword (fn [] a)] :ret a}
  ``Run `thunk` in the scope of one locale: the locale itself, the
  translator the framework's own packages read through
  `void/core/text`, and the two prebuilt message tables
  (`void/core/schema`'s since wave 0, `void/core/errors`' since 8.1).

  One function, three callers — the middleware, `with-locale*` and the
  scope a request carries so that its own refusal renders translated —
  because a locale that means four bindings in one place and two in
  another is a locale that translates a page and not the refusal of
  it.``
  [loc thunk]
  (with-dyns [locale-dyn loc
              text/t-dyn t?
              :void.schema/messages (schema-messages loc)
              :void.errors/messages (error-messages loc)]
    (thunk)))

(defn with-locale*
  {:params [:any (fn [] a)] :ret a}
  "Run thunk with the locale bound — CLI, jobs and tests; the request
  path is the middleware's."
  [loc thunk]
  (scope (locale/normalize loc) thunk))

# -- install -------------------------------------------------------------

(defn- merge-contributions
  {:params [@[{:name :keyword :locale :keyword :messages {:keyword :any}
               :precedence :number? & r}]]
   :ret {:keyword @{:keyword :any}}
   :throws [:string]}
  "Merge dictionary contributions into locale -> key -> message,
  ascending by :precedence with ties breaking on resolution order —
  the last write to a key wins."
  [contribs]
  (def idx @{})
  # ascending :precedence, stable: the last write to a key wins, and a
  # tie falls back to the deterministic resolution order
  (each c (sorted-by |(get $ :precedence 100) contribs)
    (def loc (or (locale/normalize (c :locale))
                 (errorf "void/i18n: %q contributes a dictionary for %q, which is not a locale tag"
                         (c :name) (c :locale))))
    (def bucket (or (idx loc) (let [t @{}] (put idx loc t) t)))
    (eachp [k msg] (c :messages)
      (when (and (dictionary? msg) (nil? (msg :other)))
        (errorf "void/i18n: the plural message %q in the %q dictionary of %q has no :other form — every plural table carries the fallback"
                k loc (c :name)))
      (put bucket k msg)))
  idx)

(defn install!
  {:params [{:locales (or @[:keyword] :nil) :default :keyword?
             :cookie (or :string :boolean :nil) & r}
            (or @[{:name :keyword :locale :keyword :messages {:keyword :any}
                   :precedence :number? & r}]
                :nil)
            (or @[{:name :keyword? :language :keyword :categories :function & r}]
                :nil)
            (or {:name :keyword :fn :function & r} :nil)]
   :ret :nil
   :throws [:string]}
  ``Install the [:i18n] slice and the resolved contributions into the
  module state: normalize and gate the config ([:i18n :default] must
  be one of [:i18n :locales]), merge the dictionaries, extend the
  plural rules and prebuild the schema-message tables. The
  :before-start hook calls this; so do test suites, without a boot.``
  [cfg &opt msg-contribs plural-contribs locale-source]
  (def locales (map |(or (locale/normalize $)
                         (errorf "void/i18n: [:i18n :locales] entry %q is not a locale tag" $))
                    (get cfg :locales [:en])))
  (def dflt (or (locale/normalize (get cfg :default :en))
                (errorf "void/i18n: [:i18n :default] %q is not a locale tag" (get cfg :default))))
  (unless (find |(= $ dflt) locales)
    (errorf "void/i18n: [:i18n :default] %q is not in [:i18n :locales] %q — the default is the end of every fallback chain and has to be a locale the application serves"
            dflt locales))
  (set settings (merge (or cfg {}) {:locales locales :default dflt}))
  (set index (merge-contributions (or msg-contribs [])))
  (set plural-rules
       (merge plural/rules
              (tabseq [c :in (or plural-contribs [])]
                (locale/primary (locale/normalize (c :language))) (c :categories))))
  (set source-hook locale-source)
  (table/clear warned)
  (set schema-tables (tabseq [l :in locales] l (schema-table l)))
  (set error-tables (tabseq [l :in locales] l (error-table l)))
  nil)

(defn coverage
  {:params []
   :ret @{:keyword {:count :number :missing @[:keyword] :orphans @[:keyword]}}}
  ``Per configured locale: {:count n :missing [...] :orphans [...]} —
  :missing are default-locale keys the locale lacks (the `void i18n
  check` failure), :orphans are its keys the default locale never
  heard of (a warning: usually a typo or a leftover).``
  []
  (def dflt (settings :default))
  (def base (keys (get index dflt {})))
  (tabseq [l :in (settings :locales)]
    l
    (let [dict (get index l {})]
      {:count (length dict)
       :missing (if (= l dflt) [] (sorted (filter |(nil? (get dict $)) base)))
       :orphans (if (= l dflt) []
                  (sorted (filter |(nil? (get-in index [dflt $])) (keys dict))))})))
