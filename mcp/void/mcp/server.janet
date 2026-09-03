### void/mcp/server — the MCP methods over a server value.
###
### One function of consequence, `handle`: a decoded JSON-RPC message
### and a server value in, a response message (or nil, for a
### notification) out. No socket, no stdin, no boot — which is why the
### suite can drive the entire protocol without a transport, and why
### both transports are as small as they are.
###
### **The server value is the whole exposure**, built by ./registry
### from what the composition already declared:
###
###     {:info        {:name "..." :version "..."}   serverInfo
###      :instructions "..."                         optional preamble
###      :tools       [{:name :title :description :input-schema
###                     :annotations :call} ...]
###      :resources   [{:uri :name :description :mime-type :read} ...]}
###
### `:call` is (fn [arguments] -> string | {:text ... :error? bool}),
### `:read` is (fn [] -> string | {:text ... :mime-type ...}).
###
### **A tool that fails is a result, not an error.** MCP draws the
### line at who needs to read the failure: a protocol error (unknown
### method, unknown tool, malformed params) is the client's business
### and travels as a JSON-RPC error; a tool that ran and failed is the
### *model's* business — it has to see the text to try something else —
### and travels as a result with `isError` true. That distinction is
### the reason `call-tool` catches everything a tool throws.
###
### **This server asks the client for nothing.** No sampling, no
### elicitation, no roots: every one of those is a request travelling
### server -> client, which needs a stream held open per session, which
### is exactly the state this plugin refuses to keep. What comes back is
### therefore never a request, and ./jsonrpc drops responses.

(import ./jsonrpc :as rpc)

(def protocol-version
  ``The one MCP protocol version this server implements. A client
  asking for another gets this one back, which is what the
  specification prescribes: the server names a version it supports and
  the client decides whether it can live with it.``
  "2025-06-18")

(defn capabilities
  "What this server offers. Both lists are static for the life of a
  process — the tools are the composition's CLI commands and the
  resources its schemas — so nothing subscribes and nothing is
  notified of changes."
  [srv]
  @{:tools @{:listChanged false}
    :resources @{:subscribe false :listChanged false}})

# -- tools ---------------------------------------------------------------

(defn find-tool
  "The tool exposed under `name`, or nil."
  [srv name]
  (find |(= name ($ :name)) (get srv :tools [])))

(defn tool-descriptor
  "One entry of tools/list: the tool as the client sees it."
  [tool]
  (def out @{:name (tool :name)
             :description (get tool :description "")
             :inputSchema (get tool :input-schema @{"type" "object"})})
  (when-let [t (get tool :title)] (put out :title t))
  (when-let [a (get tool :annotations)] (put out :annotations a))
  out)

(defn text-content
  "The `content` array of a tool result: one text block."
  [text]
  @[@{:type "text" :text (string text)}])

(defn call-tool
  ``Run a tool and shape its answer as a tools/call result. Anything
  the tool throws becomes `isError` with the message as text: the
  model is the one that has to read it (see the header).

  `out` is an optional buffer the tool's output is collected into.
  A caller that passes one can watch it fill — which is the whole of
  ./http's progress streaming: no callback, no second execution model,
  just the buffer the call was going to write into anyway.``
  [tool arguments &opt out]
  (def [ok answer]
    (protect
      (if-let [f (get tool :call)]
        (f (or arguments @{}) out)
        (errorf "tool %s has no :call" (tool :name)))))
  (cond
    (not ok)
    @{:content (text-content (if (string? answer) answer (describe answer)))
      :isError true}

    (dictionary? answer)
    @{:content (text-content (get answer :text ""))
      :isError (true? (get answer :error?))}

    @{:content (text-content answer) :isError false}))

# -- resources -----------------------------------------------------------

(defn find-resource
  "The resource published under `uri`, or nil."
  [srv uri]
  (find |(= uri ($ :uri)) (get srv :resources [])))

(defn resource-descriptor
  "One entry of resources/list."
  [res]
  (def out @{:uri (res :uri)
             :name (res :name)
             :mimeType (get res :mime-type "text/plain")})
  (when-let [t (get res :title)] (put out :title t))
  (when-let [d (get res :description)] (put out :description d))
  out)

(defn read-resource
  "The `contents` of one resources/read. Throws what the reader
  throws — a resource that cannot be read is a protocol error, unlike
  a tool that fails (see the header)."
  [res]
  (def answer ((res :read)))
  (def [text mime]
    (if (dictionary? answer)
      [(get answer :text "") (get answer :mime-type (get res :mime-type "text/plain"))]
      [answer (get res :mime-type "text/plain")]))
  @[@{:uri (res :uri) :mimeType mime :text (string text)}])

# -- dispatch ------------------------------------------------------------

(defn- initialize-result [srv params]
  (def asked (get params :protocolVersion))
  @{:protocolVersion protocol-version
    :capabilities (capabilities srv)
    :serverInfo (get srv :info @{:name "void" :version "0.0.1"})
    :instructions (get srv :instructions)
    # a client that asked for another version gets told, in the one
    # field of the handshake a human reads, rather than left to diff
    # two strings
    :_meta (when (and asked (not= asked protocol-version))
             @{:void/requestedProtocolVersion asked})})

(defn handle
  ``Answer one decoded message (see jsonrpc/decode) against a server
  value. Returns the response message, or nil when there is nothing to
  say — a notification, or a response the client sent us.

  Notifications are answered with silence rather than with an error
  even when the method is unknown: JSON-RPC forbids responding to
  them, and a client sending `notifications/cancelled` to a server
  that runs every tool to completion has done nothing wrong.``
  [srv msg]
  (def id (get msg :id))
  (def params (get msg :params @{}))
  (cond
    (get msg :response?) nil
    (get msg :notification?) nil

    (case (get msg :method)
      "initialize" (rpc/result id (initialize-result srv params))
      "ping" (rpc/result id @{})

      "tools/list"
      (rpc/result id @{:tools (map tool-descriptor (get srv :tools []))})

      "tools/call"
      (let [name (get params :name)
            tool (and (string? name) (find-tool srv name))]
        (if tool
          (rpc/result id (call-tool tool (get params :arguments)))
          (rpc/fail id :invalid-params
                    (string/format "unknown tool %q" (if (string? name) name (describe name)))
                    @{:known (map |($ :name) (get srv :tools []))})))

      "resources/list"
      (rpc/result id @{:resources (map resource-descriptor (get srv :resources []))})

      "resources/templates/list"
      # none: every resource this server publishes has a fixed URI,
      # because every one of them is something the composition
      # declared by name
      (rpc/result id @{:resourceTemplates @[]})

      "resources/read"
      (let [uri (get params :uri)
            res (and (string? uri) (find-resource srv uri))]
        (cond
          (not res)
          (rpc/fail id :resource-not-found
                    (string/format "no resource %q" (if (string? uri) uri (describe uri)))
                    @{:uri uri})
          (let [[ok contents] (protect (read-resource res))]
            (if ok
              (rpc/result id @{:contents contents})
              (rpc/fail id :internal-error
                        (string/format "resource %s could not be read: %s"
                                       (res :uri)
                                       (if (string? contents) contents (describe contents))))))))

      (rpc/fail id :method-not-found
                (string/format "unknown method %q" (get msg :method))))))
