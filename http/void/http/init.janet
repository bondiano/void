### void/http — the HTTP kernel plugin (SPEC.md §5.1, ADR-0006).
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

(import spork/json)
(import void/core/plugin :as plugin)
(import void/core/system :as system)
(import void/core/meta :as meta)
(import void/core/hooks :as corehooks)
(import void/core/log :as log)
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

(defn- callable? [x]
  (or (function? x) (cfunction? x)))

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

(plugin/defextension-point :void.http/hook
  :doc "Global request-lifecycle hooks (ADR-0016): {:stage <see middleware/stages> :name :fn <fn or symbol> :env <(router/env-ref (curenv)) for bare symbols>?}; per-route hooks go in :void.http/hooks metadata"
  :schema {:stage [:enum :on-request :pre-parsing :pre-validation
                   :pre-handler :pre-serialization :on-send
                   :on-response :on-error :on-timeout]
           :name :keyword
           :fn [:or :function :symbol]
           :env [:optional :function]
           :doc [:optional :string]}
  :validate (unique-by "lifecycle hook" |($ :name))
  :reduce |(sorted-by (fn [c] [(c :stage) (c :name)]) $))

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
  :doc "Route sources: {:name :routes <router/routes value, or (fn [boot] routes-value)> :env <(router/env-ref (curenv)) for bare handler symbols>?}; every active source lands in the one route table. The function form exists for a source that is a *projection* of something resolved during bootstrap — void/admin turns its resource registry and the pages contributed to :void.admin/page into real routes, and neither is knowable when the manifest freezes. It is called once per table build, so a rebuild after a reload re-projects."
  :schema {:name :keyword
           :routes [:or :dictionary :function]
           # a raw env table cannot live in a frozen manifest — wrap it
           # with router/env-ref
           :env [:optional :function]}
  :validate (unique-by "route source" |($ :name)))

(plugin/defextension-point :void.http/edge
  :doc "Wrappers around the *whole* handler, outside routing and outside the panic guard: {:name :phase <int, default 9000> :wrap (fn [handler] handler')}. Middleware wraps one route's chain, so a 404, a 405, a static file and a response the panic guard rendered never pass through it — anything that must touch every response this process emits (security headers, a CORS preflight for a path with no route) belongs here instead. Lowest phase outermost; an error escaping an edge wrapper reaches the server's last-resort 500, so keep them total."
  :schema {:name :keyword
           :phase [:optional :int]
           :wrap :function
           :doc [:optional :string]}
  :validate (unique-by "edge wrapper" |($ :name))
  :reduce (fn [contribs]
            (tuple ;(sorted-by (fn [c] [(get c :phase 9000) (string (c :name))]) contribs))))

