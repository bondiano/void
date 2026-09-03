### The MCP methods over a server value — the protocol without a
### transport. Everything here is a table in and a table out, which is the
### point of ./server holding no state.

(import ../test-support/paths)
(import void/mcp/jsonrpc :as rpc)
(import void/mcp/server :as server)

(defn- msg [id method &opt params]
  @{:id id :method method :params (or params @{}) :notification? (nil? id)})

(def calls @[])

(def srv
  @{:info @{:name "test-app" :version "1.2.3"}
    :instructions "read the room"
    :tools
    @[@{:name "echo"
        :title "echo"
        :description "Say it back"
        :input-schema @{"type" "object"}
        :read-only? true
        :call (fn [args &opt out]
                (array/push calls args)
                (string "you said " (get args :what "nothing")))}
      @{:name "boom"
        :description "Fails"
        :read-only? false
        :call (fn [args &opt out] (error "the tool exploded"))}
      @{:name "structured"
        :description "Answers with its own error flag"
        :call (fn [args &opt out] {:text "not found" :error? true})}]
    :resources
    @[@{:uri "void://health" :name "health" :mime-type "application/json"
        :read (fn [] `{"status":"up"}`)}
      @{:uri "void://broken" :name "broken"
        :read (fn [] (error "the disk is gone"))}]})

# -- initialize ----------------------------------------------------------

(def init (server/handle srv (msg 1 "initialize" @{:protocolVersion "2025-06-18"})))
(assert (= "2025-06-18" (get-in init [:result :protocolVersion])) "the version we speak")
(assert (= "test-app" (get-in init [:result :serverInfo :name])) "the server names itself")
(assert (= "read the room" (get-in init [:result :instructions])) "instructions travel")
(assert (get-in init [:result :capabilities :tools]) "tools are offered")
(assert (get-in init [:result :capabilities :resources]) "so are resources")
(assert (nil? (get-in init [:result :_meta])) "and nothing is said about the version when it matched")

# a client asking for another revision gets ours back — the
# specification's own answer — plus a note saying what it asked for
(def older (server/handle srv (msg 2 "initialize" @{:protocolVersion "2024-11-05"})))
(assert (= "2025-06-18" (get-in older [:result :protocolVersion]))
        "a server answers with a version it supports")
(assert (= "2024-11-05" (get-in older [:result :_meta :void/requestedProtocolVersion]))
        "and says which one it was asked for")

# -- ping and notifications ----------------------------------------------

(assert (empty? (get (server/handle srv (msg 3 "ping")) :result)) "ping is an empty result")
(assert (nil? (server/handle srv (msg nil "notifications/initialized")))
        "a notification is answered with silence")
(assert (nil? (server/handle srv (msg nil "notifications/nothing-we-know")))
        "even an unknown one: JSON-RPC forbids answering a notification")
(assert (nil? (server/handle srv @{:id 9 :response? true}))
        "and a response from the client is dropped")

# -- tools/list ----------------------------------------------------------

(def listed (server/handle srv (msg 4 "tools/list")))
(def names (map |($ :name) (get-in listed [:result :tools])))
(assert (deep= @["echo" "boom" "structured"] names) "every tool is listed, in the order given")
(def echo (first (get-in listed [:result :tools])))
(assert (= "Say it back" (echo :description)) "with its description")
(assert (= "object" (get-in echo [:inputSchema "type"])) "and its input schema")

# -- tools/call ----------------------------------------------------------

(def called (server/handle srv (msg 5 "tools/call" @{:name "echo" :arguments @{:what "hi"}})))
(assert (= "you said hi" (get-in called [:result :content 0 :text])) "the tool ran")
(assert (= "text" (get-in called [:result :content 0 :type])) "and answered as text")
(assert (= false (get-in called [:result :isError])) "and did not fail")
(assert (= "hi" (get-in calls [0 :what])) "the arguments reached it")

# a tool that throws is a *result*, not an error: the model is the one
# that has to read the failure and decide what to do next
(def failed (server/handle srv (msg 6 "tools/call" @{:name "boom"})))
(assert (nil? (failed :error)) "a failing tool is not a protocol error")
(assert (get-in failed [:result :isError]) "it is a result flagged as one")
(assert (string/find "exploded" (get-in failed [:result :content 0 :text]))
        "carrying what went wrong")

(def flagged (server/handle srv (msg 7 "tools/call" @{:name "structured"})))
(assert (get-in flagged [:result :isError]) "a tool may flag its own failure")
(assert (= "not found" (get-in flagged [:result :content 0 :text])) "with its own text")

# an unknown tool *is* a protocol error: the client asked for something
# that does not exist, and no model can fix that by trying again
(def unknown (server/handle srv (msg 8 "tools/call" @{:name "nope"})))
(assert (= (rpc/codes :invalid-params) (get-in unknown [:error :code]))
        "an unknown tool is refused as invalid params")
(assert (index-of "echo" (get-in unknown [:error :data :known]))
        "and the refusal says what there is instead")

# -- resources -----------------------------------------------------------

(def resources (server/handle srv (msg 10 "resources/list")))
(assert (= 2 (length (get-in resources [:result :resources]))) "both resources are listed")
(assert (= "application/json" (get-in resources [:result :resources 0 :mimeType]))
        "with the media type a client needs to parse them")

(def read (server/handle srv (msg 11 "resources/read" @{:uri "void://health"})))
(assert (= "void://health" (get-in read [:result :contents 0 :uri])) "the content names its URI")
(assert (string/find "up" (get-in read [:result :contents 0 :text])) "and carries the body")

(def missing (server/handle srv (msg 12 "resources/read" @{:uri "void://nothing"})))
(assert (= (rpc/codes :resource-not-found) (get-in missing [:error :code]))
        "a URI that resolves to nothing gets MCP's own code, not -32602")
(assert (= "void://nothing" (get-in missing [:error :data :uri])) "and the URI back")

# a resource that cannot be read is an error and not an isError result:
# there is no model decision to make about a disk that is gone
(def broken (server/handle srv (msg 13 "resources/read" @{:uri "void://broken"})))
(assert (= (rpc/codes :internal-error) (get-in broken [:error :code]))
        "a resource that throws is a protocol error")

(assert (empty? (get-in (server/handle srv (msg 14 "resources/templates/list"))
                        [:result :resourceTemplates]))
        "there are no templates: every resource here has a name somebody declared")

# -- an unknown method ---------------------------------------------------

(def nope (server/handle srv (msg 15 "prompts/list")))
(assert (= (rpc/codes :method-not-found) (get-in nope [:error :code]))
        "a method this server does not implement is refused as such")

(print "server-test ok")
