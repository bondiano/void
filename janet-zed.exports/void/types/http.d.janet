# Types of void/http's values, named where they recur.

# -- the wire ------------------------------------------------------------

# A parsed header table: `wire/parse-request-head` and `parse-response-head` accumulate
# it — lowercase names, a repeated header an array of its values.
(def HttpHeaders :typedef
  @{:string (or :string @[:string])})

# A request head: the table `wire/parse-request-head` builds.
(def HttpRequestHead :typedef
  @{:method :string :path :string :http-version [:number :number]
    :headers HttpHeaders :head-size :number})

# A response head: the table `wire/parse-response-head` builds.
(def HttpResponseHead :typedef
  @{:status :number :message :string :http-version [:number :number]
    :headers HttpHeaders :head-size :number})

# -- the ring model ------------------------------------------------------

# The request a handler receives: built by `server/build-request` (and `make-request` on
# the inject path), extended by middleware (`:params`, `:void/route`, `:form`,
# `:session`, `:cookies`, …) — hence open.
(def HttpRequest :typedef
  @{:method :keyword :path :string :raw-path :string :query-string :string?
    :query @{:string :any} :headers HttpHeaders :http-version [:number :number]
    :body :any :received :number :arrived :number? :remote-addr :string? & r})

# A response: the table `ring/response` builds, or a struct literal a handler returns;
# `ring/upgrade` and handlers add keys (`:void.http/upgrade`, `:session`) — hence open.
(def HttpResponse :typedef
  (or @{:status :number :headers (or @{:string :any} {:string :any} :nil) :body :any & r}
      {:status :number :headers (or @{:string :any} {:string :any} :nil) :body :any & r}))

# A handler: what the server, routing and every middleware wrapper call.
(def HttpHandler :typedef
  (fn [HttpRequest] HttpResponse))

# Set-Cookie attributes: written by callers of `ring/cookie-str` and merged by
# `ring/delete-cookie` and `session/wrap-session`.
(def HttpCookieOptions :typedef
  (or {:path :string? :domain :string? :max-age :number? :expires :string?
       :secure :boolean? :http-only :boolean?
       :same-site (or (enum :strict :lax :none) :nil) & r}
      @{:path :string? :domain :string? :max-age :number? :expires :string?
        :secure :boolean? :http-only :boolean?
        :same-site (or (enum :strict :lax :none) :nil) & r}))

# A multipart part: the table `multipart/parse` builds, or the struct a caller hands
# `multipart/encode`.
(def HttpMultipartPart :typedef
  (or @{:name :string? :filename :string? :content-type :string?
        :headers (or @{:any :any} {:any :any} :nil) :value :any & r}
      {:name :string? :filename :string? :content-type :string?
       :headers (or @{:any :any} {:any :any} :nil) :value :any & r}))

# -- routing -------------------------------------------------------------

# One route declaration: the struct `router/route` (and GET, POST, …) builds.
(def HttpRouteDeclaration :typedef
  {:route :boolean :method :keyword :pattern :string
   :handler (or :symbol :function) :meta {:keyword :any}})

# A routes value: the struct `router/routes` builds — a global metadata layer over
# route declarations, groups and nested routes values.
(def HttpRoutes :typedef
  {:routes :boolean :global {:keyword :any} :children [:any]})

# A :void.http/route-source contribution: written by `defroutes`, rebuilt by the table
# build from the live manifests.
(def HttpRouteSource :typedef
  {:name :keyword
   :routes (or HttpRoutes (fn [:any] HttpRoutes))
   :env (or (fn [] :table) :table :nil)})

# A :void.http/middleware contribution value: written by plugins, `middleware/stage-wrapper`
# builds the synthetic ones, `resolve-phases` numbers a relative placement.
(def HttpMiddleware :typedef
  {:name :keyword :phase :number? :before :keyword? :after :keyword?
   :wrap (or :function :cfunction) :when (or :function :cfunction :nil)
   :named :boolean? :route-aware :boolean? :doc :string?})

# A middleware contribution attributed to its plugin: boot's resolution builds it, the
# table build adds the `:stage` ones.
(def HttpMiddlewareContribution :typedef
  {:plugin :keyword :value HttpMiddleware :stage :boolean?})

# One chain step as data: `middleware/describe` builds it, `select` merges a `:reason`
# into the declined ones.
(def HttpChainStep :typedef
  (or {:name :keyword :phase :number :plugin :keyword :stage :boolean?
       :before :keyword? :after :keyword? :reason :keyword?}
      @{:name :keyword :phase :number :plugin :keyword :stage :boolean?
        :before :keyword? :after :keyword? :reason :keyword?}))

# A route table entry: built by `router/build-table`, frozen with the table; dispatch
# puts it at (req :void/route).
(def HttpRoute :typedef
  {:name :keyword :method :keyword :pattern :string :params [:keyword]
   :peg (or :abstract :nil) :static :string? :handler (or :symbol :function)
   :no-reload :boolean :meta {:keyword :any} :provenance {:keyword :any}
   :warnings [:string] :chain HttpHandler :middleware [:keyword]
   :steps [HttpChainStep] :declined [HttpChainStep] :hooks {:keyword :any}
   :source :keyword})