(plugin/defextension-point :void.http/session-store
  :doc "Session store factories: {:name :make (fn [session-config] store) :shared? boolean :replacement string?}; config [:http :session :store] picks one by name. :shared? is the answer to \"would a second replica see this session\" (ADR-0030) — a store that does not say is taken to live in one process's heap, because that is what a store written without the question in mind is"
  :schema {:name :keyword
           :make :function
           :shared? [:optional :boolean]
           :replacement [:optional :string]}
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

(plugin/contribute! :void.http/route-meta-key
  {:key :void.http/middleware
   :schema [:vector :keyword]
   :doc "Named middleware this route opts into, concatenated group -> route"
   :merge :concat})

(plugin/contribute! :void.http/route-meta-key
  {:key :void.http/timeout
   :schema [:number {:min 0.001}]
   :doc "Handler deadline in seconds; a more specific *metadata* layer may only lower it (group -> route). `[:http :read-timeout]` and the server's own limits are not metadata layers: a route that declares nothing inherits them, and one that declares a deadline is bounded by the group above it and by nothing else"
   :merge :restrict
   :allow? (fn [outer inner] (<= inner outer))})

(plugin/contribute! :void.http/route-meta-key
  {:key :void.http/max-body
   :schema [:int {:min 0}]
   :doc "Request body cap in bytes; a more specific *metadata* layer may only lower it (group -> route). `[:http :max-body]` is not one of those layers: it is what a route that declares nothing gets, so a single route that has to accept more than the rest of the application says so on itself and raises nothing for anybody else"
   :merge :restrict
   :allow? (fn [outer inner] (<= inner outer))})

(plugin/contribute! :void.http/route-meta-key
  {:key :void.http/hooks
   :schema :dictionary
   :doc "Route-level lifecycle hooks (ADR-0016): {stage [fn-or-symbol ...]}; concatenated per stage, group hooks before route hooks"
   :merge :concat})

# -- built-in middleware (through the same point other plugins use) ------

(plugin/contribute! :void.http/middleware
  {:name :void.http/panic-guard
   :phase middleware/phase/panic-guard
   :doc "Exception -> response at the route chain edge (errors/wrap-panic; runs the :on-error stage hooks before the renderers)"
   :wrap (fn [handler]
           (fn panic-guard [req]
             (def ctx (context))
             ((errors/wrap-panic handler
                                 {:renderers (ctx :renderers)
                                  :dev (ctx :dev)
                                  :on-error
                                  (fn route-on-error [r]
                                    (tuple ;(get ctx :on-error-global [])
                                           ;(get-in r [:void/route :hooks :on-error] [])))})
              req)))})

# per-process random prefix + counter (fastify's genReqId model: a bare
# counter, no crypto and no header lookup on the hot path; the prefix
# disambiguates processes/workers in aggregated logs)
(def- request-id-prefix
  (let [b (os/cryptorand 4)]
    (string/join (seq [x :in b] (string/format "%02x" x)))))
(var- request-id-counter 0)

(plugin/contribute! :void.http/middleware
  {:name :void.http/request-id
   :phase middleware/phase/observability
   :doc "Mint the request id ((req :request-id)) and bind it to the log context (ADR-0018); config [:http :request-id-header] names a trusted inbound header to take instead (off by default, fastify-style)"
   :wrap (fn [handler]
           # :wrap runs at table-build time — the context (and config)
           # already exist, so the header choice costs nothing per request
           (def hdr (get-in (context) [:config :request-id-header]))
           (fn request-id-mw [req]
             (def id (or (when hdr (ring/request-header req hdr))
                         (string request-id-prefix "-" (++ request-id-counter))))
             (put req :request-id id)
             (log/with-context {:request-id id}
               (handler req))))})

(plugin/contribute! :void.http/middleware
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
                           # a body that does not decode is the client's
                           # error, not this process's — same verdict the
                           # multipart branch above already gives. A codec
                           # that raised a structured error already chose
                           # its status and wording; only a raw decoder
                           # error gets the generic 400
                           (def [ok v] (protect ((c :decode) (req :body))))
                           (unless ok
                             (if (and (dictionary? v) (get v :http/status))
                               (error v)
                               (errors/abort 400 (string/format "malformed %s body"
                                                                (c :content-type)))))
                           (put req :parsed-body v)))
                       (get (context) :codecs []))))
             (handler req)))})

(plugin/contribute! :void.http/middleware
  {:name :void.http/session
   :phase middleware/phase/session
   :doc "Cookie sessions over the configured :void.http/session-store"
   :when (fn [_] (not (nil? (get (context) :session))))
   :wrap (fn [handler]
           (fn session-mw [req]
             (def s (get (context) :session))
             (if s ((session/wrap-session handler s) req) (handler req))))})

(plugin/contribute! :void.http/session-store
  {:name :memory
   :make (fn [_] (session/memory-store))
   :shared? false
   :replacement "sessions in a store every replica reads: compose void/redis-http and set [:http :session :store] :redis, or void/db-http and :db"})

(plugin/contribute! :void.core/store
  {:name :void.http/session
   :what "sessions"
   :doc "The session store this composition resolved — the one a user's next request lands on, whichever replica accept() gave it"
   :ask (fn ask-session [_boot]
          (when-let [s (get (context) :session)]
            {:store (get s :store-name :anonymous)
             :shared? (s :shared?)
             :replacement (get s :replacement
                               "a session store several replicas share")}))})

# -- the error path, without the throw -----------------------------------

