### void/rest — REST/JSON API plugin, sugar over void/http.
###
### Three moves, all driven by the :void.schema/* route metadata keys
### this plugin declares (the reserved rows): validation, serialization,
### problems. The validation middleware (phase 6000) coerces and checks
### :params/:query/:headers/:body against the route's schemas before the
### handler runs — the handler only ever sees typed, valid data — and
### answers violations with RFC 7807 problem+json. Handlers return lazy
### `(rest/json data)` responses; the serialization middleware (phase
### 9010, just inside void/html's render middleware, whose JSON twin it
### is) encodes them on the way out and, with [:rest :validate-responses]
### (default: dev), checks the payload against the :void.schema/response
### schema for the status — contract drift fails loudly in dev instead of
### silently in prod. The problem+json error renderer answers API clients
### (schema'd routes, or any client whose Accept mentions json) for every
### abort and panic, so an API never sees an HTML error page. defresource
### (./resource) builds conventional CRUD route groups whose action specs
### land on routes as exactly these metadata keys; ./pagination carries
### the list-endpoint conventions.

(import void/core/plugin :as plugin)
(import void/core/schema :as schema)
(import void/http/ring :as ring)
(import void/core/errors :as errors)
(import void/http/middleware :as middleware)
(import spork/json)
(import ./problem :as problem)
(import ./pagination :as pagination)
(import ./resource :prefix "" :export true)

# -- boot context --------------------------------------------------------

(var current-context
  "The running rest context (set by the :before-start hook):
  :validate-responses, :config. One per process, like
  plugin/current-boot."
  nil)

(defn- context []
  (or current-context
      (error "void/rest is not booted — plugin/start! builds the rest context at :before-start")))

# -- metadata keys (frozen v1 rows) --------------------------------------

(defn- schema-form? [x]
  (def [ok _] (protect (schema/normalize x)))
  ok)

(def- request-schema-keys
  [:void.schema/params :void.schema/query
   :void.schema/headers :void.schema/body])

(each [key doc]
  [[:void.schema/params "Path-param schemas: {:id :int}; coerced and validated before the handler, failures answer 400 problem+json"]
   [:void.schema/query "Query-param map schema; coerced and validated before the handler, failures answer 400 problem+json"]
   [:void.schema/headers "Request-header map schema (keyword header names); validated before the handler, failures answer 400 problem+json"]
   [:void.schema/body "Request-body schema over the decoded JSON body (or coerced form fields); failures answer 422 problem+json"]]
  (plugin/contribute! :void.http/route-meta-key
    {:key key
     :schema [:pred schema-form? "must be a schema form"]
     :doc doc
     :merge :deep-merge}))

(plugin/contribute! :void.http/route-meta-key
  {:key :void.schema/response
   :schema [:map-of [:int {:min 100 :max 599}]
            [:pred schema-form? "must be a schema form"]]
   :doc "Response schemas by status: {200 :Order 404 :Problem}; checked against rest/json payloads when [:rest :validate-responses], projected by void/openapi"
   :merge :deep-merge})

(plugin/contribute! :void.http/route-meta-key
  {:key :void.rest/problems
   :schema :boolean
   :doc "Force (true) or suppress (false) problem+json error rendering for this route; unset falls back to schema'd-route/Accept detection"
   :merge :replace})

# -- the JSON body codec -------------------------------------------------

(plugin/contribute! :void.http/body-codec
  {:name :void.rest/json
   :content-type "application/json"
   :decode (fn decode-json [body]
             (def [ok v] (protect (json/decode (string body) true)))
             (unless ok
               (error {:http/status 400 :message "malformed JSON body"
                       :problem @{"detail" "malformed JSON body"}}))
             v)
   :encode (fn encode-json [v] (json/encode v))})

# -- validation middleware (phase 6000) ----------------------------------

(defn- keywordize [t]
  (tabseq [[k v] :pairs (or t {})]
    (if (bytes? k) (keyword k) k) v))