# The route table: the frozen struct `router/build-table` builds.
(def HttpRouteTable :typedef
  {:routes [HttpRoute]
   :by-name {:keyword HttpRoute}
   :static {:keyword {:string HttpRoute}}
   :dynamic {:keyword [HttpRoute]}})

# The one-slot holder of the current table: the table `router/cell` builds.
(def HttpRouteCell :typedef
  @{:table HttpRouteTable?})

# -- errors --------------------------------------------------------------

# The context an error renderer is called with: built by `errors/wrap-panic` and
# `render-error`.
(def HttpErrorContext :typedef
  {:status :number :dev :any :stacktrace :string? :error :any})

# A :void.http/error-renderer contribution value, written by plugins.
(def HttpErrorRenderer :typedef
  {:name :keyword :fn (or :function :cfunction) :priority :number?})

# -- sessions ------------------------------------------------------------

# A session store: the struct a :void.http/session-store `:make` returns
# (`session/memory-store`, void/redis-http, void/db-http) — each adds keys of its own.
(def HttpSessionStore :typedef
  {:name :keyword?
   :load (fn [:string] (or @{:any :any} :nil))
   :save (fn [:string @{:any :any} :number] :string)
   :delete (fn [:string] :any)
   :sweep (fn [] :any)
   & r})

# -- the kernel ----------------------------------------------------------

# The http context: the table `build-context` assembles at :before-start.
(def HttpContext :typedef
  @{:boot Boot :config :any :workers :number :dev :boolean
    :renderers (or @[HttpErrorRenderer] :nil) :codecs :any :access-log :boolean
    :edge :tuple :edge-info :tuple :on-error-global :tuple :on-timeout-global :tuple
    :on-response-global :tuple :session (or :any :nil) :cell HttpRouteCell
    :build-args :any :handler HttpHandler :limits-fn (fn [:any :any] :any)
    :notify-response (fn [HttpRequest HttpResponse] :any)
    :notify-timeout (fn [HttpRequest] :any)})

# A running listener: the table `server/start` builds.
(def HttpServer :typedef
  @{:listener :abstract
    :state @{:conns @{:abstract :any} :draining :boolean}
    :accept-fiber :fiber
    :host :string
    :port :number
    :config @{:keyword :any}})

# A prefork master: the table `prefork/start` builds.
(def HttpPreforkMaster :typedef
  @{:procs @{:number :abstract} :workers :number :stopping :boolean
    :cmd (or [:string] @[:string])})

# -- the client ----------------------------------------------------------

# A client for one host: the table `client/open` builds; `send!` fills and clears `:conn`
# (a socket, or the table stream `void/tls` connects).
(def HttpClient :typedef
  @{:host :string :port :string :scheme :string :authority :string
    :headers (or @{:any :any} {:any :any}) :cookies (or @{:any :any} {:any :any})
    :timeout :number? :connect-timeout :number? :max-body :number :keep-alive :boolean
    :conn (or :abstract @{:read :function :write :function :close :function & r} :nil)
    :buf :buffer})

# What the client answers: the table `read-response!` builds; `request` adds `:url` and
# `:redirects`, and an `around-request` wrapper may add its own — hence open.
(def HttpClientResponse :typedef
  @{:status :number :message :string :http-version [:number :number]
    :headers HttpHeaders :body :string? :bytes :number :close :boolean
    :url :string? :redirects :tuple? & r})

# A client request: the struct a caller hands `request`, `send!` and the verb helpers, or
# the table `follow-target` builds for the next hop.
(def HttpRequestOptions :typedef
  (or {:url :string? :method :any :target :string? :path :string?
       :query (or @{:any :any} {:any :any} :string :nil)
       :headers (or @{:any :any} {:any :any} :nil) :cookies (or @{:any :any} {:any :any} :nil)
       :body :any :form (or @{:any :any} {:any :any} :nil)
       :multipart (or @[HttpMultipartPart] [HttpMultipartPart] :nil)
       :timeout :number? :connect-timeout :number? :max-body :number?
       :keep-alive :boolean? :close :boolean? :user-agent :string? :follow :number? & r}
      @{:url :string? :method :any :target :string? :path :string?
        :query (or @{:any :any} {:any :any} :string :nil)
        :headers (or @{:any :any} {:any :any} :nil) :cookies (or @{:any :any} {:any :any} :nil)
        :body :any :form (or @{:any :any} {:any :any} :nil)
        :multipart (or @[HttpMultipartPart] [HttpMultipartPart] :nil)
        :timeout :number? :connect-timeout :number? :max-body :number?
        :keep-alive :boolean? :close :boolean? :user-agent :string? :follow :number? & r}))