(defn render-error
  ``The response the error path would produce for `err` on `req` —
  the :void.http/error-renderer contributions in priority order
  (problem+json once void/rest is in the composition, the dev page in
  dev, terse text otherwise), the built-in renderer as the floor —
  reached by calling instead of by throwing. `status` overrides the
  one carried by a structured error.

  For middleware that *decides* on a status rather than failing at
  one: load shedding (ADR-0019) answers 503 to requests it refuses,
  and a throw there would buy a stacktrace per refused request at
  exactly the moment the process has none to spare. Anything that is
  genuinely an error still throws — the panic guard runs the
  :on-error stage hooks, which this does not.``
  [err req &opt status]
  (def ctx (context))
  (errors/render (ctx :renderers) err req
                 {:status (or status
                              (when (and (dictionary? err) (int? (err :http/status)))
                                (err :http/status))
                              500)
                  :dev (ctx :dev)}))

# -- context build (:before-start hook) ----------------------------------

(defn- build-session [cfg stores profile]
  (def scfg (get cfg :session))
  (when (and scfg (not= false (scfg :enabled)))
    (def store-name (get scfg :store :memory))
    (def contrib
      (or (get stores store-name)
          (errorf "unknown session store %q (contributed: %s)"
                  store-name
                  (string/join (map |(string/format "%q" $) (sorted (keys stores))) " "))))
    # nothing here refuses the memory store any more: "sessions in a
    # heap" is one instance of a class the deployment shape answers for
    # everybody at once, and it is `[:deploy :shape] :fleet` that says
    # no — with prefork workers as one of the ways to be a fleet
    # (ADR-0030, ADR-0010). The declaration below is what it asks.
    {:store ((contrib :make) scfg)
     :store-name store-name
     :shared? (truthy? (get contrib :shared?))
     :replacement (get contrib :replacement)
     :ttl (get scfg :ttl 86400)
     :cookie (get scfg :cookie "void-session")
     # [:http :session :cookie-opts] reaches wrap-session as-is, over
     # one profile-shaped default: production is behind TLS (ADR-0010's
     # relay), so its session cookie is Secure unless the config says
     # otherwise
     :cookie-opts (merge (if (= :prod profile) {:secure true} {})
                         (get scfg :cookie-opts {}))}))

(defn- access-log! [req resp]
  (def us
    (when-let [t (req :received)]
      # integer microseconds: precise, and no float-repr noise in %j
      (math/round (* 1000000 (- (os/clock :monotonic) t)))))
  (log/info "request" :ns "void.http.access"
            :method (req :method) :path (req :path)
            :status (resp :status) :us us
            :request-id (req :request-id)))

(defn- resolve-global-hooks
  "The :void.http/hook contributions -> stage -> tuple of resolved
  callables (symbols resolve against the contribution's :env, ADR-0002)."
  [contribs]
  (def by-stage @{})
  (each c (or contribs [])
    (def env (let [e (c :env)] (if (callable? e) (e) e)))
    (def call (router/resolve-callable
                (c :fn) env
                (string/format "%q hook %q" (c :stage) (c :name))))
    (array/push (or (get by-stage (c :stage))
                    (let [a @[]] (put by-stage (c :stage) a) a))
                call))
  (freeze by-stage))

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
  # outer guard: 404/405/static and anything outside a route chain —
  # only the global :on-error hooks apply (no route matched)
  (set h (errors/wrap-panic h {:renderers (ctx :renderers)
                               :dev (ctx :dev)
                               :on-error (fn [_] (get ctx :on-error-global []))}))
  # :void.http/edge wraps everything, the panic guard included: every
  # response this process emits passes through here, which is what a
  # security header and a CORS preflight for an unrouted path need.
  # Lowest phase outermost, the same convention middleware uses.
  (def edge (get ctx :edge []))
  (loop [i :down-to [(dec (length edge)) 0]]
    (set h (((in edge i) :wrap) h)))
  h)

