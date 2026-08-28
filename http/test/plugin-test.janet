(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/http/middleware :as middleware)
(import void/http/wire :as wire)
(import void/http/errors :as errors)

# -- a small application as a plugin -------------------------------------

(def hits @[])

(defn home [req]
  (ring/html 200 "<h1>home</h1>"))

(defn show-order [req]
  (if (= "0" (get-in req [:params :id]))
    (errors/abort 404 "no such order")
    (ring/text 200 (string "order " (get-in req [:params :id])))))

(defn create-order [req]
  (ring/text 201 (string "created " (get-in req [:form "title"]))))

(defn whoami [req]
  (put (req :session) :seen (inc (get (req :session) :seen 0)))
  (ring/text 200 (string "seen " (get-in req [:session :seen]))))

(def app-routes
  (router/routes {:void.http/timeout 30}
    (router/GET "/" 'home {:name :home})
    (router/GET "/orders/:id" 'show-order
      {:name :orders/show :void.http/timeout 5 :app/audited true})
    (router/POST "/orders" 'create-order {:name :orders/create})
    (router/GET "/whoami" 'whoami {:name :whoami})))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/http ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]
     :void.http/route-meta-key [{:key :app/audited :schema :boolean
                                 :doc "Marks audited endpoints"}]
     :void.http/middleware [{:name :test/audit
                             :phase middleware/phase/business
                             :when |(get $ :app/audited)
                             :wrap (fn [h] (fn [req]
                                             (array/push hits (req :path))
                                             (h req)))}]
     :void.http/error-renderer [{:name :test/teapot
                                 :priority 10
                                 :fn (fn [err req ctx]
                                       (when (= 404 (ctx :status))
                                         (ring/text 404 "custom 404")))}]}))

# -- dry-run validates without starting ----------------------------------

(def report
  (plugin/dry-run {:plugins ["void/http/init" app-manifest]
                   :profile :test
                   :config {:env @{}
                            :cli {:http {:port 0 :session {:enabled true}}}}}))
(assert (report :ok))
(assert (deep= [:http/kernel :http/server] (freeze (report :components)))
        "kernel + server components (ADR-0017)")
(assert (= :void/http (get-in report [:extensions :void.http/middleware :owner])))

# -- full boot -----------------------------------------------------------

(def boot
  (plugin/start!
    {:plugins ["void/http/init" app-manifest]
     :profile :test
     :config {:env @{}
              :cli {:http {:port 0
                           :read-timeout 1
                           :idle-timeout 1
                           :session {:enabled true}}}}}))

(defer (plugin/shutdown! boot 3)

  # the table was built at :before-start
  (def table (http/routes-table))
  (assert (= 4 (length (table :routes))))

  # -- with-request: full stack without a socket -------------------------

  (def r1 (http/with-request {:uri "/"}))
  (assert (= 200 (r1 :status)))
  (assert (= "<h1>home</h1>" (r1 :body)))

  (def r2 (http/with-request {:uri "/orders/42"}))
  (assert (= "order 42" (r2 :body)))
  (assert (deep= @["/orders/42"] hits) ":when-gated middleware ran for the audited route")

  (http/with-request {:uri "/"})
  (assert (= 1 (length hits)) "un-audited route skips the audit middleware")

  # abort + custom error renderer
  (def r404 (http/with-request {:uri "/orders/0"}))
  (assert (= 404 (r404 :status)))
  (assert (= "custom 404" (r404 :body)) "contributed renderer wins by priority")

  # the same renderers, reached by calling instead of by throwing —
  # what middleware that decides on a status rather than failing at one
  # uses (load shedding, ADR-0019)
  (def called (http/render-error {:http/status 404} (http/make-request {:uri "/x"})))
  (assert (= 404 (called :status)))
  (assert (= "custom 404" (called :body))
          "render-error runs the contributed renderers, not a body of its own")
  (def overridden (http/render-error {:http/status 500}
                                     (http/make-request {:uri "/x"}) 404))
  (assert (= "custom 404" (overridden :body)) "and an explicit status wins over the error's")
  (def floored (http/render-error {:http/status 503} (http/make-request {:uri "/x"})))
  (assert (= 503 (floored :status)))
  (assert (string/find "503" (string (floored :body)))
          "with the built-in renderer as the floor when nothing else answers")

  # urlencoded form parsing middleware
  (def r3 (http/with-request {:method :post :uri "/orders"
                              :headers {"content-type" "application/x-www-form-urlencoded"}
                              :body "title=widget"}))
  (assert (= 201 (r3 :status)))
  (assert (= "created widget" (r3 :body)))

  # sessions through with-request
  (def s1 (http/with-request {:uri "/whoami"}))
  (assert (= "seen 1" (s1 :body)))
  (def cookie (first (flatten [(get-in s1 [:headers "set-cookie"])])))
  (assert cookie "session cookie set")
  (def sid (first (peg/match '(* "void-session=" '(32 :h)) cookie)))
  (def s2 (http/with-request {:uri "/whoami"
                              :headers {"cookie" (string "void-session=" sid)}}))
  (assert (= "seen 2" (s2 :body)) "session persists across requests")

  # -- explain-route and url-for over the booted table -------------------

  (def ex (http/explain-route "/orders/7"))
  (assert (= :orders/show (ex :name)))
  (assert (= 5 (get-in ex [:meta :void.http/timeout])))
  (assert (= 2 (length (get-in ex [:layers :void.http/timeout])))
          "provenance shows both layers")

  (assert (= "/orders/9" (http/url-for :orders/show {:id 9})))

  # -- the real socket serves the same app -------------------------------

  (def sys-inst (get-in boot [:system :instances :http/server]))
  (def port (get-in sys-inst [:server :port]))
  (assert (pos? port) "server picked an ephemeral port")

  (def conn (net/connect "127.0.0.1" (string port)))
  (:write conn "GET /orders/42 HTTP/1.1\r\nHost: t\r\nConnection: close\r\n\r\n")
  (def buf @"")
  (while (net/read conn 4096 buf 2))
  (def head (wire/parse-response-head buf))
  (assert (= 200 (head :status)))
  (assert (string/find "order 42" buf))
  (:close conn)

  # component health
  (def health ((plugin/why boot :http/server) :state))
  (assert (= :running health)))

# after shutdown the port is closed
(assert (not (first (protect (net/connect "127.0.0.1"
                                          (string (get-in boot [:system :instances :http/server :server :port]))))))
        "listener closed by shutdown")

# -- :void.http/edge: outside routing, outside the panic guard ----------
#
# Middleware wraps one route's chain, so a 404 and a rendered 500 never
# reach it. An edge wrapper does — which is the whole reason the point
# exists (void/security's headers, ADR-0025 §3).

(defn- boom [req] (error "handler blew up"))

(def edge-routes
  (router/routes {}
    (router/GET "/fine" 'edge-ok {:name :edge/fine})
    (router/GET "/boom" 'boom {:name :edge/boom})))

(defn edge-ok [req] (ring/text 200 "fine"))

(def edge-app
  (plugin/manifest 'test/edge
    :version "0.1.0"
    :requires {:void/http ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/edge :routes edge-routes
                               :env (router/env-ref (curenv))}]
     :void.http/edge [{:name :test/stamp
                       :phase 9000
                       :wrap (fn [handler]
                               (fn [req]
                                 (def resp (handler req))
                                 (ring/header resp "x-stamped" "yes")))}
                      {:name :test/outer
                       :phase 100
                       :wrap (fn [handler]
                               (fn [req]
                                 (def resp (handler req))
                                 (ring/header resp "x-order"
                                              (string (get-in resp [:headers "x-stamped"] "-")))))}]}))

(def edge-boot
  (plugin/start! {:plugins ["void/http/init" edge-app]
                  :profile :test
                  :config {:env @{} :cli {:log {:level :error}
                                          :http {:port 0 :access-log false}}}}))

(defer (plugin/shutdown! edge-boot 3)
  (assert (= "yes" (get-in (http/with-request {:uri "/fine"}) [:headers "x-stamped"]))
          "an edge wrapper sees an ordinary response")
  (def missing (http/with-request {:uri "/no-such-path"}))
  (assert (= 404 (missing :status)))
  (assert (= "yes" (get-in missing [:headers "x-stamped"]))
          "and a 404, which no route produced and no middleware ever sees")
  (def blown (http/with-request {:uri "/boom"}))
  (assert (= 500 (blown :status)))
  (assert (= "yes" (get-in blown [:headers "x-stamped"]))
          "and a 500 the panic guard rendered, because the edge is outside it")
  (assert (= "yes" (get-in blown [:headers "x-order"]))
          "lowest phase is outermost, so the phase-100 wrapper sees what the phase-9000 one did"))

(print "plugin-test ok")
