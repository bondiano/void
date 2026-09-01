(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/html/init :as html)
(import void/html/form :as form)
(import void/i18n :as i18n)

(log/set-level! "void" :error)

# -- a small app: a translated page, a counter, a validated form ---------

(defn hello [req]
  (html/fragment [:p (i18n/t :hello/greeting {:name "void"})]))

(defn items [req]
  (def n (or (scan-number (get-in req [:query "n"] "")) 0))
  (html/fragment [:span (i18n/t :hello/items {:count n})]))

(def SignUp {:email :string :age [:int {:min 18}]})

(defn signup [req]
  (def result (form/check SignUp (req :form)))
  (if (empty? (result :errors))
    (ring/text 200 "ok")
    (html/fragment (form/form SignUp {:action "/signup"
                                      :values (req :form)
                                      :errors (result :errors)}))))

(def app-routes
  (router/routes {}
    (router/GET "/hello" 'hello {:name :hello})
    (router/GET "/items" 'items {:name :items})
    (router/POST "/signup" 'signup {:name :signup})))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/i18n ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]
     # the application's dictionaries sit at the default precedence
     # (100), the shipped ones at 0 — :void.schema/missing below
     # overrides ours without naming a number
     :void.i18n/messages
     [{:name :test/app :locale :en
       :messages {:hello/greeting "Hello, {name}!"
                  :hello/items {:one "{count} item" :other "{count} items"}
                  :void.schema/missing "required key is missing"}}
      {:name :test/app :locale :ru
       :messages {:hello/greeting "Привет, {name}!"
                  :hello/items {:one "{count} товар" :few "{count} товара"
                                :many "{count} товаров" :other "{count} товара"}
                  :void.schema/missing "заполните поле"}}]
     :void.i18n/locale-source
     [{:name :test/app
       :doc "The profile locale a signed-in user would have — here, a header"
       :fn (fn [req] (get-in req [:headers "x-user-lang"]))}]}))

(def plugins ["void/http/init" "void/html/init" "void/i18n/init" app-manifest])
(defn config [i18n-slice]
  {:env @{} :cli {:http {:port 0} :i18n i18n-slice}})

# -- phases 1-5 ----------------------------------------------------------

(def report (plugin/dry-run {:plugins plugins :profile :test
                             :config (config {:locales [:en :ru]})}))
(assert (report :ok))
(assert (= :void/i18n (get-in report [:extensions :void.i18n/messages :owner])))
(assert (= 4 (get-in report [:extensions :void.i18n/messages :contributions]))
        "the package ships :en and :ru, the app adds two more")
(assert (= 1 (get-in report [:extensions :void.i18n/locale-source :contributions])))

# the boot gates fire before anything listens
(assert (not (first (protect (plugin/start!
                               {:plugins plugins :profile :test
                                :config (config {:locales [:en] :default :ru})}))))
        "[:i18n :default] outside [:i18n :locales] is a boot error")

# -- full boot: the locale rides the dyn through the whole chain ---------

(def boot (plugin/start! {:plugins plugins :profile :test
                          :config (config {:locales [:en :ru]})}))

(defer (plugin/shutdown! boot 3)

  (defn body [spec] (string ((http/with-request spec) :body)))

  (assert (= "<p>Hello, void!</p>" (body {:uri "/hello"}))
          "no signal at all — the default locale")
  (assert (= "<p>Привет, void!</p>"
             (body {:uri "/hello" :headers {"accept-language" "ru,en;q=0.8"}}))
          "Accept-Language negotiates")
  (assert (= "<p>Привет, void!</p>"
             (body {:uri "/hello" :headers {"accept-language" "ru-RU"}}))
          "a regional tag finds its primary")
  (assert (= "<p>Hello, void!</p>"
             (body {:uri "/hello" :headers {"accept-language" "de, ja;q=0.9"}}))
          "nothing available matches — the default")
  (assert (= "<p>Привет, void!</p>"
             (body {:uri "/hello" :headers {"accept-language" "en"
                                            "cookie" "lang=ru"}}))
          "the visitor's explicit choice on the cookie beats the header")
  (assert (= "<p>Привет, void!</p>"
             (body {:uri "/hello" :headers {"accept-language" "en"
                                            "cookie" "lang=en"
                                            "x-user-lang" "ru"}}))
          "the application's hook beats both")
  (assert (= "<p>Привет, void!</p>"
             (body {:uri "/hello" :headers {"accept-language" "ru"
                                            "x-user-lang" "klingon!"}}))
          "garbage from the hook falls through to the next source")
  (assert (= "<p>Hello, void!</p>"
             (body {:uri "/hello" :headers {"cookie" "lang=de"}}))
          "a cookie naming an unconfigured locale falls through too")

  # plural forms through a real request
  (assert (= "<span>5 товаров</span>"
             (body {:uri "/items?n=5" :headers {"accept-language" "ru"}})))
  (assert (= "<span>21 товар</span>"
             (body {:uri "/items?n=21" :headers {"accept-language" "ru"}})))
  (assert (= "<span>1 item</span>" (body {:uri "/items?n=1"})))
  (assert (= "<span>2 items</span>" (body {:uri "/items?n=2"})))

  # schema errors out of a form, localized with zero changes in
  # void/html — and the app's override of :void.schema/missing wins
  (def ru-form (body {:method :post :uri "/signup"
                      :headers {"accept-language" "ru"}
                      :form {"age" "15"}}))
  (assert (string/find "заполните поле" ru-form)
          "the application overrode the shipped missing-key text")
  (assert (string/find "ожидается не меньше 18, получено 15" ru-form)
          "the shipped Russian dictionary translated the :min error")
  (def en-form (body {:method :post :uri "/signup" :form {"age" "15"}}))
  (assert (string/find "required key is missing" en-form))
  (assert (string/find "expected at least 18, got 15" en-form))

  # the CLI gate is contributed and passes on this composition
  (def cli (from-pairs (map |[($ :name) $] (plugin/extension boot :void.core/cli))))
  (assert (cli :i18n/check))
  (assert (get-in cli [:i18n/check :read-only?]))
  (assert (first (protect ((get-in cli [:i18n/check :fn]))))
          "both locales cover the default's keys — check passes"))

(print "plugin-test: ok")
