### void/i18n — dictionaries as contributions, the locale as a dyn, and
### schema errors that translate themselves.
###
### A dictionary is a contribution to :void.i18n/messages — a flat table
### of namespaced keywords to strings (or plural-form tables) for one
### locale, merged by ascending :precedence (default 100; the shipped
### dictionaries sit at 0), so an application overrides a package's text
### without naming a number — the :phase-of-middleware posture, with the
### deterministic resolution order as the tie-break. No config carries a
### translation — config is data and functions do not live in it; neither
### do catalogs that two parties write.
###
### The request's locale is resolved once per request (application hook ->
### cookie -> Accept-Language -> default) by a middleware at phase 4500 —
### after auth, so the hook sees the identity — and bound as (dyn
### :void.i18n/locale) together with (dyn :void.schema/messages), the seam
### void/core/schema has carried since wave 0. Everything deeper in the
### chain sees both: the validation middleware, the handler, the template
### rendering at phase 9000, the fibers the handler spawns, and mail/send,
### which renders before queueing exactly so that this capture works.
### Forms, admin and problem+json localize with zero changes in their
### packages.
###
### `(i18n/t :shop.cart/items {:count n})` — named {param}
### interpolation (a translation reorders words, so printf positions
### were rejected), CLDR plural categories with the rules shipped as
### data for the major families and :void.i18n/plural for the rest. A
### missing key renders as its own name and warns once; `void i18n
### check` turns that page-visible artifact into a CI failure.

(import void/core/plugin :as plugin)
(import void/http/ring :as ring)
(import ./locale :as locale)
(import ./plural :as plural)
(import ./message :as message)
(import ./catalog :as catalog)
(import ./dict :as dict)

# -- the public surface --------------------------------------------------

(def locale-dyn catalog/locale-dyn)
(def t catalog/t)
(def t? catalog/t?)
(def current-locale catalog/current-locale)
(def with-locale* catalog/with-locale*)

(defmacro with-locale
  "Run body with the locale bound — CLI, jobs and tests; the request
  path is the middleware's."
  [loc & body]
  ~(,catalog/with-locale* ,loc (fn [] ,;body)))

(def negotiate locale/negotiate)
(def parse-accept-language locale/parse-accept-language)

# -- extension points ----------------------------------------------------

(plugin/defextension-point :void.i18n/messages
  :doc "A dictionary for one locale: {:name :locale :messages {namespaced-keyword string-or-plural-table} :precedence?}. Merged by ascending :precedence — default 100, the shipped dictionaries contribute at 0 — so an application overrides a package's key without naming a number; ties fold in the deterministic resolution order, last write wins. A plural table maps CLDR categories (:zero :one :two :few :many :other) and must carry :other"
  :schema {:name :keyword
           :locale :keyword
           :messages :dictionary
           :precedence [:optional :int]
           :doc [:optional :string]}
  :cardinality :many)

(plugin/defextension-point :void.i18n/locale-source
  :doc "The application's locale resolver, asked before cookie and Accept-Language: {:name :fn}, :fn is (fn [req] locale-or-nil) — it runs after auth (phase 4500), so (dyn :void.auth/identity) is bound. The returned value is normalized and must be one of [:i18n :locales]; anything else falls through to the next source"
  :schema {:name :keyword
           :fn :function
           :doc [:optional :string]}
  :cardinality :single)

(plugin/defextension-point :void.i18n/plural
  :doc "A plural rule for a language the shipped table does not know: {:language :categories}, :categories is (fn [n] category) over the CLDR keywords (:zero :one :two :few :many :other). Without one, a language declines as one/other"
  :schema {:name [:optional :keyword]
           :language :keyword
           :categories :function
           :doc [:optional :string]}
  :cardinality :many)

# -- the shipped dictionaries --------------------------------------------

(plugin/contribute! :void.i18n/messages
  {:name :void/i18n
   :locale :en
   :messages dict/en
   :precedence 0
   :doc "The schema error texts, reproducing the core defaults"})

(plugin/contribute! :void.i18n/messages
  {:name :void/i18n
   :locale :ru
   :messages dict/ru
   :precedence 0
   :doc "The schema error texts in Russian"})

# -- config --------------------------------------------------------------

(def Config
  "Schema of the [:i18n] config slice."
  {:locales [:optional [:vector :keyword]]
   :default [:optional :keyword]
   :cookie [:optional [:or :string :boolean]]})

