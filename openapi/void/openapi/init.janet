### void/openapi — OpenAPI 3.1 plugin (SPEC.md §5.3).
###
### A pure projection, nothing to keep in sync by hand: `spec` reads
### the built route table and the schema registry and folds them into
### one OpenAPI 3.1 document. The inputs are exactly the contracts
### other plugins already maintain — the :void.schema/* route metadata
### keys that void/rest validates against become parameters,
### requestBody and responses; the :void.openapi/* keys this plugin
### declares add tags, summaries and hiding; the schema registry
### becomes components/schemas via ./jsonschema (registered as the
### :openapi projection, so (schema/project :openapi Order) works
### everywhere). The document is data; json/encode is the last step.
###
### Serving: GET /openapi.json and the Swagger UI at GET /docs are
### contributed as ordinary routes (hidden from the spec itself),
### answering only when [:openapi :enabled] — default: the :dev
### profile. `export` writes the document to a file; the :void.core/cli
### contribution makes that `void openapi export [path]`.

(import void/core/plugin :as plugin)
(import void/core/schema :as schema)
(import void/http/init :as http)
(import void/http/router :as router)
(import void/http/ring :as ring)
(import void/http/wire :as wire)
(import spork/json)
(import ./jsonschema :as jsonschema)

# -- boot context --------------------------------------------------------

(var current-context
  "The running openapi context (set by the :before-start hook):
  :enabled, :info, :config. One per process, like plugin/current-boot."
  nil)

(defn- context []
  (or current-context
      (error "void/openapi is not booted — plugin/start! builds the openapi context at :before-start")))

# -- metadata keys (SPEC part II §2.5: :void.openapi/*, merge replace) ---

(each [key sch doc]
  [[:void.openapi/tags [:vector :keyword]
    "Tags grouping this operation in the document"]
   [:void.openapi/summary :string
    "One-line operation summary"]
   [:void.openapi/description :string
    "Longer operation description (CommonMark)"]
   [:void.openapi/id :string
    "operationId override (default: the route name, / -> .)"]
   [:void.openapi/hidden :boolean
    "Leave this route out of the document"]]
  (plugin/contribute! :void.http/route-meta-key
    {:key key :schema sch :doc doc :merge :replace}))

# -- the :openapi schema projection --------------------------------------

(plugin/contribute! :void.core/schema-projection
  {:name :openapi
   :fn (fn openapi-projection [sch] (jsonschema/json-schema sch))})

# -- route table -> document ---------------------------------------------

(defn- openapi-path
  "/orders/:id/files/*rest -> /orders/{id}/files/{rest}"
  [pattern]
  (string/join
    (seq [seg :in (string/split "/" pattern)]
      (cond
        (string/has-prefix? ":" seg) (string "{" (string/slice seg 1) "}")
        (string/has-prefix? "*" seg) (string "{" (string/slice seg 1) "}")
        seg))
    "/"))

(defn- map-entries
  "The [key node] entries of a schema form that is (or resolves
  through refs/optional to) a map schema; nil otherwise."
  [form]
  (when form
    (def node (schema/normalize form))
    (case (node :type)
      :map (node :children)
      :optional (map-entries (first (node :children)))
      :ref (when-let [target (schema/lookup (get-in node [:props :name]))]
             (map-entries target))
      nil)))

(defn- parameters [rmeta path-params refs]
  (def out @[])
  # path params: always required; typed by :void.schema/params when given
  (def by-param
    (tabseq [[k sub] :in (or (map-entries (rmeta :void.schema/params)) [])]
      k sub))
  (each p path-params
    (array/push out
                @{"name" (string p)
                  "in" "path"
                  "required" true
                  "schema" (if-let [sub (get by-param p)]
                             (jsonschema/convert sub refs)
                             @{"type" "string"})}))
  # query and header params from the map-schema entries
  (each [in-name key] [["query" :void.schema/query]
                       ["header" :void.schema/headers]]
    (each [k sub] (or (map-entries (rmeta key)) [])
      (def optional? (= :optional (sub :type)))
      (array/push out
                  @{"name" (string k)
                    "in" in-name
                    "required" (not optional?)
                    "schema" (jsonschema/convert
                               (if optional? (first (sub :children)) sub)
                               refs)})))
  out)

(defn- request-body [rmeta refs]
  (when-let [form (rmeta :void.schema/body)]
    @{"required" true
      "content" @{"application/json"
                  @{"schema" (jsonschema/convert form refs)}}}))

(defn- no-content-status? [status node]
  (or (= 204 status) (= 304 status) (= :nil (node :type))))

(defn- responses [rmeta refs]
  (def declared (rmeta :void.schema/response))
  (if (or (nil? declared) (empty? declared))
    @{"200" @{"description" "OK"}}
    (do
      (def out @{})
      (each status (sorted (keys declared))
        (def node (schema/normalize (declared status)))
        (def entry @{"description" (get wire/status-messages status "")})
        (unless (no-content-status? status node)
          (put entry "content"
               @{"application/json" @{"schema" (jsonschema/convert node refs)}}))
        (put out (string status) entry))
      out)))

