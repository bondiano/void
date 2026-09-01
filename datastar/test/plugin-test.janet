(import ../test-support/paths)
(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/http/wire :as wire)
(import void/html/init :as html)
(import void/html/hiccup :as hiccup)
(import void/datastar/init :as datastar)

(log/set-level! "void" :error)

# -- an app whose routes answer both full-page and Datastar requests -----

(defn base-layout [content context]
  (hiccup/html5
    [:head [:title "counter"]]
    [:body [:main {:id "main"} content]]))

(def counter @{:n 0})

(defn page [req]
  (html/page [:p {:id "count"} (string "count: " (counter :n))]
             {:layout base-layout}))

(defn inc-count [req]
  (def sig (datastar/signals req))
  (put counter :n (+ (counter :n) (get (or sig {}) :by 1)))
  (page req))

(defn frag [req]
  (html/fragment [:p {:id "count"} "fragment"]))

(defn read-signals [req]
  (ring/response 200 (json/encode (or (datastar/signals req) {}))
                 @{"content-type" "application/json"}))

(defn push [req]
  (datastar/events [(datastar/patch-signals {:count (counter :n)})
                    (datastar/remove-elements "#toast")]))

(def app-routes
  (router/routes {}
    (router/GET "/" 'page {:name :page :void.datastar/morph true})
    (router/POST "/inc" 'inc-count {:name :inc :void.datastar/morph true})
    (router/GET "/frag" 'frag {:name :frag :void.datastar/morph true})
    (router/GET "/signals" 'read-signals {:name :signals})
    (router/POST "/signals" 'read-signals {:name :signals/post})
    (router/GET "/push" 'push {:name :push})))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/datastar ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]}))

(def plugins ["void/http/init" "void/html/init" "void/datastar/init" app-manifest])
(def config {:env @{} :cli {:log {:level :error}
                            :http {:port 0 :strict-meta true}}})

# -- dry-run: the composition validates, the component is visible --------

(def report
  (plugin/dry-run {:plugins plugins :profile :test :config config}))
(assert (report :ok))
(assert (index-of :datastar/registry (report :components))
        "the stream registry is a component of the composition")

# -- the full stack ------------------------------------------------------

(def boot (plugin/start! {:plugins plugins :profile :test :config config}))

(defer (plugin/shutdown! boot 3)

  (assert (= true (get-in (http/explain-route "/") [:meta :void.datastar/morph])))

  # a plain browser request gets the full page
  (def full (http/with-request {:uri "/"}))
  (assert (string/has-prefix? "<!DOCTYPE html>" (string (full :body))))
  (assert (string/find "count: 0" (string (full :body))))

  # a Datastar request on the same route gets the morph events
  (def morph (http/with-request {:uri "/"
                                 :headers {"datastar-request" "true"}}))
  (assert (= "text/event-stream" (get-in morph [:headers "content-type"])))
  (def [title-ev body-ev] (morph :body))
  (assert (= (string "event: datastar-patch-elements\n"
                     "data: selector title\n"
                     "data: elements <title>counter</title>\n\n")
             title-ev))
  (assert (string/has-prefix? (string "event: datastar-patch-elements\n"
                                      "data: selector body\n"
                                      "data: elements <body>")
                              body-ev))
  (assert (string/find "count: 0" body-ev))

  # an action reads the signals it was sent and morphs the new page
  (def acted (http/with-request {:method :post :uri "/inc"
                                 :headers {"datastar-request" "true"}
                                 :json {:by 2}}))
  (assert (= 2 (length (acted :body))))
  (assert (string/find "count: 2" (get (acted :body) 1)))

  # the same handler still serves a plain form post
  (def plain (http/with-request {:method :post :uri "/inc"}))
  (assert (string/has-prefix? "<!DOCTYPE html>" (string (plain :body))))
  (assert (string/find "count: 3" (string (plain :body))))

  # a fragment route morphs by id: one event, no selector
  (def frag-resp (http/with-request {:uri "/frag"
                                     :headers {"datastar-request" "true"}}))
  (assert (= 1 (length (frag-resp :body))))
  (assert (= (string "event: datastar-patch-elements\n"
                     "data: elements <p id=\"count\">fragment</p>\n\n")
             (string (first (frag-resp :body)))))

  # signals: the datastar query parameter on GET, the JSON body otherwise
  (def via-query
    (http/with-request {:uri (string "/signals?datastar="
                                     (wire/url-encode `{"open":true}`))}))
  (assert (deep= @{:open true} (json/decode (string (via-query :body)) true)))
  (def via-body
    (http/with-request {:method :post :uri "/signals" :json {:q "abc"}}))
  (assert (deep= @{:q "abc"} (json/decode (string (via-body :body)) true)))
  # no signals is nil, malformed signals is a 400 — not a crash
  (def none (http/with-request {:uri "/signals"}))
  (assert (deep= @{} (json/decode (string (none :body)) true)))
  (def bad (http/with-request {:method :post :uri "/signals" :body "{oops"
                               :headers {"content-type" "application/json"}}))
  (assert (= 400 (bad :status)))

  # hand-built event responses stream through ring/sse untouched
  (def pushed (http/with-request {:uri "/push"}))
  (def frames (seq [f :in (pushed :body)] (string f)))
  (assert (= (string "event: datastar-patch-signals\n"
                     "data: signals {\"count\":3}\n\n")
             (get frames 0)))
  (assert (= (string "event: datastar-patch-elements\n"
                     "data: selector #toast\n"
                     "data: mode remove\n\n")
             (get frames 1))))

(print "plugin-test: ok")