# route meta is frozen, so the (immutable) schema forms it carries are
# usable cache keys: normalize (and its PEG compiles) runs once per
# distinct schema, not per request
(def- norm-cache @{})

(defn- normalized [form]
  (or (get norm-cache form)
      (let [n (schema/normalize form)]
        (put norm-cache form n)
        n)))

(defn- body-value [req]
  (cond
    (not (nil? (req :parsed-body))) [(req :parsed-body) false]
    (req :form) [(keywordize (req :form)) true]
    [nil false]))

(plugin/contribute! :void.http/middleware
  {:name :void.rest/validate
   :phase middleware/phase/validation
   :doc "Coerce and validate request parts against the route's :void.schema/* keys; violations answer problem+json (400 request line parts, 422 body)"
   :when (fn [rmeta] (some |(not (nil? (get rmeta $)))
                           [;request-schema-keys]))
   :route-aware true
   :wrap (fn [handler rmeta]
           # resolved once per route, at table build: which request-line
           # parts this route schemas, each schema already normalized.
           # Headers are validated against a keywordized copy and never
           # put back — the request keeps its string-keyed header table
           (def parts
             (seq [[key slot status put-back] :in [[:void.schema/params :params 400 true]
                                                     [:void.schema/query :query 400 true]
                                                     [:void.schema/headers :headers 400 false]]
                   :let [form (get rmeta key)]
                   :when form]
               {:slot slot :schema (normalized form) :status status :put-back put-back}))
           (def body-schema
             (when-let [form (get rmeta :void.schema/body)] (normalized form)))
           (fn rest-validate [req]
             (each p parts
               (def slot (p :slot))
               (def res (schema/check (p :schema) (keywordize (req slot)) {:coerce true}))
               # a violation is raised as data: the panic guard hands
               # it to the renderers, and the problem+json one reads
               # the schema errors off the envelope
               (unless (empty? (res :errors))
                 (errors/raise :void.schema/invalid
                               (string/format "invalid request %s" (string slot))
                               {:in slot :errors (res :errors)}
                               (p :status)))
               (when (p :put-back)
                 (put req slot (res :value))))
             (when body-schema
               (def [value coerce] (body-value req))
               (def res (schema/check body-schema value (if coerce {:coerce true} {})))
               (unless (empty? (res :errors))
                 (errors/raise :void.schema/invalid "invalid request body"
                               {:in :body :errors (res :errors)} 422))
               (put req :parsed-body (res :value)))
             (handler req)))})

# -- lazy JSON responses and the serialization middleware ----------------

(defn json
  ``A lazy JSON response — data as data, encoded by the serialization
  middleware on the way out (and checked against the route's
  :void.schema/response schema in dev):

      (rest/json order)
      (rest/json orders {:status 200 :headers {"x-total" "117"}})

  opts: :status (200), :headers (merged over application/json).``
  [data &opt opts]
  (default opts {})
  @{:status (get opts :status 200)
    :headers (merge @{"content-type" "application/json; charset=utf-8"}
                    (get opts :headers {}))
    :void.rest/data data})

(defn created
  "The 201 response for a newly created representation; location adds
  the Location header."
  [data &opt location]
  (def resp (json data {:status 201}))
  (if location (ring/header resp "location" location) resp))

(defn no-content
  "The bare 204."
  []
  (ring/response 204))

(defn rest-response?
  "Is this response a lazy JSON response the serialization middleware
  will encode?"
  [resp]
  (and (dictionary? resp)
       (not (nil? (get resp :void.rest/data)))))

