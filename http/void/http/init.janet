### void/http — the HTTP kernel plugin (SPEC.md §5.1, ADR-0006,
### ROADMAP 1.1).
###
### The first and heaviest consumer of the plugin API: void/http owns
### the extension points other plugins hang HTTP behavior on —
### :void.http/middleware (phased wrappers), :void.http/route-meta-key
### (metadata contract declarations), :void.http/route-source (app
### modules contribute their routes here), :void.http/session-store,
### :void.http/body-codec and :void.http/error-renderer. At
### :before-start the whole route table is built and validated — meta
### typos, unresolved handler symbols, restrict loosenings all fail the
### boot before a port opens — and the :http/server component then just
### serves it. With :workers > 1 the component becomes a prefork master
### (ADR-0010) re-execing this same application per worker; each worker
### binds the shared port via SO_REUSEPORT.
###
### REPL/tools surface: (http/with-request {...}) runs a request
### through the full stack without a socket, (http/explain-route "/x")
### shows every metadata value's origin, (http/url-for :name {...})
### reverses routes, (http/rebuild!) rebuilds and atomically swaps the
### table after code changes.

(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/meta :as meta)
(import ./wire :as wire)
(import ./ring :as ring)
(import ./router :as router)
(import ./middleware :as middleware)
(import ./negotiate :as negotiate)
(import ./multipart :as multipart)
(import ./static :as static)
(import ./session :as session)
(import ./errors :as errors)
(import ./server :as server)
(import ./prefork :as prefork)

# -- boot context --------------------------------------------------------

(var current-context
  "The running http context (set by the :before-start table build):
  :cell (route table holder), :handler, :limits-fn, :renderers,
  :codecs, :session, :workers, :config, :dev. One per process, like
  plugin/current-boot."
  nil)

(defn- context []
  (or current-context
      (error "void/http is not booted — plugin/start! builds the route table at :before-start")))

# -- extension points ----------------------------------------------------

(defn- unique-by [what f]
  (fn [contribs]
    (def seen @{})
    (each c contribs
      (def k (f c))
      (when (in seen k)
        (errorf "duplicate %s %q" what k))
      (put seen k true))))

(plugin/defextension-point :void.http/middleware
  :doc "Phased HTTP middleware: {:name :phase 0-10000 :wrap (fn [handler] handler') :when (fn [route-meta] bool)? :named bool?}; :named applies only when a route lists it under :void.http/middleware"
  :schema {:name :keyword
           :phase [:int {:min 0 :max 10000}]
           :wrap :function
           :when [:optional :function]
           :named [:optional :boolean]
           :doc [:optional :string]}
  :validate (unique-by "middleware" |($ :name))
  :reduce |(sorted-by |[($ :phase) ($ :name)] $))

(plugin/defextension-point :void.http/route-meta-key
  :doc "Route metadata key declarations (ADR-0005): {:key :schema? :doc? :merge (:replace :concat :deep-merge :restrict)? :allow?}"
  :schema {:key :keyword
           :schema [:optional :any]
           :doc [:optional :string]
           :merge [:optional [:enum :replace :concat :deep-merge :restrict]]
           :allow? [:optional :function]}
  :validate (unique-by "metadata key" |($ :key))
  :reduce (fn [contribs]
            (def out @{})
            (each c contribs
              (put out (c :key)
                   (meta/declare-key (c :key)
                                     ;(mapcat (fn [[k v]] [k v])
                                              (pairs (merge-into @{} c {:key nil}))))))
            out))

(plugin/defextension-point :void.http/route-source
  :doc "Route sources: {:name :routes <router/routes value> :env <(router/env-ref (curenv)) for bare handler symbols>?}; every active source lands in the one route table"
  :schema {:name :keyword
           :routes :dictionary
           # a raw env table cannot live in a frozen manifest — wrap it
           # with router/env-ref
           :env [:optional :function]}
  :validate (unique-by "route source" |($ :name)))

(plugin/defextension-point :void.http/session-store
  :doc "Session store factories: {:name :make (fn [session-config] store)}; config [:http :session :store] picks one by name"
  :schema {:name :keyword :make :function}
  :validate (unique-by "session store" |($ :name))
  :reduce (fn [contribs] (tabseq [c :in contribs] (c :name) c)))

(plugin/defextension-point :void.http/body-codec
  :doc "Request body codecs: {:name :content-type :decode (fn [bytes] value) :encode?}; the parsing middleware decodes a matching request body into (req :parsed-body)"
  :schema {:name :keyword
           :content-type :string
           :decode :function
           :encode [:optional :function]}
  :validate (unique-by "body codec" |($ :name)))

