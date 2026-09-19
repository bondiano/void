# Types of void/http's values, named where they recur.

# -- the wire ------------------------------------------------------------

# A parsed header table: `wire/parse-request-head` and `parse-response-head` accumulate
# it — lowercase names, a repeated header an array of its values.
(def HttpHeaders :typedef
  '@{:string (or :string @[:string])})

# A request head: the table `wire/parse-request-head` builds.
(def HttpRequestHead :typedef
  '@{:method :string :path :string :http-version [:number :number]
    :headers HttpHeaders :head-size :number})

# A response head: the table `wire/parse-response-head` builds.
(def HttpResponseHead :typedef
  '@{:status :number :message :string :http-version [:number :number]
    :headers HttpHeaders :head-size :number})

# The chunked-body decoder's state: what `wire/chunked-start` and `decode-chunked` answer,
# tagged by `:phase`. `:need` asks for more bytes, `:out` is what the last call decoded.
(def HttpChunkedState :typedef
  '(or {:phase :size :pos :number :received :number :out :string? :need :number?}
      {:phase :data :pos :number :remaining :number :received :number :out :string?
       :need :number?}
      {:phase :trailers :pos :number :received :number :out :string? :need :number?}
      {:phase :done :pos :number :received :number :out :string? :need :number?}
      {:phase :error
       :reason (enum :too-large :malformed :bad-terminator :oversized-line :oversized-trailers)
       :message :string :pos :number :received :number :out :string? :need :number?}))

# -- the ring model ------------------------------------------------------

# The request a handler receives: built by `server/build-request` (and `make-request` on
# the inject path), extended by middleware (`:params`, `:void/route`, `:form`,
# `:session`, `:cookies`, …) — hence open.
(def HttpRequest :typedef
  '@{:method :keyword :path :string :raw-path :string :query-string :string?
    :query @{:string :any} :headers HttpHeaders :http-version [:number :number]
    :body :any :received :number :arrived :number? :remote-addr :string? & r})

# A response: the table `ring/response` builds, or a struct literal a handler returns (one
# shape: a struct and a table are held to it by what they hold);
# `ring/upgrade` and handlers add keys (`:void.http/upgrade`, `:session`) — hence open.
(def HttpResponse :typedef
  '{:status :number :headers (or {:string :any} :nil) :body :any & r})

# A response as `ring/response` (and `text`, `html`, `redirect`, `sse`, …) builds it: a table
# whose headers are a table too, so the `ring/header` family can put into it.
(def HttpResponseTable :typedef
  '@{:status :number :body :any :headers @{:string :any} & r})

# What `ring/upgrade` builds: a response whose `:void.http/upgrade` takes the socket over once
# the head is out, handed the connection and the bytes that arrived behind the request.
(def HttpUpgradeResponse :typedef
  '@{:status :number :body :any :headers @{:string :any}
    :void.http/upgrade (fn [:any :any] :any) & r})

# A handler: what the server, routing and every middleware wrapper call.
(def HttpHandler :typedef
  '(fn [HttpRequest] HttpResponse))

# Set-Cookie attributes: written by callers of `ring/cookie-str` and merged by
# `ring/delete-cookie` and `session/wrap-session`.
(def HttpCookieOptions :typedef
  '{:path :string? :domain :string? :max-age :number? :expires :string?
   :secure :boolean? :http-only :boolean?
   :same-site (or (enum :strict :lax :none) :nil) & r})

# A multipart part: the table `multipart/parse` builds, or the struct a caller hands
# `multipart/encode`.
(def HttpMultipartPart :typedef
  '{:name :string? :filename :string? :content-type :string?
   :headers (or {:any :any} :nil) :value :any & r})

# -- routing -------------------------------------------------------------

# One route declaration: the struct `router/route` (and GET, POST, …) builds.
(def HttpRouteDeclaration :typedef
  '{:route :boolean :method :keyword :pattern :string
   :handler (or :symbol :function) :meta {:keyword :any}})

# A routes value: the struct `router/routes` builds — a global metadata layer over
# route declarations, groups and nested routes values.
(def HttpRoutes :typedef
  '{:routes :boolean :global {:keyword :any} :children [:any]})

# A :void.http/route-source contribution: written by `defroutes`, rebuilt by the table
# build from the live manifests.
(def HttpRouteSource :typedef
  '{:name :keyword
   :routes (or HttpRoutes (fn [:any] HttpRoutes))
   :env (or (fn [] :table) :table :nil)})

# A :void.http/middleware (or :void.http/edge) contribution value: written by plugins,
# placed by `:after`/`:before` edges to anchors or neighbours; `middleware/stage-wrapper`
# builds the synthetic ones. A `:route-aware` one's `:wrap` is handed the route's metadata
# as well.
(def HttpMiddleware :typedef
  '{:name :keyword
   :before (or :keyword [:keyword] :nil) :after (or :keyword [:keyword] :nil)
   :wrap (or (fn [HttpHandler] HttpHandler) (fn [HttpHandler {:keyword :any}] HttpHandler))
   :when (or :function :cfunction :nil)
   :named :boolean? :route-aware :boolean? :doc :string?})