(defn- projected-routes
  ``The :routes of a source, with the function form applied to the boot
  value: a source that projects something bootstrap resolved (void/admin
  turns its resource registry into routes) cannot carry the value in a
  frozen manifest, so it carries the projection instead.``
  [name routes boot]
  (if (callable? routes)
    (let [[ok v] (protect (routes boot))]
      (unless ok
        (errorf "route source %q: projecting its routes failed: %s" name v))
      (unless (and (dictionary? v) (get v :routes))
        (errorf "route source %q: its projection returned %q, not a router/routes value" name v))
      v)
    routes))

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
       :routes (projected-routes (get-in c [:value :name] (c :plugin))
                                 (get-in c [:value :routes]) boot)
       :env (get-in c [:value :env])}))
  (def global-hooks (resolve-global-hooks (resolved :void.http/hook)))
  (def ctx
    @{:config cfg
      :workers workers
      :dev dev?
      :renderers (resolved :void.http/error-renderer)
      :codecs (resolved :void.http/body-codec)
      :access-log (not= false (cfg :access-log))
      :edge (tuple ;(or (resolved :void.http/edge) []))
      :on-error-global (tuple ;(get global-hooks :on-error []))
      :on-timeout-global (tuple ;(get global-hooks :on-timeout []))
      :on-response-global (tuple ;(get global-hooks :on-response []))
      :session (build-session cfg (or (resolved :void.http/session-store) @{})
                              (boot :profile))})
  # the built-in middleware closures ((context)) must see this context
  # already while the table build evaluates their :when predicates
  (set current-context ctx)
  (def build-args
    {:sources sources
     :meta-keys (or (resolved :void.http/route-meta-key) @{})
     :middleware (get-in boot [:extensions :void.http/middleware :contributions] [])
     :stage-hooks global-hooks
     :strict (get cfg :strict-meta false)})
  (def table (router/build-table build-args))
  # the :void.http/route-added app hook (ADR-0016): plugins see every
  # entry at build time (validation, derived registrations) — a
  # handler error fails the boot
  (each e (table :routes)
    (corehooks/run! (boot :hooks) :void.http/route-added boot e))
  (def cell (router/cell table))
  (put ctx :cell cell)
  (put ctx :build-args build-args)
  (put ctx :handler (make-handler ctx (cfg :static)))
  (put ctx :limits-fn
       (fn limits [method path]
         (when-let [[entry _] (router/match (router/current cell) method path)]
           {:max-body (get-in entry [:meta :void.http/max-body])
            :timeout (get-in entry [:meta :void.http/timeout])})))
  (put ctx :notify-response
       (fn notify-response [req resp]
         (each h (ctx :on-response-global) (protect (h req resp)))
         (each h (get-in req [:void/route :hooks :on-response] [])
           (protect (h req resp)))
         (when (ctx :access-log)
           (protect (access-log! req resp)))))
  (put ctx :notify-timeout
       (fn notify-timeout [req]
         (each h (ctx :on-timeout-global) (protect (h req)))
         (each h (get-in req [:void/route :hooks :on-timeout] [])
           (protect (h req)))))
  ctx)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 500
   :name :http/build-table
   :doc "Build and validate the route table before anything listens"
   :fn (fn build! [boot] (build-context boot))})

(defn- request-from-raw
  "A whole raw HTTP request (bytes) -> request table, through the same
  wire parser the server uses (ADR-0017 :raw mode: limits, smuggling
  vectors, malformed input). The body is the bytes past the head —
  no chunked decoding in the inject path."
  [raw]
  (def head (wire/parse-request-head raw))
  (cond
    (nil? head) (error "raw request: incomplete head (no \\r\\n\\r\\n)")
    (= :error head) (error "raw request: malformed head"))
  (def raw-path (head :path))
  (def [path qs] (wire/split-path raw-path))
  (def body-bytes (string/slice raw (head :head-size)))
  @{:method (keyword (string/ascii-lower (head :method)))
    :path path
    :raw-path raw-path
    :query-string qs
    :query (or (wire/parse-query qs) @{})
    :headers (head :headers)
    :http-version (head :http-version)
    :received (os/clock :monotonic)
    :arrived (os/clock :monotonic)
    :body (if (empty? body-bytes) nil body-bytes)})

