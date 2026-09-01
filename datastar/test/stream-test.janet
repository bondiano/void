(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/html/hiccup :as hiccup)
(import void/datastar/init :as datastar)

(log/set-level! "void" :error)

# -- a live page: the stream re-renders it on every poke -----------------

(def counter @{:n 0})

(defn page-view []
  (hiccup/html5
    [:head [:title (string "count " (counter :n))]]
    [:body [:main {:id "main"} (string "count: " (counter :n))]]))

(defn live [req]
  (datastar/morph-stream req page-view {:rooms [:counter]}))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/datastar ">=0.0.1"}
    :contributes
    {:void.http/route-source
     [{:name :test/app
       :routes (router/routes {}
                 (router/GET "/live" 'live {:name :live}))
       :env (router/env-ref (curenv))}]}))

(def boot
  (plugin/start!
    {:plugins ["void/http/init" "void/html/init" "void/datastar/init" app-manifest]
     :profile :test
     :config {:env @{} :cli {:log {:level :error} :http {:port 0}}}}))

(defer (plugin/shutdown! boot 3)

  (def resp (http/with-request {:uri "/live"
                                :headers {"datastar-request" "true"}}))
  (assert (= "text/event-stream" (get-in resp [:headers "content-type"])))
  (def frames (resp :body))
  (assert (fiber? frames) "a stream response is a fiber, one SSE frame per yield")

  # the initial morph resynchronizes the page on (re)connect
  (assert (string/find "data: elements <title>count 0</title>" (resume frames)))
  (assert (string/find "count: 0" (resume frames)))

  # a poke re-renders the stream's own view and pushes the new page
  (put counter :n 1)
  (datastar/poke! :counter)
  (assert (string/find "<title>count 1</title>" (resume frames)))
  (assert (string/find "count: 1" (resume frames)))

  # pokes coalesce: two before a render still mean one render
  (put counter :n 2)
  (datastar/poke! :counter)
  (put counter :n 3)
  (datastar/poke! :counter)
  (assert (string/find "<title>count 3</title>" (resume frames)))
  (assert (string/find "count: 3" (resume frames)))

  # a room nobody joined is a no-op, not an error
  (datastar/poke! :ghost))

(print "stream-test: ok")
