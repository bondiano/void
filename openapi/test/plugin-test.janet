(import ../test-support/paths)
(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/schema :as schema)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/rest/init :as rest)
(import void/openapi/init :as openapi)

# -- a schema'd API to project -------------------------------------------

(schema/defschema OaOrder
  {:id :int
   :title :string
   :total [:number {:min 0}]})

(schema/defschema OaCreateOrder
  {:title [:string {:min 1}]
   :total [:number {:min 0}]})

(defn ok [req] (rest/json {}))

(rest/defresource orders "/orders"
  {:id-schema :int
   :meta {:void.openapi/tags [:orders]}}
  {:index {:handler 'ok
           :query {:page [:optional [:int {:min 1}]]}
           :response {200 :any}
           :meta {:void.openapi/summary "List orders"}}
   :show {:handler 'ok :response {200 :OaOrder 404 :any}}
   :create {:handler 'ok :body :OaCreateOrder
            :response {201 :OaOrder}}
   :destroy {:handler 'ok :response {204 :nil}}})

(def app-routes
  (router/routes {}
    orders
    (router/GET "/internal" 'ok {:name :internal :void.openapi/hidden true})
    (router/ANY "/catchall" 'ok {:name :catchall})))

(def app-manifest
  (plugin/manifest 'test/app
    :version "0.1.0"
    :requires {:void/openapi ">=0.0.1"}
    :contributes
    {:void.http/route-source [{:name :test/app
                               :routes app-routes
                               :env (router/env-ref (curenv))}]}))

(def plugins ["void/http/init" "void/rest/init" "void/openapi/init" app-manifest])

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
                    :openapi {:enabled true
                              :info {:title "orders api" :version "1.2.3"}}}}}))

(defer (plugin/shutdown! boot 3)

  # -- the served document ------------------------------------------------
  (def resp (http/with-request {:uri "/openapi.json"}))
  (assert (= 200 (resp :status)))
  (assert (string/has-prefix? "application/json"
                              (get-in resp [:headers "content-type"])))
  (def document (json/decode (resp :body)))

  (assert (= "3.1.0" (document "openapi")))
  (assert (= "orders api" (get-in document ["info" "title"])))
  (assert (= "1.2.3" (get-in document ["info" "version"])))

  # resource paths with {id} templates, one item per path
  (def paths (document "paths"))
  (assert (deep= @["/orders" "/orders/{id}"] (sorted (keys paths))))
  (assert (deep= @["get" "post"] (sorted (keys (paths "/orders")))))
  (assert (deep= @["delete" "get"] (sorted (keys (paths "/orders/{id}")))))

  # hidden routes, :any routes and the openapi routes themselves are out
  (assert (nil? (paths "/internal")))
  (assert (nil? (paths "/catchall")))
  (assert (nil? (paths "/openapi.json")))
  (assert (nil? (paths "/docs")))

  # operation projection: id, tags from the group layer, summary
  (def index-op (get-in paths ["/orders" "get"]))
  (assert (= "orders.index" (index-op "operationId")))
  (assert (deep= @["orders"] (index-op "tags")))
  (assert (= "List orders" (index-op "summary")))

  # query params from :void.schema/query, optionality respected
  (def page-param (first (index-op "parameters")))
  (assert (= "page" (page-param "name")))
  (assert (= "query" (page-param "in")))
  (assert (= false (page-param "required")))
  (assert (= "integer" (get-in page-param ["schema" "type"])))

  # path params typed by :id-schema
  (def show-op (get-in paths ["/orders/{id}" "get"]))
  (def id-param (first (show-op "parameters")))
  (assert (= "id" (id-param "name")))
  (assert (= "path" (id-param "in")))
  (assert (= true (id-param "required")))
  (assert (= "integer" (get-in id-param ["schema" "type"])))

  # responses: $ref content for 200, declared 404
  (assert (= "#/components/schemas/OaOrder"
             (get-in show-op ["responses" "200" "content"
                              "application/json" "schema" "$ref"])))
  (assert (= "Not Found" (get-in show-op ["responses" "404" "description"])))

  # requestBody from :void.schema/body
  (def create-op (get-in paths ["/orders" "post"]))
  (assert (= "#/components/schemas/OaCreateOrder"
             (get-in create-op ["requestBody" "content"
                                "application/json" "schema" "$ref"])))
  (assert (= true (get-in create-op ["requestBody" "required"])))

  # 204 has a description and no content
  (def destroy-op (get-in paths ["/orders/{id}" "delete"]))
  (assert (= "No Content" (get-in destroy-op ["responses" "204" "description"])))
  (assert (nil? (get-in destroy-op ["responses" "204" "content"])))

  # components carry every referenced schema
  (def comps (get-in document ["components" "schemas"]))
  (assert (not (nil? (comps "OaOrder"))))
  (assert (not (nil? (comps "OaCreateOrder"))))
  (assert (deep= @["title" "total"]
                 (sorted (get-in comps ["OaCreateOrder" "required"]))))

  # -- the :openapi schema projection registered with the schema layer ---
  (assert (= "#/components/schemas/OaOrder"
             ((schema/project :openapi [:ref :OaOrder]) "$ref")))

  # -- swagger ui ---------------------------------------------------------
  (def docs (http/with-request {:uri "/docs"}))
  (assert (= 200 (docs :status)))
  (assert (string/find "swagger-ui" (string (docs :body))))
  (assert (string/find "/openapi.json" (string (docs :body))))

  # -- export -------------------------------------------------------------
  (def out (string (os/getenv "TMPDIR" "/tmp") "/void-openapi-test.json"))
  (openapi/export out)
  (def exported (json/decode (slurp out)))
  (assert (= "3.1.0" (exported "openapi")))
  (assert (= "orders api" (get-in exported ["info" "title"])))
  (os/rm out))

# -- disabled outside dev: the routes answer 404 -------------------------

(def boot2
  (plugin/start!
    {:plugins plugins
     :profile :test
     :config {:env @{} :cli {:http {:port 0}}}}))
(defer (plugin/shutdown! boot2 3)
  (assert (= 404 ((http/with-request {:uri "/openapi.json"}) :status)))
  (assert (= 404 ((http/with-request {:uri "/docs"}) :status))))

(print "plugin-test: ok")