(defn- operation [entry refs]
  (def rmeta (entry :meta))
  (def op
    @{"operationId" (or (rmeta :void.openapi/id)
                        (string/replace-all "/" "." (string (entry :name))))
      "responses" (responses rmeta refs)})
  (when-let [tags (rmeta :void.openapi/tags)]
    (put op "tags" (map string tags)))
  (when-let [s (rmeta :void.openapi/summary)] (put op "summary" s))
  (when-let [d (rmeta :void.openapi/description)] (put op "description" d))
  (def params (parameters rmeta (entry :params) refs))
  (unless (empty? params) (put op "parameters" params))
  (when-let [rb (request-body rmeta refs)] (put op "requestBody" rb))
  op)

(def- spec-methods
  {:get true :post true :put true :patch true :delete true :options true})

(defn spec
  ``The OpenAPI 3.1 document for a route table — a pure fold over the
  entries and the schema registry, as data (json/encode it to ship):

      (openapi/spec (http/routes-table) {:info {:title "orders api"}})

  Included: every route whose method is concrete (:any and :head are
  routing artifacts) and that is not :void.openapi/hidden. components/
  schemas carries every registered schema the routes reference,
  transitively. opts :info merges over {"title" "void application"
  "version" "0.0.1"}.``
  [table &opt opts]
  (default opts {})
  (def refs @{})
  (def paths @{})
  (each entry (table :routes)
    (when (and (in spec-methods (entry :method))
               (not (get-in entry [:meta :void.openapi/hidden])))
      (def path (openapi-path (entry :pattern)))
      (def item (or (get paths path) (let [t @{}] (put paths path t) t)))
      (put item (string (entry :method)) (operation entry refs))))
  (def doc
    @{"openapi" "3.1.0"
      "info" (merge @{"title" "void application" "version" "0.0.1"}
                    (tabseq [[k v] :pairs (get opts :info {})]
                      (string k) v))
      "paths" paths})
  (def comps (jsonschema/components refs))
  (unless (empty? comps)
    (put doc "components" @{"schemas" comps}))
  doc)

(defn spec-json
  "spec, encoded — the /openapi.json body and the export payload."
  [table &opt opts]
  (json/encode (spec table opts)))

# -- serving: /openapi.json and the Swagger UI ---------------------------

(def json-path "The path the document is served under." "/openapi.json")
(def docs-path "The path the Swagger UI is served under." "/docs")

(defn serve-json
  "GET /openapi.json — the live document, or 404 when [:openapi
  :enabled] is off (default outside :dev)."
  [req]
  (def ctx (context))
  (if (ctx :enabled)
    (ring/response 200 (spec-json (http/routes-table) {:info (ctx :info)})
                   @{"content-type" "application/json; charset=utf-8"})
    (ring/not-found)))

(def- swagger-page
  (string
    `<!doctype html><html><head><meta charset="utf-8">`
    `<title>API docs</title>`
    `<link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css">`
    `</head><body><div id="swagger-ui"></div>`
    `<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>`
    `<script>SwaggerUIBundle({url: "` json-path `", dom_id: "#swagger-ui"});</script>`
    `</body></html>`))

(defn serve-docs
  "GET /docs — Swagger UI over /openapi.json (a dev tool: the UI
  assets load from the unpkg CDN), 404 when disabled."
  [req]
  (def ctx (context))
  (if (ctx :enabled)
    (ring/html 200 swagger-page)
    (ring/not-found)))

(def- own-routes
  (router/routes {}
    (router/GET json-path 'serve-json
                {:name :void.openapi/json :void.openapi/hidden true})
    (router/GET docs-path 'serve-docs
                {:name :void.openapi/docs :void.openapi/hidden true})))

# -- export --------------------------------------------------------------

(defn export
  ``Write the current document to a file (the `void openapi export`
  CLI; callable from a REPL against a booted system too):

      (openapi/export "openapi.json")``
  [&opt path opts]
  (default path "openapi.json")
  (spit path (string (spec-json (http/routes-table)
                                (merge {:info ((context) :info)}
                                       (or opts {})))
                     "\n"))
  path)

(plugin/contribute! :void.core/cli
  {:name :openapi/export
   :read-only? false
   :doc "Write the OpenAPI 3.1 document to a file: void openapi export [path]"
   :fn (fn cli-export [& args] (export (first args)))})

# -- context build (:before-start hook) ----------------------------------

(defn build-context
  "Assemble the openapi context from a boot value. Normally called by
  the :before-start hook."
  [boot]
  (def cfg (or (get-in boot [:config :values :openapi]) {}))
  (set current-context
       @{:config cfg
         :enabled (if (nil? (cfg :enabled))
                    (= :dev (boot :profile))
                    (cfg :enabled))
         :info (get cfg :info {})}))

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :openapi/build-context
   :doc "Resolve the openapi config before the route table builds"
   :fn (fn build! [boot] (build-context boot))})

# -- manifest ------------------------------------------------------------

(def Config
  "Schema of the :openapi config slice."
  {:enabled [:optional :boolean]
   :info [:optional {:title [:optional :string]
                     :version [:optional :string]
                     :description [:optional :string]}]})

(plugin/defplugin void/openapi
  :doc "OpenAPI 3.1 as a pure projection of the route table and schema registry: :void.schema/* metadata becomes parameters/requestBody/responses, registered schemas become components via the :openapi projection; /openapi.json + Swagger UI when enabled (default: dev); export for CI."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :openapi
  :config-schema Config
  :config-defaults {}
  :contributes
  {:void.http/route-source [{:name :void/openapi
                             :routes own-routes
                             :env (router/env-ref (curenv))}]})
