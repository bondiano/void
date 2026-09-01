### void/mcp-http — MCP over HTTP, as a route (SPEC.md §5.18,
### ADR-0031).
###
### The second transport, and a separate plugin in this package: an
### agent talking to a jobs worker over stdio has no reason to compose
### an HTTP kernel — the void/cache — void/cache-http split.
###
### **It is a route, and that is the whole security story** (the form
### of ADR-0028): `POST /mcp` goes through routing, the phase chain,
### `void/security`'s headers and limits, `void/pressure`'s shedding
### and whatever the application put in front of it. Nothing here
### re-implements any of that.
###
### **Streamable HTTP, and stateless on purpose.** MCP has two HTTP
### transports: the 2024-11-05 pair (`GET /sse` + `POST /messages`)
### and the Streamable HTTP of 2025-03-26. The older one is a session
### pinned to a process — the server holds the stream, the client
### posts to it by session id, and the two must land on the same
### replica. That is a store outside one process's reach, which under
### `[:deploy :shape] :fleet` is exactly what ADR-0030 refuses. So:
### Streamable HTTP, no `Mcp-Session-Id` issued, every POST
### self-contained. A `GET /mcp` gets 405 and a sentence saying why —
### which is the answer the specification prescribes for a server with
### no server-initiated messages to send.
###
### **SSE carries progress, and nothing else.** A response to one
### request is one message; streaming it would be ceremony. But a tool
### that is a CLI command prints as it goes — `void db migrate` says
### what it applied, line by line — and a client that sent a
### `progressToken` asked to see that. So a `tools/call` with a token,
### from a client that accepts `text/event-stream`, is answered with a
### stream of `notifications/progress` carrying what the command has
### printed so far, then the response, then end of stream. Without a
### token the same call is one JSON object, because there is nothing
### to stream.
###
### **The gate has two settings, for two sizes of deployment.**
### `[:mcp-http :auth] :token` is a shared bearer token compared
### without leaking its prefix — one operator, one agent, one secret.
### `:identity` is the real one: the request must arrive with an
### authenticated identity, and with every scope `[:mcp-http :scopes]`
### names. It is read from `void/auth`'s **dyn key** rather than by
### importing the package (ADR-0023 §1) — so an OAuth access token
### verified by `void/auth-oauth` (ADR-0032), a session cookie, or an
### application's own authentication all satisfy it, and this plugin
### knows about none of them. A refusal carries `WWW-Authenticate`
### with the RFC 6750 code and, when `[:mcp-http :resource-metadata]`
### names it, the pointer to this server's protected-resource
### document: that pointer is how an MCP client discovers *which*
### authorization server to go to, and it is the difference between
### "401" and "401, and here is how to fix it".
###
### The Origin allowlist is the DNS-rebinding defence the
### specification asks for: a browser always sends `Origin`, an agent
### on the same machine does not, so the default — no origins allowed
### — refuses the page that found your port without refusing your
### client.
###
### In `:prod` the endpoint does not start with nothing in front of
### it. What it cannot do is carry a `:void.authz/policy` of its own:
### the route table is built before the config could name one, so the
### third exit is the one void/obs-http documents for its paths — turn
### the built-in endpoint off and mount `handler` in the application's
### own route source, where the route carries whatever metadata it
### deserves, `:void.auth/scopes` included.

(import void/core/plugin :as plugin)
(import void/http/ring :as ring)
(import void/http/router :as router)
(import ./jsonrpc :as rpc)
(import ./server :as mcp-server)
(import ./init :as mcp)

(def path "The path the built-in endpoint answers on." "/mcp")

(def accepted-protocol-versions
  ``The values of `MCP-Protocol-Version` this endpoint accepts. Both
  revisions speak the same Streamable HTTP; a client that names
  anything else gets 400, which is what the specification asks for —
  guessing at an unknown revision is how a client ends up debugging
  the wrong end.``
  ["2025-06-18" "2025-03-26"])

(def Config
  "Schema of the [:mcp-http] config slice."
  {:endpoints [:optional :boolean]
   :auth [:optional [:enum :none :token :identity]]
   :token [:optional :string]
   :scopes [:optional [:vector :string]]
   :resource-metadata [:optional :string]
   :origins [:optional [:vector :string]]
   :progress-interval [:optional [:number {:min 0.01}]]})

