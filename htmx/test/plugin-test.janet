(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/html/init :as html)
(import void/html/hiccup :as hiccup)
(import void/htmx/hx :as hx)
(import void/htmx/init :as htmx)

# -- an app whose routes answer both full-page and htmx requests ---------

(defn base-layout [content context]
  (hiccup/html5
    [:head [:title "orders"]]
    [:body [:main {:id "main"} content]]))

(defn orders [req]
  (html/page [:ul {:id "orders"} [:li "widget"]]
             {:layout base-layout}))

(defn create [req]
  (htmx/trigger
    (html/page [:li "gadget"] {:layout base-layout})
    :order-created))

(defn plain [req]
  (html/page [:h1 "about"] {:layout base-layout}))

(def app-routes
  (router/routes {}
    (router/GET "/orders" 'orders {:name :orders :void.htmx/partial true})
    (router/POST "/orders" 'create {:name :orders/create :void.htmx/partial true})
    (router/GET "/about" 'plain {:name :about})))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/htmx ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]}))

(def plugins ["void/http/init" "void/html/init" "void/htmx/init" app-manifest])

# -- dry-run -------------------------------------------------------------

(def report
  (plugin/dry-run {:plugins plugins
                   :profile :test
                   :config {:env @{} :cli {:http {:port 0}}}}))
(assert (report :ok))

# the meta key is declared, so strict mode accepts it and explain sees it
(def boot
  (plugin/start!
    {:plugins plugins
     :profile :test
     :config {:env @{} :cli {:http {:port 0 :strict-meta true}}}}))

(defer (plugin/shutdown! boot 3)

  (assert (= true (get-in (http/explain-route "/orders") [:meta :void.htmx/partial])))

  # a plain browser request gets the full page
  (def full (http/with-request {:uri "/orders"}))
  (assert (string/has-prefix? "<!DOCTYPE html>" (string (full :body))))

  # an htmx request gets the bare fragment
  (def frag (http/with-request {:uri "/orders"
                                :headers {"hx-request" "true"}}))
  (assert (= `<ul id="orders"><li>widget</li></ul>` (string (frag :body)))
          "HX-Request strips the layout on a :void.htmx/partial route")

  # a history restore needs the full page again
  (def hist (http/with-request {:uri "/orders"
                                :headers {"hx-request" "true"
                                          "hx-history-restore-request" "true"}}))
  (assert (string/has-prefix? "<!DOCTYPE html>" (string (hist :body))))

  # routes without the meta key keep their layout for htmx too
  (def about (http/with-request {:uri "/about"
                                 :headers {"hx-request" "true"}}))
  (assert (string/has-prefix? "<!DOCTYPE html>" (string (about :body))))

  # response helpers compose with view responses
  (def created (http/with-request {:method :post :uri "/orders"
                                   :headers {"hx-request" "true"}}))
  (assert (= "<li>gadget</li>" (string (created :body))))
  (assert (= "order-created" (get-in created [:headers "hx-trigger"]))))

(print "plugin-test: ok")
