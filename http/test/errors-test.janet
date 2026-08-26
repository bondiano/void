(import ../test-support/paths)
(import void/http/errors :as errors)

(def quiet-log (fn [_ _ _] nil))
(defn- req [] @{:method :get :path "/x" :headers @{}})

# -- happy path passes through -------------------------------------------

(def ok-h (errors/wrap-panic (fn [_] {:status 200 :body "fine"}) {:log quiet-log}))
(assert (= "fine" ((ok-h (req)) :body)))

# -- plain panic -> 500 --------------------------------------------------

(def boom (errors/wrap-panic (fn [_] (error "kaput")) {:log quiet-log}))
(def r (boom (req)))
(assert (= 500 (r :status)))
(assert (= "500 Internal Server Error" (r :body)) "prod body is terse")
(assert (not (string/find "kaput" (r :body))) "prod body leaks nothing")

# -- structured abort keeps its status, is not logged --------------------

(def logged @[])
(def teapot (errors/wrap-panic (fn [_] (errors/abort 418 "no coffee"))
                               {:log (fn [e _ _] (array/push logged e))}))
(def r2 (teapot (req)))
(assert (= 418 (r2 :status)))
(assert (empty? logged) "4xx aborts are not logged as panics")

(def failing (errors/wrap-panic (fn [_] (error "down"))
                                {:log (fn [e _ _] (array/push logged e))}))
(failing (req))
(assert (= ["down"] (freeze logged)) "500s reach the log hook")

# -- dev page ------------------------------------------------------------

(def dev (errors/wrap-panic (fn [_] (error "kaput")) {:dev true :log quiet-log}))
(def r3 (dev (req)))
(assert (= 500 (r3 :status)))
(assert (string/find "text/html" (get-in r3 [:headers "content-type"])))
(assert (string/find "kaput" (r3 :body)) "dev page shows the error")
(assert (string/find "errors-test" (r3 :body)) "dev page shows the stacktrace")
(assert (string/find "&lt;" ((dev @{:method :get :path "/<script>" :headers @{}}) :body))
        "request data is escaped")

# -- renderer chain ------------------------------------------------------

(def renderers
  [{:name :broken :fn (fn [_ _ _] (error "renderer bug"))}
   {:name :json :fn (fn [err req ctx]
                      (when (= 418 (ctx :status))
                        {:status 418 :body "teapot json"
                         :headers @{"content-type" "application/json"}}))}])

(def custom (errors/wrap-panic (fn [_] (errors/abort 418))
                               {:renderers renderers :log quiet-log}))
(assert (= "teapot json" ((custom (req)) :body))
        "first non-nil renderer wins; a broken renderer is skipped")

(def fallback (errors/wrap-panic (fn [_] (error "x"))
                                 {:renderers renderers :log quiet-log}))
(assert (= 500 ((fallback (req)) :status))
        "no renderer matched -> default renderer")

(print "errors-test ok")