(def defaults
  ``Defaults of the [:i18n] slice: one locale, English, and the "lang"
  cookie as the source a visitor's explicit choice rides on (the
  language-switch route of the application sets it; :cookie false
  turns the source off). There is deliberately no query-parameter
  source — a query string travels into logs and referrers, and a GET
  that changes the representation arms cache traps.``
  {:locales [:en]
   :default :en
   :cookie "lang"})

# -- boot ----------------------------------------------------------------

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 400
   :name :i18n/install-catalog
   :doc "Merge the :void.i18n/messages contributions in resolution order, run the boot gates and prebuild the :void.schema/messages and :void.errors/messages tables"
   :fn (fn install [boot]
         (catalog/install!
           (get-in boot [:config :values :i18n] {})
           (get-in boot [:extensions :void.i18n/messages :resolved])
           (get-in boot [:extensions :void.i18n/plural :resolved])
           (get-in boot [:extensions :void.i18n/locale-source :resolved])))})

# -- the middleware ------------------------------------------------------

(defn- configured
  # the element of [:i18n :locales] equal to loc, or nil — a header, a
  # cookie and even the application's hook are inputs, not verdicts
  [loc]
  (when loc
    (find |(= $ loc) (get (or catalog/settings {}) :locales []))))

(defn- hook-locale [req]
  (when-let [hook catalog/source-hook
             f (get hook :fn)]
    (configured (locale/normalize (f req)))))

(defn- cookie-locale [req]
  (def name (get (or catalog/settings {}) :cookie))
  (when (and name (not= false name))
    (configured (locale/normalize (get (ring/cookies req) name)))))

(defn resolve-locale
  "The locale of one request: application hook -> cookie ->
  Accept-Language -> [:i18n :default]."
  [req]
  (or (hook-locale req)
      (cookie-locale req)
      (locale/negotiate (get-in req [:headers "accept-language"])
                        (get (or catalog/settings {}) :locales []))
      (get (or catalog/settings {}) :default :en)))

(plugin/contribute! :void.http/middleware
  {:name :void.i18n/locale
   :phase 4500
   :doc "Resolve the request's locale (hook -> cookie -> Accept-Language -> default) and bind it, with the matching :void.schema/messages and :void.errors/messages tables, for everything deeper in the chain — validation, the handler, the error renderers, the template render at phase 9000 and every fiber they spawn"
   :wrap
   (fn [handler]
     (fn i18n-locale [req]
       (def loc (resolve-locale req))
       (with-dyns [catalog/locale-dyn loc
                   :void.schema/messages (catalog/schema-messages loc)
                   :void.errors/messages (catalog/error-messages loc)]
         (handler req))))})

# -- the CLI -------------------------------------------------------------

(plugin/contribute! :void.core/cli
  {:name :i18n/check
   :read-only? true
   :doc "Print locales and dictionary sizes; a default-locale key missing from a configured locale is an error (the coverage gate): void i18n check"
   :fn (fn cli-check [& args]
         (unless (empty? args)
           (errorf "void i18n check takes no arguments (got %q)" (string/join args " ")))
         (def s catalog/settings)
         (printf "locales  %s" (string/join (map string (s :locales)) " "))
         (printf "default  %s" (string (s :default)))
         (printf "cookie   %s" (if (s :cookie) (string (s :cookie)) "off"))
         (def cov (catalog/coverage))
         (var failed false)
         (each l (s :locales)
           (def c (cov l))
           (printf "%s  %d keys" (string l) (c :count))
           (each k (c :orphans)
             (printf "  orphan   %s — the default locale never heard of it" (string k)))
           (unless (empty? (c :missing))
             (set failed true)
             (each k (c :missing)
               (printf "  missing  %s" (string k)))))
         (when failed
           (error "a key present in the default locale is missing above — the page would show the key name")))})

# -- the plugin ----------------------------------------------------------

(plugin/defplugin void/i18n
  :doc "Dictionaries as data: a translation table is a contribution merged in resolution order, the request's locale is a dyn bound after auth and inherited by every fiber the handler spawns, and the schema errors of forms, admin and problem+json translate through the (dyn :void.schema/messages) seam the core has carried since wave 0."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :i18n
  :config-schema Config
  :config-defaults defaults)