(plugin/defextension-point :void.http/error-renderer
  :doc "Error renderers: {:name :fn (fn [err req ctx] response|nil) :priority?}; first response wins, priority order (default 1000)"
  :schema {:name :keyword
           :fn :function
           :priority [:optional :int]}
  :validate (unique-by "error renderer" |($ :name))
  :reduce |(sorted-by (fn [c] [(get c :priority 1000) (c :name)]) $))

# -- reserved metadata keys owned by the kernel (SPEC part II §2.5) ------

(plugin/defcontribution :void.http/route-meta-key
  {:key :void.http/middleware
   :schema [:vector :keyword]
   :doc "Named middleware this route opts into, concatenated group -> route"
   :merge :concat})

(plugin/defcontribution :void.http/route-meta-key
  {:key :void.http/timeout
   :schema [:number {:min 0.001}]
   :doc "Handler deadline in seconds; a more specific layer may only lower it"
   :merge :restrict
   :allow? (fn [outer inner] (<= inner outer))})

(plugin/defcontribution :void.http/route-meta-key
  {:key :void.http/max-body
   :schema [:int {:min 0}]
   :doc "Request body cap in bytes; a more specific layer may only lower it"
   :merge :restrict
   :allow? (fn [outer inner] (<= inner outer))})

# -- built-in middleware (through the same point other plugins use) ------

(plugin/defcontribution :void.http/middleware
  {:name :void.http/panic-guard
   :phase middleware/phase/panic-guard
   :doc "Exception -> response at the route chain edge (errors/wrap-panic)"
   :wrap (fn [handler]
           (fn panic-guard [req]
             (def ctx (context))
             ((errors/wrap-panic handler {:renderers (ctx :renderers)
                                          :dev (ctx :dev)})
              req)))})

(plugin/defcontribution :void.http/middleware
  {:name :void.http/parsing
   :phase middleware/phase/parsing
   :doc "Decode request bodies: urlencoded/multipart -> (req :form), registered body codecs -> (req :parsed-body)"
   :wrap (fn [handler]
           (fn parsing [req]
             (def ct (ring/request-header req "content-type"))
             (when (and ct (req :body))
               (cond
                 (string/has-prefix? "application/x-www-form-urlencoded" ct)
                 (put req :form (or (wire/parse-query (string (req :body))) @{}))

                 (multipart/boundary ct)
                 (do
                   (def [ok parts]
                     (protect (multipart/parse (req :body) (multipart/boundary ct))))
                   (unless ok (errors/abort 400 (string parts)))
                   (put req :multipart parts)
                   (put req :form (multipart/fields parts)))

                 (some (fn [c]
                         (when (string/has-prefix? (c :content-type) ct)
                           (put req :parsed-body ((c :decode) (req :body)))))
                       (get (context) :codecs []))))
             (handler req)))})

(plugin/defcontribution :void.http/middleware
  {:name :void.http/session
   :phase middleware/phase/session
   :doc "Cookie sessions over the configured :void.http/session-store"
   :when (fn [_] (not (nil? (get (context) :session))))
   :wrap (fn [handler]
           (fn session-mw [req]
             (def s (get (context) :session))
             (if s ((session/wrap-session handler s) req) (handler req))))})

(plugin/defcontribution :void.http/session-store
  {:name :memory
   :make (fn [_] (session/memory-store))})

# -- context build (:before-start hook) ----------------------------------

(defn- build-session [cfg stores workers]
  (def scfg (get cfg :session))
  (when (and scfg (not= false (scfg :enabled)))
    (def store-name (get scfg :store :memory))
    (def contrib
      (or (get stores store-name)
          (errorf "unknown session store %q (contributed: %s)"
                  store-name
                  (string/join (map |(string/format "%q" $) (sorted (keys stores))) " "))))
    (when (and (= :memory store-name) (> workers 1))
      (error "memory sessions cannot back :workers > 1 — each prefork worker has its own heap (ADR-0010); use an external session store"))
    {:store ((contrib :make) scfg)
     :ttl (get scfg :ttl 86400)
     :cookie (get scfg :cookie "void-session")}))

