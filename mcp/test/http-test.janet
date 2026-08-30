### MCP over HTTP: a route like any other, stateless by construction,
### with SSE reserved for the one thing that has anything to stream
### (ADR-0031).

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/log :as log)
(import void/test :as test)
(import void/mcp/jsonrpc :as rpc)
(import void/mcp/http :as mcp-http)
(require "void/http/init")
(require "void/mcp/init")
(import spork/json)

(log/set-level! "void" :error)

(def app
  (plugin/manifest 'http/app
    :version "0.1.0"
    :requires {:void/mcp ">=0.0.1"}
    :contributes
    {:void.core/cli
     [{:name :test/hello
       :doc "Greets"
       :read-only? true
       :fn (fn [& args] (print "hello"))}
      {:name :test/slow
       :doc "Prints as it goes"
       :read-only? true
       :fn (fn [& args]
             (print "first")
             (ev/sleep 0.15)
             (print "second"))}]}))

(defn- options [&opt extra]
  {:plugins [:void/http :void/mcp :void/mcp-http app]
   :config {:env @{}
            :cli (merge {:log {:level :error} :http {:port 0}} (or extra {}))}})

(defn- rpc-post [c msg &opt headers]
  (test/inject c {:method :post :uri "/mcp"
                  :body (rpc/encode msg)
                  :headers (merge @{"content-type" "application/json"} (or headers @{}))}))

# -- the handshake -------------------------------------------------------

(test/with-http [c (options)]
  (def resp (rpc-post c (rpc/request 1 "initialize" @{:protocolVersion "2025-06-18"})))
  (assert (= 200 (resp :status)) "the endpoint answers")
  (assert (string/has-prefix? "application/json" (get-in resp [:headers "content-type"]))
          "with JSON")
  (assert (= "2025-06-18" (get-in resp [:headers "mcp-protocol-version"]))
          "and says which revision it speaks")
  (def body (test/json resp))
  (assert (= "2025-06-18" (get-in body [:result :protocolVersion])) "the handshake completes")

  # a tool call over one self-contained POST — no session was
  # established, and none is needed
  (def called (rpc-post c (rpc/request 2 "tools/call"
                                       @{:name "test_hello" :arguments @{:args []}})))
  (assert (string/find "hello" (get-in (test/json called) [:result :content 0 :text]))
          "a tool call is one request and one response")

  # a notification has no answer, and 202 is what the specification
  # asks a server to say about it
  (def note (rpc-post c (rpc/notification "notifications/initialized")))
  (assert (= 202 (note :status)) "a notification is accepted, not answered")
  (assert (empty? (test/text note)) "with no body")

  # a frame that is not a message is refused as one, with the JSON-RPC
  # error in the body rather than an HTML error page
  (def garbage (test/inject c {:method :post :uri "/mcp" :body "not json"
                               :headers @{"content-type" "application/json"}}))
  (assert (= 400 (garbage :status)) "a malformed frame is a bad request")
  (assert (= (rpc/codes :parse-error) (get-in (test/json garbage) [:error :code]))
          "and says so in JSON-RPC")

  # GET is the transport's other half in the specification, and this
  # server does not have it — because having it means holding a stream
  # per session, in one process, which is the state it refuses to keep
  (def get-resp (test/inject c {:uri "/mcp"}))
  (assert (= 405 (get-resp :status)) "GET /mcp is not allowed")
  (assert (= "POST" (get-in get-resp [:headers "allow"])) "and the answer says what is")
  (assert (string/find "server-initiated" (test/text get-resp))
          "with the reason, not just the status")

  # a protocol revision this endpoint does not speak is a 400, per the
  # specification — guessing at an unknown revision debugs the wrong end
  (def wrong-version
    (rpc-post c (rpc/request 3 "ping") @{"mcp-protocol-version" "1999-01-01"}))
  (assert (= 400 (wrong-version :status)) "an unsupported protocol version is refused")
  (assert (string/find "2025-06-18" (test/text wrong-version))
          "and the refusal names what is supported")

  (assert (= 200 ((rpc-post c (rpc/request 4 "ping")
                            @{"mcp-protocol-version" "2025-03-26"}) :status))
          "the revision before it is still spoken"))

# -- the browser is the attacker the Origin check is for -----------------

