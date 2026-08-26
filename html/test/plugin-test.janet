(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/html/init :as html)
(import void/html/hiccup :as hiccup)
(import void/html/temple :as temple)

# -- a small app: hiccup pages, fragments, a temple view -----------------

(defn base-layout [content context]
  (hiccup/html5
    [:head [:title (get context :title "void")]]
    [:body
     [:header [:a {:href "/"} "home"]]
     [:main content]]))

(defn home [req]
  (html/page [:h1 "orders"]
             {:layout base-layout :context {:title "orders"}}))

(defn frag [req]
  (html/fragment [:span "just this"]))

(def tmpl-view (temple/create "<h1>{{ (args :title) }}</h1>" "view"))
(def tmpl-layout
  (temple/create "<!DOCTYPE html><title>{{ (args :title) }}</title>{- (args :content) -}"
                 "layout"))

(defn tmpl [req]
  (html/page tmpl-view
             {:engine :temple
              :layout tmpl-layout
              :context {:title "from temple"}}))

(defn asset-url [req]
  (ring/text 200 (html/asset "css/app.css")))

(def app-routes
  (router/routes {}
    (router/GET "/" 'home {:name :home})
    (router/GET "/frag" 'frag {:name :frag})
    (router/GET "/tmpl" 'tmpl {:name :tmpl})
    (router/GET "/asset" 'asset-url {:name :asset})))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/html ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]}))

# -- dry-run validates the composition -----------------------------------

(def report
  (plugin/dry-run {:plugins ["void/http/init" "void/html/init" app-manifest]
                   :profile :test
                   :config {:env @{} :cli {:http {:port 0}}}}))
(assert (report :ok))
(assert (= :void/html (get-in report [:extensions :void.html/engine :owner])))
(assert (= 2 (get-in report [:extensions :void.html/engine :contributions]))
        "hiccup and temple engines are contributed")

# an unknown engine fails the boot before anything listens
(assert (not (first (protect
                      (plugin/start!
                        {:plugins ["void/http/init" "void/html/init" app-manifest]
                         :profile :test
                         :config {:env @{}
                                  :cli {:http {:port 0}
                                        :html {:engine :mustache}}}}))))
        "config [:html :engine] must name a contributed engine")

# -- full boot: lazy view responses render on the way out ----------------

(def boot
  (plugin/start!
    {:plugins ["void/http/init" "void/html/init" app-manifest]
     :profile :test
     :config {:env @{} :cli {:http {:port 0}}}}))

(defer (plugin/shutdown! boot 3)

  (def r1 (http/with-request {:uri "/"}))
  (assert (= 200 (r1 :status)))
  (assert (= "text/html; charset=utf-8" (get-in r1 [:headers "content-type"])))
  (def body (string (r1 :body)))
  (assert (string/has-prefix? "<!DOCTYPE html>" body) "the layout wrapped the page")
  (assert (string/find "<title>orders</title>" body) "context reached the layout")
  (assert (string/find "<main><h1>orders</h1></main>" body))

  (def r2 (http/with-request {:uri "/frag"}))
  (assert (= "<span>just this</span>" (string (r2 :body))) "fragments skip layout")

  (def r3 (http/with-request {:uri "/tmpl"}))
  (assert (= "<!DOCTYPE html><title>from temple</title><h1>from temple</h1>"
             (string (r3 :body)))
          "per-response :engine override renders through temple")

  (def r4 (http/with-request {:uri "/asset"}))
  (assert (= "/assets/css/app.css" (string (r4 :body)))
          "no manifest -> dev passthrough asset urls"))

(print "plugin-test: ok")