(def defaults
  {:endpoints true
   :origins []
   :scopes []
   :progress-interval 0.1})

(var settings "The [:mcp-http] slice, read at :before-start." defaults)

(def identity-dyn
  ``Where the current identity lives — `void/auth`'s dyn key, read by
  name rather than by importing the package. That indirection is
  ADR-0023's and ADR-0024's, and it is what lets this plugin accept an
  OAuth access token (void/auth-oauth), a session cookie or an
  application's own authentication without knowing which is in the
  composition, or whether any of them is.``
  :void.auth/identity)

(defn auth-mode
  ``What this endpoint demands of a request:

    :none      nothing — a development default, and a boot error in :prod
    :token     the shared bearer token in [:mcp-http :token]
    :identity  an authenticated identity, and every scope in
               [:mcp-http :scopes]

  Unset means `:token` when a token is configured and `:none`
  otherwise, so the setting that was there before this one still means
  what it meant.``
  [&opt cfg]
  (default cfg settings)
  (or (cfg :auth)
      (cond
        (cfg :token) :token
        (not (empty? (get cfg :scopes []))) :identity
        :none)))


# -- the gate ------------------------------------------------------------

(defn- same-secret?
  ``Compare two secrets without leaking their common prefix in the
  time it takes — the same comparison void/obs-http makes for
  /metrics, and for the same reason.``
  [a b]
  (def x (string a))
  (def y (string b))
  (var diff (if (= (length x) (length y)) 0 1))
  (def n (min (length x) (length y)))
  (loop [i :range [0 n]]
    (set diff (bor diff (bxor (in x i) (in y i)))))
  (zero? diff))

(defn- token-ok? [req]
  (if-let [token (settings :token)]
    (if-let [given (ring/request-header req "authorization")]
      (same-secret? (string "Bearer " token) given)
      false)
    # :auth :token with no token configured is a composition that asks
    # for a lock and supplies no key; build-settings refuses it
    false))

(defn- scopes-of
  ``The scopes an identity carries. `scope` is the space-delimited
  string RFC 6749 defines and `scp` the array some issuers send;
  reading both here rather than importing void/auth-oauth keeps this
  plugin's only tie to authentication the dyn key above.``
  [id]
  (def raw (or (get-in id [:claims :scope]) (get-in id [:claims :scp])))
  (cond
    (nil? raw) []
    (bytes? raw) (filter |(not (empty? $)) (string/split " " (string raw)))
    (indexed? raw) (map string raw)
    []))

(defn- challenge [&opt error description scope]
  (def parts @[(string/format "Bearer realm=%q" "mcp")])
  (when error (array/push parts (string/format "error=%q" error)))
  (when description (array/push parts (string/format "error_description=%q" description)))
  (when (and scope (not (empty? scope)))
    (array/push parts (string/format "scope=%q" (string/join scope " "))))
  # the pointer an MCP client follows to find out *where* to get a
  # token (RFC 9728 §5.1). void/auth-oauth serves that document and
  # can build this URL from its own audience; here it is configuration,
  # because this plugin does not know whether that one is composed
  (when-let [url (settings :resource-metadata)]
    (array/push parts (string/format "resource_metadata=%q" url)))
  (string/join parts ", "))

(defn- refusal
  ``The answer to a request this endpoint will not serve: 401 when
  there is no acceptable credential, 403 when there is one and it may
  not do this — RFC 6750 draws that line, and it matters to a client,
  which retries the first and must not retry the second.``
  [status error description &opt scope]
  (ring/response status
                 (string status " " (if (= 401 status) "Unauthorized" "Forbidden"))
                 @{"content-type" "text/plain; charset=utf-8"
                   "www-authenticate" (challenge error description scope)}))

(defn- gate
  "nil when the request may proceed, or the refusal it earned."
  [req]
  (case (auth-mode)
    :none nil
    :token (unless (token-ok? req)
             (refusal 401 "invalid_token" "this endpoint expects its bearer token"))
    :identity
    (let [id (dyn identity-dyn)
          wanted (get settings :scopes [])]
      (cond
        (nil? id)
        (refusal 401 "invalid_token"
                 "this endpoint needs an authenticated identity" wanted)
        (let [have (scopes-of id)
              missing (filter |(not (index-of $ have)) wanted)]
          (unless (empty? missing)
            (refusal 403 "insufficient_scope"
                     "the credential is valid and does not carry every scope this endpoint needs"
                     wanted)))))))

