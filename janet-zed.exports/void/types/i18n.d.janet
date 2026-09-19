# Types of void/i18n's values, named where they recur.

# A CLDR plural category: what a plural rule answers for a count.
(def I18nPluralCategory :typedef
  '(enum :zero :one :two :few :many :other))

# A :void.i18n/messages contribution: one dictionary of one locale.
(def I18nMessages :typedef
  '{:name :keyword :locale :keyword :messages {:keyword :any} :precedence :number? & r})

# A :void.i18n/plural contribution: the rule of a language the shipped table does not know.
(def I18nPluralRule :typedef
  '{:name :keyword? :language :keyword :categories (fn [:number] I18nPluralCategory) & r})

# The :void.i18n/locale-source contribution: the application's locale resolver, asked
# before the cookie and Accept-Language.
(def I18nLocaleSource :typedef
  '{:name :keyword :fn (fn [:any] :any) & r})