(test/with-http [c (options)]
  (def blocked (rpc-post c (rpc/request 1 "ping") @{"origin" "https://evil.example"}))
  (assert (= 403 (blocked :status))
          "a request carrying an Origin nobody allowed is refused (DNS rebinding)")
  (assert (= 200 ((rpc-post c (rpc/request 2 "ping")) :status))
          "while a client that sends no Origin — every agent — is not"))

(test/with-http [c (options {:mcp-http {:origins ["https://ops.example"]}})]
  (assert (= 200 ((rpc-post c (rpc/request 1 "ping")
                            @{"origin" "https://ops.example"}) :status))
          "an allowlisted Origin is let through"))

# -- the token -----------------------------------------------------------

(test/with-http [c (options {:mcp-http {:token "s3cret"}})]
  (def anon (rpc-post c (rpc/request 1 "ping")))
  (assert (= 401 (anon :status)) "without the token the endpoint says nothing")
  (assert (string/has-prefix? "Bearer " (get-in anon [:headers "www-authenticate"]))
          "and says what it wants")
  (assert (= 401 ((rpc-post c (rpc/request 2 "ping")
                            @{"authorization" "Bearer wrong"}) :status))
          "a wrong token is no better than none")
  (assert (= 200 ((rpc-post c (rpc/request 3 "ping")
                            @{"authorization" "Bearer s3cret"}) :status))
          "and the right one gets in"))

# -- an identity, and the scopes it carries ------------------------------
#
# `[:mcp-http :auth] :identity` reads void/auth's dyn key and nothing
# else — which is the whole of this plugin's tie to authentication
# (ADR-0023 §1, ADR-0032). The suite binds that key from a middleware
# of its own, exactly as void/auth-oauth's would after verifying an
# access token: what is under test here is the gate, not the verifier.

(var presented nil)

(def authenticator
  (plugin/manifest 'http/authenticator
    :version "0.1.0"
    :requires {:void/http ">=0.0.1"}
    :contributes
    {:void.http/middleware
     [{:name :test/identity
       # phase 4000 is void/auth's own: the identity is in place before
       # anything downstream asks for it
       :phase 4000
       :wrap (fn [handler]
               (fn [req]
                 (with-dyns [:void.auth/identity presented]
                   (handler req))))}]}))

(defn- as-agent [id body]
  (set presented id)
  (defer (set presented nil) (body)))

(test/with-http [c {:plugins [:void/http :void/mcp :void/mcp-http app authenticator]
                    :config {:env @{}
                             :cli {:log {:level :error} :http {:port 0}
                                   :mcp-http {:auth :identity
                                              :scopes ["mcp:tools"]
                                              :resource-metadata
                                              "https://api.example.test/.well-known/oauth-protected-resource"}}}}]

  # nobody: a 401 that points at the metadata document, which is how an
  # MCP client finds out which authorization server to go to
  (def anon (rpc-post c (rpc/request 1 "ping")))
  (assert (= 401 (anon :status)) "without an identity the endpoint says nothing")
  (def challenge (get-in anon [:headers "www-authenticate"]))
  (assert (string/find "resource_metadata=" challenge)
          "and the refusal carries the pointer a client needs (RFC 9728 §5.1)")
  (assert (string/find "mcp:tools" challenge) "and the scope it wants")

  # a token that is valid and does not carry the grant: 403, not 401 —
  # a client that retried the same credential would learn nothing
  (as-agent {:subject "user:1" :claims {:scope "profile"}}
            (fn []
              (def narrow (rpc-post c (rpc/request 2 "ping")))
              (assert (= 403 (narrow :status)) "an identity without the scope is forbidden")
              (assert (string/find "insufficient_scope"
                                   (get-in narrow [:headers "www-authenticate"]))
                      "with the RFC 6750 code that says so")))

  # and one that carries it
  (as-agent {:subject "user:1" :claims {:scope "mcp:tools mcp:resources"}}
            (fn []
              (assert (= 200 ((rpc-post c (rpc/request 3 "ping")) :status))
                      "an identity with the scope is served")))

  # the array spelling some issuers use instead of the string
  (as-agent {:subject "svc:1" :claims {:scp ["mcp:tools"]}}
            (fn []
              (assert (= 200 ((rpc-post c (rpc/request 4 "ping")) :status))
                      "scp is read as well as scope"))))

