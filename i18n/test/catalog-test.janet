(import ../test-support/paths)
(import void/core/schema :as schema)
(import void/core/errors :as errors)
(import void/core/log :as log)
(import void/i18n :as i18n)
(import void/i18n/catalog :as catalog)
(import void/i18n/dict :as dict)

(log/set-level! "void.i18n" :fatal)

(def shipped
  [{:name :void/i18n :locale :en :messages dict/en}
   {:name :void/i18n :locale :ru :messages dict/ru}])

# -- lookup, fallback, override ------------------------------------------

(catalog/install!
  {:locales [:en :ru] :default :en :cookie "lang"}
  [;shipped
   {:name :test/app :locale :en :messages {:a/hello "hello" :a/only-en "just english"}}
   {:name :test/app :locale :ru :messages {:a/hello "привет"}}
   {:name :test/late :locale :ru :messages {:a/hello "здравствуйте"}}])

(assert (= "hello" (i18n/t :a/hello)) "no dyn bound — the default locale speaks")
(i18n/with-locale :ru
  (assert (= "здравствуйте" (i18n/t :a/hello))
          "equal precedence — the later contribution's key wins")
  (assert (= "just english" (i18n/t :a/only-en))
          "a key the locale lacks falls back to the default locale")
  (assert (= "a/missing" (i18n/t :a/missing)) "a key found nowhere renders as its own name")
  (assert (nil? (i18n/t? :a/missing)) "t? says nil instead")
  (assert (= "здравствуйте" (i18n/t? :a/hello))))
(assert (= :ru-ru (i18n/with-locale "ru-RU" (i18n/current-locale)))
        "with-locale normalizes what it is given")

# a shipped-style :precedence 0 dictionary loses to a default one even
# when it comes later in resolution order
(catalog/install!
  {:locales [:ru] :default :ru}
  [{:name :aaa/app :locale :ru :messages {:a/hello "приложение"}}
   {:name :zzz/base :locale :ru :messages {:a/hello "пакет"} :precedence 0}])
(i18n/with-locale :ru
  (assert (= "приложение" (i18n/t :a/hello))
          "precedence is policy, resolution order only breaks ties"))

# -- regional locale falls to its primary --------------------------------

(catalog/install!
  {:locales [:en :ru-ru] :default :en}
  [;shipped {:name :test/app :locale :ru :messages {:a/hello "привет"}}])
(i18n/with-locale :ru-ru
  (assert (= "привет" (i18n/t :a/hello)) ":ru-ru reads the :ru dictionary through the chain"))

# -- plurals through t, and a contributed rule ---------------------------

(catalog/install!
  {:locales [:en :ru] :default :en}
  [;shipped
   {:name :test/app :locale :ru
    :messages {:a/items {:one "{count} товар" :few "{count} товара"
                         :many "{count} товаров" :other "{count} товара"}}}
   {:name :test/app :locale :en
    :messages {:a/items {:one "{count} item" :other "{count} items"}}}])
(i18n/with-locale :ru
  (assert (= "21 товар" (i18n/t :a/items {:count 21})))
  (assert (= "5 товаров" (i18n/t :a/items {:count 5}))))
(i18n/with-locale :en
  (assert (= "1 item" (i18n/t :a/items {:count 1})))
  (assert (= "2 items" (i18n/t :a/items {:count 2}))))

(catalog/install!
  {:locales [:en :xx] :default :en}
  [{:name :test/app :locale :xx
    :messages {:a/items {:two "{count}!!" :other "{count}?"}}}]
  [{:name :test/app :language :xx :categories (fn [n] (if (= 2 n) :two :other))}])
(i18n/with-locale :xx
  (assert (= "2!!" (i18n/t :a/items {:count 2})) "a contributed plural rule is consulted")
  (assert (= "3?" (i18n/t :a/items {:count 3}))))

# -- boot gates ----------------------------------------------------------

(assert (not (first (protect (catalog/install! {:locales [:en] :default :de} []))))
        "[:i18n :default] outside [:i18n :locales] is a boot error")
(assert (not (first (protect (catalog/install! {:locales ["no way"] :default :en} []))))
        "a locales entry that is not a tag is a boot error")