(defn- make-handler [ctx static-cfg]
  (def cell (ctx :cell))
  (var h
    (fn route-or-404 [req]
      (or (router/dispatch (router/current cell) req)
          (let [allowed (router/allowed-methods (router/current cell) (req :path))]
            (if (empty? allowed)
              (ring/not-found)
              (ring/response 405 "405 Method Not Allowed"
                             @{"allow" (string/join
                                         (map |(string/ascii-upper (string $)) allowed)
                                         ", ")
                               "content-type" "text/plain; charset=utf-8"}))))))
  (when static-cfg
    (set h (static/wrap-static h {:root (static-cfg :root)
                                  :prefix (get static-cfg :prefix "/")
                                  :index (get static-cfg :index "index.html")})))
  # outer guard: 404/405/static and anything outside a route chain
  (errors/wrap-panic h {:renderers (ctx :renderers) :dev (ctx :dev)}))

(defn build-context
  "Assemble the http context from a boot value: resolve the extension
  points, build and validate the route table (fail fast, batched),
  compose the handler. Sets current-context (the built-in middleware
  reads it from table-build time on). Normally called by the
  :before-start hook."
  [boot]
  (defn resolved [name] (get-in boot [:extensions name :resolved]))
  (def cfg (or (get-in boot [:config :values :http]) {}))
  (def workers (prefork/worker-count (get cfg :workers 1)))
  (def dev? (if (nil? (cfg :dev-errors))
              (= :dev (boot :profile))
              (cfg :dev-errors)))
  (def sources
    (seq [c :in (get-in boot [:extensions :void.http/route-source :contributions] [])]
      {:name (get-in c [:value :name] (c :plugin))
       :routes (get-in c [:value :routes])
       :env (get-in c [:value :env])}))
  (def ctx
    @{:config cfg
      :workers workers
      :dev dev?
      :renderers (resolved :void.http/error-renderer)
      :codecs (resolved :void.http/body-codec)
      :session (build-session cfg (or (resolved :void.http/session-store) @{}) workers)})
  # the built-in middleware closures ((context)) must see this context
  # already while the table build evaluates their :when predicates
  (set current-context ctx)
  (def table
    (router/build-table
      {:sources sources
       :meta-keys (or (resolved :void.http/route-meta-key) @{})
       :middleware (get-in boot [:extensions :void.http/middleware :contributions] [])
       :strict (get cfg :strict-meta false)}))
  (def cell (router/cell table))
  (put ctx :cell cell)
  (put ctx :build-args
       {:sources sources
        :meta-keys (or (resolved :void.http/route-meta-key) @{})
        :middleware (get-in boot [:extensions :void.http/middleware :contributions] [])
        :strict (get cfg :strict-meta false)})
  (put ctx :handler (make-handler ctx (cfg :static)))
  (put ctx :limits-fn
       (fn limits [method path]
         (when-let [[entry _] (router/match (router/current cell) method path)]
           {:max-body (get-in entry [:meta :void.http/max-body])
            :timeout (get-in entry [:meta :void.http/timeout])})))
  ctx)

(plugin/defcontribution :void.core/hooks
  {:hook :before-start
   :phase 500
   :name :http/build-table
   :doc "Build and validate the route table before anything listens"
   :fn (fn build! [boot] (build-context boot))})

# -- the server component ------------------------------------------------

(def server-component
  (system/component :http/server
    :doc "The HTTP listener — or, with :workers > 1 in the master
    process, the prefork supervisor for the workers that listen."
    :config {:key :http}
    :start
    (fn start [_ cfg0]
      (def ctx (context))
      (def cfg (or cfg0 {}))
      (if (and (> (ctx :workers) 1) (not (prefork/worker?)))
        @{:mode :master
          :master (prefork/start {:workers (ctx :workers)})}
        @{:mode :server
          :server (server/start
                    (merge
                      (tabseq [k :in [:host :port :max-header :max-body
                                      :read-timeout :idle-timeout
                                      :drain-timeout :max-connections]
                               :when (not (nil? (get cfg k)))]
                        k (cfg k))
                      {:handler (ctx :handler)
                       :limits-fn (ctx :limits-fn)}))}))
    :stop
    (fn stop [inst]
      (case (inst :mode)
        :master (prefork/stop (inst :master))
        :server (server/stop (inst :server))))
    :health
    (fn health [inst]
      (case (inst :mode)
        :master (let [n (length (prefork/alive (inst :master)))]
                  {:status (if (= n (get-in inst [:master :workers])) :up :degraded)
                   :workers n})
        :server {:status (if (server/draining? (inst :server)) :draining :up)
                 :connections (server/connections (inst :server))
                 :port (get-in inst [:server :port])}))))

# -- REPL / tooling surface ----------------------------------------------