# with no scopes named, any authenticated identity is enough
(test/with-http [c {:plugins [:void/http :void/mcp :void/mcp-http app authenticator]
                    :config {:env @{}
                             :cli {:log {:level :error} :http {:port 0}
                                   :mcp-http {:auth :identity}}}}]
  (assert (= 401 ((rpc-post c (rpc/request 1 "ping")) :status)) "still nobody is nobody")
  (as-agent {:subject "user:1" :claims {}}
            (fn []
              (assert (= 200 ((rpc-post c (rpc/request 2 "ping")) :status))
                      "and an identity with no scopes at all gets in"))))

# -- compositions that ask for a lock and supply no key ------------------

(each [slice why]
  [[{:auth :token} "[:mcp-http :auth] :token with no token"]
   [{:scopes ["mcp:tools"] :auth :none} "scopes with nothing asking for an identity"]]
  (def [ok] (protect
              (test/start! {:plugins [:void/http :void/mcp :void/mcp-http app]
                            :only [:http/kernel]
                            :config {:env @{}
                                     :cli {:log {:level :error} :http {:port 0}
                                           :mcp-http slice}}})))
  (assert (not ok) (string why " does not start")))

# -- the endpoint can be turned off entirely -----------------------------

(test/with-http [c (options {:mcp-http {:endpoints false}})]
  (assert (= 404 ((rpc-post c (rpc/request 1 "ping")) :status))
          "[:mcp-http :endpoints] false leaves no endpoint")
  (assert (= 404 ((test/inject c {:uri "/mcp"}) :status))
          "on either method — the application mounts `handler` itself"))

# -- :prod without a token does not start --------------------------------

(def [ok err]
  (protect (test/start! {:plugins [:void/http :void/mcp :void/mcp-http app]
                         :profile :prod
                         :only [:http/kernel]
                         :config {:env @{}
                                  :cli {:log {:level :error}
                                        :http {:port 0}
                                        :deploy {:shape :single}}}})))
(assert (not ok) "an unauthenticated MCP endpoint does not start in :prod")
(assert (and (string? err) (string/find "[:mcp-http :auth] :identity" err))
        "and the refusal names every way out, strongest first")
(assert (string/find "[:mcp-http :token]" err) "the shared token among them")

(def [ok2 boot2]
  (protect (test/start! {:plugins [:void/http :void/mcp :void/mcp-http app]
                         :profile :prod
                         :only [:http/kernel]
                         :config {:env @{}
                                  :cli {:log {:level :error}
                                        :http {:port 0}
                                        :deploy {:shape :single}
                                        :mcp-http {:token "prod-token"}}}})))
(assert ok2 "with a token it starts")
(when ok2 (test/stop! boot2))

# -- SSE carries a tool's output as progress -----------------------------

(test/with-http [c (options {:mcp-http {:progress-interval 0.05}})]
  (def streamed
    (test/inject c {:method :post :uri "/mcp"
                    :body (rpc/encode
                            (rpc/request 9 "tools/call"
                                         @{:name "test_slow"
                                           :arguments @{:args []}
                                           :_meta @{:progressToken "tok"}}))
                    :headers @{"content-type" "application/json"
                               "accept" "application/json, text/event-stream"}}))
  (assert (= 200 (streamed :status)) "the call is answered")
  (assert (string/has-prefix? "text/event-stream"
                              (get-in streamed [:headers "content-type"]))
          "as a stream, because the client asked for progress")
  (def events (map |(json/decode ($ :data) true) (test/sse-events streamed)))
  (def progress (filter |(= "notifications/progress" (get $ :method)) events))
  (assert (not (empty? progress)) "the command's output arrives as progress")
  (assert (= "tok" (get-in progress [0 :params :progressToken]))
          "under the token the client chose")
  (assert (string/find "first" (get-in progress [0 :params :message]))
          "carrying what the command printed so far")
  (def final (last events))
  (assert (= 9 (final :id)) "and the last event is the response to the request")
  (assert (string/find "second" (get-in final [:result :content 0 :text]))
          "with everything the command printed")

  # the same call without a progress token is one JSON object: there
  # is nothing to stream to a client that did not ask to watch
  (def plain
    (test/inject c {:method :post :uri "/mcp"
                    :body (rpc/encode (rpc/request 10 "tools/call"
                                                   @{:name "test_slow" :arguments @{:args []}}))
                    :headers @{"content-type" "application/json"
                               "accept" "application/json, text/event-stream"}}))
  (assert (string/has-prefix? "application/json" (get-in plain [:headers "content-type"]))
          "no progress token, no stream"))

(print "http-test ok")