(defn- check-response-schema
  "Check one payload against the route's response schemas by status
  (`rs`, the route's :void.schema/response); a violation is a panic,
  because it is the handler's bug and not the client's."
  [route-name rs resp data]
  (when-let [form (get rs (resp :status))]
    (def res (schema/check (normalized form) data {}))
    (unless (empty? (res :errors))
      (errorf "response for %q violates its %d schema:\n  - %s"
              route-name (resp :status)
              (string/join (map schema/error-str (res :errors))
                           "\n  - ")))))

(plugin/contribute! :void.http/middleware
  {:name :void.rest/serialize
   # the response phase + 10, not the phase itself: void/html renders
   # lazy views on 9000, and a composition with both would otherwise be
   # two plugins on one number, ordered by plugin name and warned about
   # at build. The order is free — a lazy view (:void.html/content) and
   # a lazy rest value (:void.rest/data) are disjoint markers, and
   # neither wrapper touches the other's response — so the number only
   # says the order was chosen rather than spelled. A name (:after
   # :void.html/render) is not available: void/rest does not require
   # void/html, and a relative placement may only point at a middleware
   # that is certainly there (ADR-0045 §3)
   :phase (+ middleware/phase/response 10)
   :doc "Encode lazy (rest/json data) responses; with [:rest :validate-responses] check the payload against the route's :void.schema/response schema first"
   :route-aware true
   :wrap (fn [handler rmeta]
           # whether responses are checked, and against what, is settled
           # at table build: the [:rest] slice was read at :before-start
           # (phase 450, before the table) and the route is frozen
           (def rs (when ((context) :validate-responses)
                     (get rmeta :void.schema/response)))
           (def route-name (get rmeta :name))
           (fn rest-serialize [req]
             (def resp (handler req))
             (when (rest-response? resp)
               (def data (resp :void.rest/data))
               (when rs (check-response-schema route-name rs resp data))
               (put resp :body (json/encode data)))
             resp))})

# -- problem+json error rendering ----------------------------------------

(defn- problem-request? [req]
  (def rmeta (get-in req [:void/route :meta]))
  (def flag (get (or rmeta {}) :void.rest/problems))
  (cond
    (not (nil? flag)) flag
    (and rmeta
         (some |(not (nil? (get rmeta $)))
               [:void.schema/response ;request-schema-keys]))
    true
    (let [a (ring/request-header req "accept")]
      (and a (not (nil? (string/find "json" a)))))))

(plugin/contribute! :void.http/error-renderer
  {:name :void.rest/problem
   :priority 900
   :fn (fn render-problem [err req ctx]
         (when (problem-request? req)
           (problem/from-error err ctx)))})

# -- problem sugar -------------------------------------------------------

(defn problem
  "See problem/response — the RFC 7807 response builder."
  [status &opt ext headers]
  (problem/response status ext headers))

(defn abort
  ``Throw a problem the renderer keeps intact:

      (rest/abort 404)
      (rest/abort 409 "order is already shipped")
      (rest/abort 403 "forbidden" {"balance" 30})``
  [status &opt detail ext]
  (errors/raise :void.rest/problem detail
                {:problem (merge (or ext @{})
                                 (if detail @{"detail" (string detail)} @{}))}
                status))

(errors/define! :void.rest/problem
  {:doc "rest/abort — a problem the handler shaped itself: :data {:problem <extension members>}"})

# -- context build (:before-start hook) ----------------------------------

(defn build-context
  "Assemble the rest context from a boot value. Normally called by the
  :before-start hook."
  [boot]
  (def cfg (or (get-in boot [:config :values :rest]) {}))
  (set current-context
       @{:config cfg
         :validate-responses (if (nil? (cfg :validate-responses))
                               (= :dev (boot :profile))
                               (cfg :validate-responses))}))

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :rest/build-context
   :doc "Resolve the rest config before the route table builds"
   :fn (fn build! [boot] (build-context boot))})

# -- manifest ------------------------------------------------------------

(def Config
  "Schema of the :rest config slice."
  {:validate-responses [:optional :boolean]})

(plugin/defplugin void/rest
  :doc "REST/JSON sugar over void/http: :void.schema/* route metadata drives request coercion+validation and response serialization; RFC 7807 problem+json for every failure; defresource CRUD groups; pagination/sorting/filtering conventions."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :rest
  :config-schema Config
  :config-defaults {})