# A middleware contribution attributed to its plugin: boot's resolution builds it, the
# table build adds the `:stage` ones.
(def HttpMiddlewareContribution :typedef
  '{:plugin :keyword :value HttpMiddleware :stage :boolean?})

# One chain step as data: `middleware/describe` builds it, `select` merges a `:reason`
# into the declined ones.
(def HttpChainStep :typedef
  '{:name :keyword :plugin :keyword :stage :boolean?
   :before (or :keyword [:keyword] :nil) :after (or :keyword [:keyword] :nil)
   :reason :keyword?})

# An anchor in the order `middleware/order` answers: a named place of the chain (or the
# edge), with no wrapper of its own.
(def HttpAnchor :typedef
  '{:name :keyword :anchor :boolean})

# A route table entry: built by `router/build-table`, frozen with the table; dispatch
# puts it at (req :void/route).
(def HttpRoute :typedef
  '{:name :keyword :method :keyword :pattern :string :params [:keyword]
   :peg (or :abstract :nil) :static :string? :handler (or :symbol :function)
   :no-reload :boolean :meta {:keyword :any} :provenance {:keyword :any}
   :warnings [:string] :chain HttpHandler :middleware [:keyword]
   :steps [HttpChainStep] :declined [HttpChainStep] :hooks {:keyword :any}
   :source :keyword})

# The route table: the frozen struct `router/build-table` builds.
(def HttpRouteTable :typedef
  '{:routes [HttpRoute]
   :by-name {:keyword HttpRoute}
   :static {:keyword {:string HttpRoute}}
   :dynamic {:keyword [HttpRoute]}})

# The one-slot holder of the current table: the table `router/cell` builds.
(def HttpRouteCell :typedef
  '@{:table HttpRouteTable?})

# -- errors --------------------------------------------------------------

# The context an error renderer is called with: built by `errors/wrap-panic` and
# `render-error`.
(def HttpErrorContext :typedef
  '{:status :number :dev :any :stacktrace :string? :error :any})

# A :void.http/error-renderer contribution value, written by plugins; tried in the
# order its `:after`/`:before` edges to `errors/renderer-anchors` (or a neighbour)
# give, first response wins.
(def HttpErrorRenderer :typedef
  '{:name :keyword :fn (or :function :cfunction)
   :after (or :keyword [:keyword] :nil) :before (or :keyword [:keyword] :nil)})

# -- sessions ------------------------------------------------------------

# A session store: the struct a :void.http/session-store `:make` returns
# (`session/memory-store`, void/redis-http, void/db-http) — each adds keys of its own.
(def HttpSessionStore :typedef
  '{:name :keyword?
   :load (fn [:string] (or @{:any :any} :nil))
   :save (fn [:string @{:any :any} :number] :string)
   :delete (fn [:string] :any)
   :sweep (fn [] :any)
   & r})

# -- the kernel ----------------------------------------------------------

# The http context: the table `build-context` assembles at :before-start.
(def HttpContext :typedef
  '@{:boot Boot :config :any :workers :number :dev :boolean
    :renderers (or @[HttpErrorRenderer] :nil) :codecs :any :access-log :boolean
    :edge :tuple :edge-info :tuple :on-error-global :tuple :on-timeout-global :tuple
    :on-response-global :tuple :session (or :any :nil) :cell HttpRouteCell
    :build-args :any :handler HttpHandler :limits-fn (fn [:any :any] :any)
    :notify-response (fn [HttpRequest HttpResponse] :any)
    :notify-timeout (fn [HttpRequest] :any)})

# A running listener: the table `server/start` builds.
(def HttpServer :typedef
  '@{:listener :abstract
    :state @{:conns @{:abstract :any} :draining :boolean}
    :accept-fiber :fiber
    :host :string
    :port :number
    :config @{:keyword :any}})

# A prefork master: the table `prefork/start` builds.
(def HttpPreforkMaster :typedef
  '@{:procs @{:number :abstract} :workers :number :stopping :boolean
    :cmd [:string]})

# -- the client ----------------------------------------------------------

# A client for one host: the table `client/open` builds; `send!` fills and clears `:conn`
# (a socket, or the table stream `void/tls` connects).
(def HttpClient :typedef
  '@{:host :string :port :string :scheme :string :authority :string
    :headers {:any :any} :cookies {:any :any}
    :timeout :number? :connect-timeout :number? :max-body :number :keep-alive :boolean
    :conn (or :abstract @{:read :function :write :function :close :function & r} :nil)
    :buf :buffer})

# What the client answers: the table `read-response!` builds; `request` adds `:url` and
# `:redirects`, and an `around-request` wrapper may add its own — hence open.
(def HttpClientResponse :typedef
  '@{:status :number :message :string :http-version [:number :number]
    :headers HttpHeaders :body :string? :bytes :number :close :boolean
    :url :string? :redirects :tuple? & r})

# A client request: the struct a caller hands `request`, `send!` and the verb helpers, or
# the table `follow-target` builds for the next hop.
(def HttpRequestOptions :typedef
  '{:url :string? :method :any :target :string? :path :string?
   :query (or {:any :any} :string :nil)
   :headers (or {:any :any} :nil) :cookies (or {:any :any} :nil)
   :body :any :form (or {:any :any} :nil)
   :multipart (or [HttpMultipartPart] :nil)
   :timeout :number? :connect-timeout :number? :max-body :number?
   :keep-alive :boolean? :close :boolean? :user-agent :string? :follow :number? & r})
