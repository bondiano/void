### The stdio transport: a line is a message, and the loop keeps
### running while an agent thinks (ADR-0031).
###
### The suite drives it over an os/pipe rather than over the process's
### own stdin — same stream type, same ev/read, and a test that owns
### both ends.

(import ../test-support/paths)
(import void/core/plugin :as plugin)
(import void/core/hooks :as hooks)
(import void/core/log :as log)
(import void/mcp :as mcp)
(import void/mcp/jsonrpc :as rpc)
(import void/mcp/stdio :as stdio)
(import spork/json)

(log/set-level! "void" :fatal)

(defn- run
  ``Feed `frames` (already-encoded strings, joined by the caller into
  chunks) to a stdio server and collect what it writes. Returns
  [handled written].``
  [chunks handler]
  (def [r w] (os/pipe))
  (def written @[])
  (ev/go (fn feed []
           (each c chunks (ev/write w c))
           (:close w)))
  (def handled (stdio/serve handler {:in r :write (fn [msg] (array/push written msg))}))
  (:close r)
  [handled written])

# -- framing -------------------------------------------------------------

(defn- echo-handler [msg]
  (case (get msg :method)
    "ping" (rpc/result (msg :id) @{:pong true})
    "boom" (error "the handler broke")
    nil))

(def [handled written]
  (run [(string (rpc/encode (rpc/request 1 "ping")) "\n"
                (rpc/encode (rpc/notification "notifications/initialized")) "\n")]
       echo-handler))
(assert (= 2 handled) "both frames were read")
(assert (= 1 (length written)) "and only the request was answered")
(assert (get-in written [0 :result :pong]) "with the answer the handler gave")

# a message split across reads is still one message: the transport
# frames on newlines, not on whatever the kernel handed it
(def [_ split]
  (run ["{\"jsonrpc\":\"2.0\",\"id\":" "1,\"method\":\"ping\"}" "\n"] echo-handler))
(assert (= 1 (length split)) "a frame split across three reads is one message")
(assert (get-in split [0 :result :pong]) "and is answered")

# -- refusals ------------------------------------------------------------

(def [_ garbage] (run ["not json\n"] echo-handler))
(assert (= (rpc/codes :parse-error) (get-in garbage [0 :error :code]))
        "a frame that is not JSON is refused on the same stream")

(def [_ broken] (run [(string (rpc/encode (rpc/request 7 "boom")) "\n")] echo-handler))
(assert (= (rpc/codes :internal-error) (get-in broken [0 :error :code]))
        "a handler that throws answers with an internal error")
(assert (= 7 (get-in broken [0 :id]))
        "carrying the id, so the client stops waiting")

# a notification that fails is logged and not answered: JSON-RPC has no
# way to tell a client about a message it did not ask about
(def [_ silent]
  (run [(string (rpc/encode (rpc/notification "boom")) "\n")] echo-handler))
(assert (empty? silent) "a failing notification is answered with silence")

# blank lines between frames are frames of nothing
(def [n2 _] (run ["\n\n" (string (rpc/encode (rpc/request 1 "ping")) "\n")] echo-handler))
(assert (= 1 n2) "blank lines are not messages")

# -- the whole protocol over the transport -------------------------------
#
# The same thing `void mcp serve` does: bootstrap without starting
# anything, then answer on stdin — the tools bring their components
# with them.

(def app
  (plugin/manifest 'stdio/app
    :version "0.1.0"
    :requires {:void/mcp ">=0.0.1"}
    :contributes
    {:void.core/cli
     [{:name :test/hello
       :doc "Greets"
       :read-only? true
       :fn (fn [& args] (print "hello " (string/join args " ")))}]}))

(def boot (plugin/bootstrap {:plugins [:void/mcp app]
                             :profile :test
                             :config {:env @{} :cli {:log {:level :fatal}}}}
                            true))
(hooks/run! (boot :hooks) :config-loaded boot)
(hooks/run! (boot :hooks) :before-start boot)

(def session
  [(string (rpc/encode (rpc/request 1 "initialize"
                                    @{:protocolVersion "2025-06-18"
                                      :clientInfo @{:name "suite" :version "0"}})) "\n"
           (rpc/encode (rpc/notification "notifications/initialized")) "\n"
           (rpc/encode (rpc/request 2 "tools/list")) "\n"
           (rpc/encode (rpc/request 3 "tools/call"
                                    @{:name "test_hello" :arguments @{:args ["world"]}})) "\n")])

(def [count answers]
  (run session (fn [msg] (mcp/handle msg {:start-needs true}))))

(assert (= 4 count) "four frames in")
(assert (= 3 (length answers)) "three answers out — the notification got none")
(assert (= "2025-06-18" (get-in answers [0 :result :protocolVersion])) "the handshake")
(assert (index-of "test_hello" (map |($ :name) (get-in answers [1 :result :tools])))
        "the command is a tool")
(assert (string/find "hello world" (get-in answers [2 :result :content 0 :text]))
        "and calling it runs the command with its arguments")

# every answer is one line of JSON: that is the frame the client reads
(each a answers
  (def line (rpc/encode a))
  (assert (nil? (string/find "\n" line)) "an answer is one line")
  (assert (= "2.0" (get (json/decode line) "jsonrpc")) "and valid JSON-RPC"))

(print "stdio-test ok")