(defn- origin-ok? [req]
  (if-let [origin (ring/request-header req "origin")]
    (truthy? (index-of origin (get settings :origins [])))
    true))

(defn- protocol-ok? [req]
  (if-let [given (ring/request-header req "mcp-protocol-version")]
    (truthy? (index-of given accepted-protocol-versions))
    # absent means 2025-03-26 by the specification's own default, and
    # that is one of the two this endpoint speaks
    true))

(defn- accepts-sse? [req]
  (if-let [accept (ring/request-header req "accept")]
    (truthy? (string/find "text/event-stream" (string/ascii-lower accept)))
    false))

# -- answering -----------------------------------------------------------

(def- json-headers
  @{"content-type" "application/json"
    "mcp-protocol-version" mcp-server/protocol-version})

(defn- json-response [status msg]
  (ring/response status (rpc/encode msg) (merge @{} json-headers)))

(defn- progress-notification [token progress message]
  (rpc/notification "notifications/progress"
                    @{:progressToken token
                      :progress progress
                      :message message}))

(defn- streamed-call
  ``A tools/call answered as SSE: `notifications/progress` carrying
  what the command has printed since the last event, then the
  response, then the end of the stream.

  The call runs in its own fiber and writes into `out`; this one
  watches the buffer. Watching rather than being called back is what
  keeps the tool ignorant of the transport — a CLI command prints, and
  printing is all it has ever done.``
  [srv tool arguments id token]
  (def out @"")
  (def done @[])
  (def interval (get settings :progress-interval 0.1))
  (ring/sse
    (coro
      # the call is its own fiber, so a client that hangs up does not
      # abandon a half-run command: what was started finishes, and only
      # the stream it was narrating goes away
      (ev/go (fn run-tool []
               (def [ok answer] (protect (mcp-server/call-tool tool arguments out)))
               (array/push done
                           (if ok
                             answer
                             @{:content (mcp-server/text-content
                                          (if (string? answer) answer (describe answer)))
                               :isError true}))))
      (var sent 0)
      (var progress 0)
      (while (empty? done)
        (ev/sleep interval)
        (when (> (length out) sent)
          (++ progress)
          (yield {:data (rpc/encode (progress-notification
                                      token progress
                                      (string (buffer/slice out sent))))})
          (set sent (length out))))
      # whatever landed in the buffer between the last tick and the end
      (when (> (length out) sent)
        (++ progress)
        (yield {:data (rpc/encode (progress-notification
                                    token progress
                                    (string (buffer/slice out sent))))}))
      (yield {:data (rpc/encode (rpc/result id (first done)))}))
    @{"mcp-protocol-version" mcp-server/protocol-version}))

(defn- streamable? [req msg]
  (and (= "tools/call" (get msg :method))
       (not (get msg :notification?))
       (accepts-sse? req)
       (not (nil? (get-in msg [:params :_meta :progressToken])))))

(defn- origin-refusal [req]
  (unless (origin-ok? req)
    (ring/response 403 "403 Forbidden — this Origin is not in [:mcp-http :origins]"
                   @{"content-type" "text/plain; charset=utf-8"})))

(defn- protocol-refusal [req]
  (unless (protocol-ok? req)
    (json-response 400
                   (rpc/fail nil :invalid-request
                             (string "unsupported MCP-Protocol-Version — this endpoint speaks "
                                     (string/join accepted-protocol-versions " and "))))))

(defn- answer [req]
  (def decoded (rpc/decode (string (or (req :body) ""))))
  (if-let [err (get decoded :error)]
    (json-response 400 err)
    (let [msg (decoded :ok)
          srv (mcp/server-value)]
      (cond
        # a notification or a response: nothing to say, and 202 is the
        # specification's own status for it
        (or (get msg :notification?) (get msg :response?))
        (do (mcp-server/handle srv msg)
            (ring/response 202 "" (merge @{} json-headers)))

        (streamable? req msg)
        (if-let [tool (mcp-server/find-tool srv (get-in msg [:params :name]))]
          (streamed-call srv tool (get-in msg [:params :arguments]) (msg :id)
                         (get-in msg [:params :_meta :progressToken]))
          (json-response 200 (mcp-server/handle srv msg)))

        (json-response 200 (mcp-server/handle srv msg))))))