(defn make-request
  ``An in-memory request table from an inject/with-request spec
  (ADR-0017): :method (:get, or :post once a body sugar is present),
  :uri/:path, :headers, :body — plus sugar: :json <value> encodes and
  sets the content type, :form <dict> urlencodes, :raw <bytes> parses
  a whole HTTP request through the server's wire parser instead.``
  [spec]
  (if (get spec :raw)
    (request-from-raw (get spec :raw))
    (do
      (def uri (or (get spec :uri) (get spec :path) "/"))
      (def [path qs] (wire/split-path uri))
      (def headers (merge @{} (get spec :headers {})))
      (var body (get spec :body))
      (var default-method :get)
      (when-let [j (get spec :json)]
        (set body (json/encode j))
        (put headers "content-type" "application/json")
        (set default-method :post))
      (when-let [f (get spec :form)]
        (set body (wire/encode-query f))
        (put headers "content-type" "application/x-www-form-urlencoded")
        (set default-method :post))
      @{:method (get spec :method default-method)
        :path path
        :raw-path uri
        :query-string qs
        :query (or (wire/parse-query qs) @{})
        :headers headers
        :http-version 1
        :received (os/clock :monotonic)
        # the queue-time base the server stamps in read-head: on the
        # inject path (ADR-0017) a request arrives when it is made
        :arrived (os/clock :monotonic)
        :body body})))


# -- the kernel and server components (ADR-0017) -------------------------

(defn- run-app-hook
  "Run an app-level http hook (:void.http/listening / :draining) on
  the current boot's registry, protected — transport notifications
  never block start/stop."
  [hook & args]
  (when-let [b plugin/current-boot]
    (each e (corehooks/run-protected! (b :hooks) hook b ;args)
      (eprint e))))

(def kernel-component
  (system/component :http/kernel
    :doc "The socket-free HTTP kernel: route table, precompiled chains
    and lifecycle hooks, the composed handler — zero I/O. Tests start
    :only [:http/kernel] (ADR-0017): the app is fully wired, no port
    opens; test/inject and with-request run against it."
    :start
    (fn start [_ _]
      (def ctx (context))
      # a duck-typed surface: void/test's inject client drives the
      # kernel through these fields alone — void/dev (wave 0) never
      # imports void/http (wave 1)
      @{:handler (ctx :handler)
        :limits-fn (ctx :limits-fn)
        :make-request make-request
        :serialize server/serialize-response
        :notify-response (ctx :notify-response)
        :notify-timeout (ctx :notify-timeout)})
    :health (fn health [_] {:status :up})))

