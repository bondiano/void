(import ../test-support/paths)
(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/schema :as schema)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/rest/init :as rest)
(import void/rest/pagination :as pagination)

# -- a small JSON API ----------------------------------------------------

(schema/defschema Order
  {:id :int
   :title :string
   :total [:number {:min 0}]})

(schema/defschema CreateOrder
  {:title [:string {:min 1}]
   :total [:number {:min 0}]})

(def db @{1 @{:id 1 :title "widget" :total 9.5}})
(var next-id 2)

(defn index [req]
  (def paging (pagination/params req {:allowed-sort [:id :total]}))
  (def items (sorted-by |($ :id) (values db)))
  (def page-items (take (paging :limit) (drop (paging :offset) items)))
  (rest/json (pagination/envelope page-items
                                  (merge paging {:total (length items)}))))

(defn show [req]
  (def order (get db (get-in req [:params :id])))
  (unless order (rest/abort 404 "no such order"))
  (rest/json order))

(defn create [req]
  (def body (req :parsed-body))
  (def order (merge body {:id next-id}))
  (put db next-id (merge-into @{} order))
  (++ next-id)
  (rest/created order (string "/orders/" (order :id))))

(defn broken [req]
  # violates its own :void.schema/response contract
  (rest/json {:id "not-an-int" :title 1 :total -1}))

(defn haywire [req]
  (error "wires crossed"))

(rest/defresource orders "/orders"
  {:id-schema :int}
  {:index {:handler 'index
           :query (pagination/query-schema)
           :response {200 :any}}
   :show {:handler 'show :response {200 :Order}}
   :create {:handler 'create :body :CreateOrder :response {201 :Order}}})

(def app-routes
  (router/routes {}
    orders
    (router/GET "/broken" 'broken
                {:name :broken :void.schema/response {200 :Order}})
    (router/GET "/haywire" 'haywire {:name :haywire})))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/rest ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]}))

(def plugins ["void/http/init" "void/rest/init" app-manifest])

# -- dry-run and boot (strict metadata: every key must be declared) ------

(def report
  (plugin/dry-run {:plugins plugins
                   :profile :test
                   :config {:env @{} :cli {:http {:port 0}}}}))
(assert (report :ok))

(def boot
  (plugin/start!
    {:plugins plugins
     :profile :test
     :config {:env @{}
              :cli {:http {:port 0 :strict-meta true}
                    :rest {:validate-responses true}}}}))

(defer (plugin/shutdown! boot 3)

  (defn body-of [resp] (json/decode (resp :body) true))

  # -- happy path: params coerced, response serialized -------------------
  (def shown (http/with-request {:uri "/orders/1"}))
  (assert (= 200 (shown :status)))
  (assert (string/has-prefix? "application/json"
                              (get-in shown [:headers "content-type"])))
  (assert (= "widget" ((body-of shown) :title)))

  # the handler saw a coerced int param (db is keyed by number 1)
  (assert (= 1 ((body-of shown) :id)))

  # -- param validation: garbage :id answers 400 problem+json ------------
  (def bad-param (http/with-request {:uri "/orders/nope"}))
  (assert (= 400 (bad-param :status)))
  (assert (= "application/problem+json"
             (get-in bad-param [:headers "content-type"])))
  (def bp (body-of bad-param))
  (assert (= "invalid request params" (bp :detail)))
  (assert (= "/id" (get-in bp [:errors 0 :pointer])))

  # -- query validation from the pagination convention schema ------------
  (def bad-query (http/with-request {:uri "/orders?per-page=9000"}))
  (assert (= 400 (bad-query :status)))
  (assert (= "/per-page" (get-in (body-of bad-query) [:errors 0 :pointer])))

  # -- json body: decoded, validated, coerced into the handler -----------
  (def created
    (http/with-request {:method :post :uri "/orders"
                        :headers {"content-type" "application/json"}
                        :body (json/encode {:title "gadget" :total 3})}))
  (assert (= 201 (created :status)))
  (assert (= "/orders/2" (get-in created [:headers "location"])))
  (assert (= "gadget" ((body-of created) :title)))

  (def invalid
    (http/with-request {:method :post :uri "/orders"
                        :headers {"content-type" "application/json"}
                        :body (json/encode {:title "" :total -2})}))
  (assert (= 422 (invalid :status)))
  (def iv (body-of invalid))
  (assert (= 2 (length (iv :errors))))
  (assert (deep= @["/title" "/total"]
                 (sorted (map |($ :pointer) (iv :errors)))))

  (def malformed
    (http/with-request {:method :post :uri "/orders"
                        :headers {"content-type" "application/json"}
                        :body "{oops"}))
  (assert (= 400 (malformed :status)))
  (assert (= "malformed JSON body" ((body-of malformed) :detail)))

  # a missing body on a :void.schema/body route is a 422, not a crash
  (def missing (http/with-request {:method :post :uri "/orders"}))
  (assert (= 422 (missing :status)))

  # -- pagination conventions through a live request ---------------------
  (def listed (http/with-request {:uri "/orders?page=1&per-page=1&sort=-id"}))
  (assert (= 200 (listed :status)))
  (def lst (body-of listed))
  (assert (= 2 (get-in lst [:page :total])))
  (assert (= 2 (get-in lst [:page :pages])))
  (assert (= 1 (length (lst :data))))

  # -- rest/abort inside a handler ---------------------------------------
  (def gone (http/with-request {:uri "/orders/777"}))
  (assert (= 404 (gone :status)))
  (assert (= "application/problem+json" (get-in gone [:headers "content-type"])))
  (assert (= "no such order" ((body-of gone) :detail)))

  # -- response validation catches contract drift ------------------------
  (def drift (http/with-request {:uri "/broken"
                                 :headers {"accept" "application/json"}}))
  (assert (= 500 (drift :status)))
  (assert (= "application/problem+json" (get-in drift [:headers "content-type"])))

  # -- problem rendering keys off the route and the Accept header --------
  # no schemas + html accept -> the plain http renderer answers
  (def html-err (http/with-request {:uri "/haywire"
                                    :headers {"accept" "text/html"}}))
  (assert (= 500 (html-err :status)))
  (assert (not= "application/problem+json"
                (get-in html-err [:headers "content-type"])))
  # same route, json accept -> problem+json
  (def json-err (http/with-request {:uri "/haywire"
                                    :headers {"accept" "application/json"}}))
  (assert (= "application/problem+json"
             (get-in json-err [:headers "content-type"])))
  # prod-mode 500s hide the panic message
  (assert (nil? ((body-of json-err) :detail)))

  # a 404 with no matched route still renders as a problem for json
  (def no-route (http/with-request {:uri "/nowhere"
                                    :headers {"accept" "application/json"}}))
  (assert (= 404 (no-route :status))))

(print "plugin-test: ok")