(defn handler
  ``POST /mcp — one JSON-RPC message in, one answer out. Public, so an
  application that wants the endpoint on another path, behind an
  authorization policy or inside a route group mounts it itself and
  turns [:mcp-http :endpoints] off.

  The four gates in front of the answer are ordered by what they cost
  a caller to learn: an Origin nobody allowed is refused before a
  credential is read, and a credential is checked before a body is
  parsed.``
  [req]
  (if-not (settings :endpoints)
    (ring/not-found)
    (or (origin-refusal req)
        (gate req)
        (protocol-refusal req)
        (answer req))))

(defn get-handler
  ``GET /mcp — 405, because this server holds no stream to push
  messages down. Everything it says is an answer to something the
  client asked, and that answer travels on the POST that asked.``
  [req]
  (if (settings :endpoints)
    (ring/response 405
                   (string "405 Method Not Allowed — this MCP endpoint sends no "
                           "server-initiated messages, so it holds no SSE stream open. "
                           "POST your JSON-RPC messages to " path ".")
                   @{"content-type" "text/plain; charset=utf-8"
                     "allow" "POST"})
    (ring/not-found)))

# -- config and the production gate --------------------------------------

(defn build-settings
  "The [:mcp-http] slice over the defaults. Normally called by the
  :before-start hook."
  [boot]
  (def cfg (merge defaults (or (get-in boot [:config :values :mcp-http]) {})))
  (def mode (auth-mode cfg))
  (when (and (= :token mode) (nil? (cfg :token)))
    (error (string "[:mcp-http :auth] is :token and [:mcp-http :token] is not set — "
                   "a lock with no key. Set the token, or name another mode.")))
  (when (and (= :none mode) (not (empty? (get cfg :scopes []))))
    (error (string "[:mcp-http :scopes] names scopes and [:mcp-http :auth] is :none — "
                   "scopes are checked on an identity, and this endpoint is not asking "
                   "for one. Set [:mcp-http :auth] :identity.")))
  (when (and (= :prod (boot :profile))
             (cfg :endpoints)
             (= :none mode))
    (error (string "[:mcp-http] serves POST " path " in the :prod profile with nothing in "
                   "front of it: an MCP endpoint runs this application's tools, and an "
                   "unauthenticated one runs them for whoever reaches the port. Three ways "
                   "out, in the order they scale: [:mcp-http :auth] :identity with "
                   "void/auth-oauth composed, so an OAuth access token issued *for this "
                   "server* is what opens it (and [:mcp-http :scopes] says which grant); "
                   "[:mcp-http :token] with a shared bearer token (a {:secret \"MCP_TOKEN\"} "
                   "config value) for one operator and one agent; or [:mcp-http :endpoints] "
                   "false and mount void/mcp-http's `handler` in your own route source, "
                   "where the route can carry :void.authz/policy and :void.auth/scopes.")))
  cfg)

(plugin/contribute! :void.core/hooks
  {:hook :before-start
   :phase 450
   :name :mcp-http/capture-config
   :doc "Read the [:mcp-http] slice before the route table is built"
   :fn (fn capture [boot] (set settings (build-settings boot)))})

(def- own-routes
  # no :void.openapi/hidden: that key belongs to void/openapi, and a
  # route source may not name a key its plugin did not require (the
  # table build rejects it). An MCP endpoint in an application's
  # OpenAPI document is honest anyway — it is a route like the others
  (router/routes {}
    (router/POST path 'handler {:name :void.mcp/endpoint})
    (router/GET path 'get-handler {:name :void.mcp/stream})))

(plugin/defplugin void/mcp-http
  :doc "MCP over HTTP as an ordinary route: POST /mcp speaks Streamable HTTP with no session to pin to a process, SSE carries a tool's output as progress when the client asked for it, GET answers 405. Bearer token and Origin allowlist; in :prod the endpoint does not start without a token."
  :version "0.0.1"
  :requires {:void/core ">=0.0.1" :void/mcp ">=0.0.1" :void/http ">=0.0.1"}
  :config-key :mcp-http
  :config-schema Config
  :config-defaults defaults
  :contributes
  {:void.http/route-source [{:name :void/mcp-http
                             :routes own-routes
                             :env (router/env-ref (curenv))}]})