(def server-component
  (system/component :http/server
    :doc "The HTTP listener over :http/kernel — or, with :workers > 1
    in the master process, the prefork supervisor for the workers that
    listen."
    :deps [:http/kernel]
    :config {:key :http}
    :start
    (fn start [_ cfg0]
      (def ctx (context))
      (def cfg (or cfg0 {}))
      (if (and (> (ctx :workers) 1) (not (prefork/worker?)))
        @{:mode :master
          :master (prefork/start {:workers (ctx :workers)})}
        (do
          (def srv (server/start
                     (merge
                       (tabseq [k :in [:host :port :max-header :max-body
                                       :read-timeout :idle-timeout
                                       :head-timeout :body-timeout
                                       :drain-timeout :max-connections
                                       :yield-budget]
                                :when (not (nil? (get cfg k)))]
                         k (cfg k))
                       {:handler (ctx :handler)
                        :limits-fn (ctx :limits-fn)
                        :on-response (ctx :notify-response)
                        :on-timeout (ctx :notify-timeout)})))
          (run-app-hook :void.http/listening srv)
          @{:mode :server :server srv})))
    :stop
    (fn stop [inst]
      (case (inst :mode)
        :master (prefork/stop (inst :master))
        :server (do (run-app-hook :void.http/draining (inst :server))
                    (server/stop (inst :server)))))
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
  sessions, error rendering — without a socket:

      (http/with-request {:uri "/orders/42?full=1"})
      (http/with-request {:method :post :uri "/orders"
                          :headers {"content-type" "application/x-www-form-urlencoded"}
                          :body "title=x"})

  Accepts make-request's :json/:form/:raw sugar too. Returns the
  response table (the REPL helper — test/inject in void/test adds the
  cookie jar, wire serialization and the :on-response stage).``
  [spec]
  (((context) :handler) (make-request spec)))

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

(plugin/contribute! :void.core/cli
  {:name :routes
   :read-only? true
   :doc "Print the route table: void routes [--keys]"
   :fn (fn cli-routes [& args]
         (each a args
           (unless (= a "--keys")
             (errorf "void routes: unknown flag %q (only --keys)" a)))
         (print-routes (routes-table)
                       {:keys (truthy? (index-of "--keys" args))}))})

(defn- live-sources
  ``Route sources re-read from the live manifest registry: a dofile
  reload of an app module re-runs its `defplugin`, which re-registers
  the manifest — so the registry holds the *current* :void.http/route-source
  contributions while the boot value holds the boot-time snapshot.
  Boot-time source order is preserved (route precedence must not change
  under a rebuild); sources contributed after boot append at the end.``
  [boot fallback]
  (def live @[])
  (each pname (boot :active)
    (def m (or (get plugin/manifest-registry pname)
               (get-in boot [:manifests pname])))
    (each c (get-in m [:contributes :void.http/route-source] [])
      (array/push live {:name (get c :name pname)
                        :routes (projected-routes (get c :name pname) (c :routes) boot)
                        :env (c :env)})))
  (def by-name (tabseq [s :in live] (s :name) s))
  (def out @[])
  (each s fallback
    (when-let [l (get by-name (s :name))]
      (put by-name (s :name) nil)
      (array/push out l)))
  (each s live
    (when (get by-name (s :name))
      (put by-name (s :name) nil)
      (array/push out s)))
  out)

(defn rebuild!
  "Rebuild the route table and swap it atomically — after code changes
  that add routes or edit patterns/metadata (handler redefinitions are
  live without this, ADR-0002). Route sources are re-read from the
  live manifest registry, so a watcher/dofile reload of an app module
  is enough; the :void.dev/reloaded hook below calls this for you."
  []
  (def ctx (context))
  (def args (ctx :build-args))
  (def sources
    (if-let [boot plugin/current-boot]
      (live-sources boot (args :sources))
      (args :sources)))
  (router/swap! (ctx :cell)
                (router/build-table (merge args {:sources sources}))))

(plugin/contribute! :void.core/hooks
  {:hook :void.dev/reloaded
   :phase 500
   :name :http/rebuild-table
   :doc "Rebuild + atomically swap the route table after the dev watcher reloads modules (new routes, pattern and metadata edits go live)"
   :fn (fn on-reloaded [boot report]
         (when (and current-context (not (empty? (get report :reloaded []))))
           (rebuild!)
           (eprint "void/http route table rebuilt")))})

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
   :head-timeout [:optional [:number {:min 0.001}]]
   :body-timeout [:optional [:number {:min 0.001}]]
   :drain-timeout [:optional [:number {:min 0}]]
   :max-connections [:optional [:int {:min 1}]]
   # seconds of synchronous work a connection fiber may do before it
   # yields the loop one turn; 0 turns the fairness yield off
   # (server.janet documents why it exists)
   :yield-budget [:optional [:number {:min 0}]]
   :strict-meta [:optional :boolean]
   :dev-errors [:optional :boolean]
   :access-log [:optional :boolean]
   :request-id-header [:optional :string]
   :session [:optional {:enabled [:optional :boolean]
                        :store [:optional :keyword]
                        :ttl [:optional [:number {:min 1}]]
                        :cookie [:optional :string]
                        :cookie-opts [:optional
                                      {:path [:optional :string]
                                       :domain [:optional :string]
                                       :max-age [:optional :int]
                                       :expires [:optional :string]
                                       :secure [:optional :boolean]
                                       :http-only [:optional :boolean]
                                       :same-site [:optional [:enum :strict :lax :none]]}]}]
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
                    :head-timeout 30
                    :body-timeout 300
                    :drain-timeout 15
                    :max-connections 1024
                    :yield-budget 0.002}
  :components [kernel-component server-component])