(assert (not (first (protect (catalog/install!
                               {:locales [:en] :default :en}
                               [{:name :test/app :locale :en
                                 :messages {:a/items {:one "1"}}}]))))
        "a plural table without :other is a boot error naming the contributor")

# -- coverage ------------------------------------------------------------

(catalog/install!
  {:locales [:en :ru] :default :en}
  [{:name :test/app :locale :en :messages {:a/x "x" :a/y "y"}}
   {:name :test/app :locale :ru :messages {:a/x "х" :a/stray "лишний"}}])
(def cov (catalog/coverage))
(assert (deep= @[:a/y] (get-in cov [:ru :missing])) "a default-locale key the locale lacks")
(assert (deep= @[:a/stray] (get-in cov [:ru :orphans])) "a key the default locale never heard of")
(assert (empty? (get-in cov [:en :missing])))

# -- the schema-error bridge ---------------------------------------------

# every dictionary code, rendered by the core defaults first and
# through the :en catalog table second — byte for byte
(def cases
  [[(schema/check {:name :string} {}) "missing"]
   [(schema/check {:name :string} {:name 42}) "type"]
   [(schema/check [:enum :a :b] :c) "enum"]
   [(schema/check [:int {:min 18}] 15) "min"]
   [(schema/check [:int {:max 5}] 7) "max"]
   [(schema/check [:string {:min 3}] "ab") "min-length"]
   [(schema/check [:string {:max 3}] "abcd") "max-length"]])

(catalog/install! {:locales [:en :ru] :default :en} shipped)
(each [r name] cases
  (def errs (r :errors))
  (assert (not (empty? errs)) (string name " produced an error"))
  (each e errs
    (def plain (schema/error-str e))
    (def through
      (with-dyns [:void.schema/messages (catalog/schema-messages :en)]
        (schema/error-str e)))
    (assert (= plain through)
            (string "the :en catalog reproduces the core text for " name
                    ": " plain " vs " through))))

# and the same errors speak Russian under the :ru table
(defn- ru-str [e]
  (with-dyns [:void.schema/messages (catalog/schema-messages :ru)]
    (schema/error-str e)))
(assert (string/find "обязательное поле отсутствует"
                     (ru-str (first ((schema/check {:name :string} {}) :errors)))))
(assert (= "ожидается не меньше 18, получено 15"
           (ru-str (first ((schema/check [:int {:min 18}] 15) :errors)))))

# -- error envelopes translate by kind: the dictionary key is the kind ----
(catalog/install! {:locales [:en :ru] :default :en}
                  [{:name :test/errors :locale :ru :precedence 100
                    :messages {:void.db/not-found "{entity} с id {id} не найден"
                               :void.http/not-found "по адресу {path} ничего нет"}}
                   {:name :test/errors-en :locale :en :precedence 100
                    :messages {:void.db/not-found "no {entity} with id {id}"
                               :void.http/not-found "nothing at {path}"}}])
(def nf (errors/make :void.db/not-found "User 7 not found" {:entity :User :id 7}))
(assert (= "User 7 not found" (errors/message nf)) "without a binding the envelope speaks for itself")
(with-dyns [:void.errors/messages (catalog/error-messages :ru)]
  (assert (= "User с id 7 не найден" (errors/message nf)) "the :ru dictionary translates the kind, :data as params")
  (assert (= "kaboom" (errors/message "kaboom")) "a kind the dictionary lacks keeps its own message"))
(with-dyns [:void.errors/messages (catalog/error-messages :en)]
  (assert (= "nothing at /x" (errors/message (errors/make :void.http/not-found nil {:path "/x"})))
          "a string :data field is not quoted"))

# a code the catalog does not carry falls through to the core default
(catalog/install! {:locales [:xx] :default :xx} [])
(def e (first ((schema/check {:name :string} {}) :errors)))
(assert (= (schema/error-str e)
           (with-dyns [:void.schema/messages (catalog/schema-messages :xx)]
             (schema/error-str e)))
        "an empty table changes nothing — error-str falls back per code")

(print "catalog-test: ok")