(defn routes-table
  "The current route table."
  []
  (router/current ((context) :cell)))

(defn with-request
  ``Run a request through the full stack — routing, middleware,
  sessions, error rendering — without a socket (ROADMAP 1.1):

      (http/with-request {:uri "/orders/42?full=1"})
      (http/with-request {:method :post :uri "/orders"
                          :headers {"content-type" "application/x-www-form-urlencoded"}
                          :body "title=x"})

  Returns the response table.``
  [spec]
  (def ctx (context))
  (def uri (or (get spec :uri) (get spec :path) "/"))
  (def [path qs] (wire/split-path uri))
  (def req @{:method (get spec :method :get)
             :path path
             :raw-path uri
             :query-string qs
             :query (or (wire/parse-query qs) @{})
             :headers (merge @{} (get spec :headers {}))
             :http-version 1
             :body (get spec :body)})
  ((ctx :handler) req))

(defn explain-route
  "The routing verdict and per-key metadata provenance for a path (see
  router/explain-route); nil when nothing matches."
  [path &opt method]
  (router/explain-route (routes-table) path method))

(defn url-for
  "Reverse routing by route name against the current table."
  [name &opt params query]
  (router/url-for (routes-table) name params query))

(defn print-routes
  ``Print the route table (the `void routes` CLI command). With :keys
  each route also lists its merged metadata, one key per line — :name
  aside, since it is already a column.``
  [table &opt opts]
  (def entries
    (sorted-by |[($ :pattern) (string ($ :method))] (table :routes)))
  (def rows
    (seq [e :in entries]
      [(string/ascii-upper (string (e :method)))
       (e :pattern)
       (string/format "%q" (e :name))
       (if (symbol? (e :handler)) (string (e :handler)) "<fn>")
       (string/format "%q" (e :source))]))
  (def widths
    (seq [i :range [0 4]]
      (max 1 ;(map |(length ($ i)) rows))))
  (each [row e] (map tuple rows entries)
    (printf "%s  %s  %s  %s  %s"
            ;(seq [i :range [0 4]]
               (string/format (string "%-" (widths i) "s") (row i)))
            (row 4))
    (when (get opts :keys)
      (each k (sorted (filter |(not= :name $) (keys (e :meta))))
        (printf "  %q %q" k (get-in e [:meta k]))))))

(plugin/defcontribution :void.core/cli
  {:name :routes
   :doc "Print the route table: void routes [--keys]"
   :fn (fn cli-routes [& args]
         (each a args
           (unless (= a "--keys")
             (errorf "void routes: unknown flag %q (only --keys)" a)))
         (print-routes (routes-table)
                       {:keys (truthy? (index-of "--keys" args))}))})

(defn rebuild!
  "Rebuild the route table from the booted sources and swap it
  atomically — after REPL work that changes patterns or metadata
  (handler redefinitions are live without this, ADR-0002)."
  []
  (def ctx (context))
  (router/swap! (ctx :cell) (router/build-table (ctx :build-args))))

# -- manifest ------------------------------------------------------------

(def Config
  "Schema of the :http config slice."
  {:host [:optional :string]
   :port [:optional [:int {:min 0 :max 65535}]]
   :workers [:optional [:or [:int {:min 1}] [:enum :auto]]]
   :max-header [:optional [:int {:min 256}]]
   :max-body [:optional [:int {:min 0}]]
   :read-timeout [:optional [:number {:min 0.001}]]
   :idle-timeout [:optional [:number {:min 0.001}]]
   :drain-timeout [:optional [:number {:min 0}]]
   :max-connections [:optional [:int {:min 1}]]
   :strict-meta [:optional :boolean]
   :dev-errors [:optional :boolean]
   :session [:optional {:enabled [:optional :boolean]
                        :store [:optional :keyword]
                        :ttl [:optional [:number {:min 1}]]
                        :cookie [:optional :string]}]
   :static [:optional {:root :string
                       :prefix [:optional :string]
                       :index [:optional :string]}]})

(plugin/defplugin void/http
  :doc "HTTP kernel: net/ev server (keep-alive, limits, chunked, SSE, graceful drain), PEG router with symbol handlers and metadata merge, phased middleware, sessions, static files, prefork workers."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1"}
  :config-key :http
  :config-schema Config
  :config-defaults {:host "127.0.0.1"
                    :port 8080
                    :workers 1
                    :max-header 8192
                    :max-body 1048576
                    :read-timeout 30
                    :idle-timeout 75
                    :drain-timeout 15
                    :max-connections 1024}
  :components [server-component])
