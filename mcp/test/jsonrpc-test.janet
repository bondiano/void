### The wire format: what a frame may be, and what a refusal looks
### like when it cannot be one (ADR-0031).

(import ../test-support/paths)
(import void/mcp/jsonrpc :as rpc)
(import spork/json)

# -- a request -----------------------------------------------------------

(def decoded (rpc/decode `{"jsonrpc":"2.0","id":7,"method":"tools/list","params":{"cursor":"x"}}`))
(assert (decoded :ok) "a well-formed request decodes")
(assert (= 7 (get-in decoded [:ok :id])) "the id survives")
(assert (= "tools/list" (get-in decoded [:ok :method])) "so does the method")
(assert (= "x" (get-in decoded [:ok :params :cursor])) "params decode with keyword keys")
(assert (not (get-in decoded [:ok :notification?])) "a request with an id is not a notification")

# -- a notification ------------------------------------------------------

(def note (rpc/decode `{"jsonrpc":"2.0","method":"notifications/initialized"}`))
(assert (get-in note [:ok :notification?]) "no id means a notification")
(assert (nil? (get-in note [:ok :id])) "and no id to answer to")

# a JSON null id is the same thing said differently, and nothing
# downstream should have to know that
(def null-id (rpc/decode `{"jsonrpc":"2.0","id":null,"method":"ping"}`))
(assert (nil? (get-in null-id [:ok :id])) "a null id decodes as no id")

# -- a response from the client is not a request -------------------------

(def answer (rpc/decode `{"jsonrpc":"2.0","id":1,"result":{}}`))
(assert (get-in answer [:ok :response?])
        "a message with no method is an answer to something we asked")

# -- refusals ------------------------------------------------------------

(each [text code why]
  [[`not json at all` (rpc/codes :parse-error) "a frame that is not JSON"]
   [`[{"jsonrpc":"2.0","id":1,"method":"ping"}]` (rpc/codes :invalid-request) "a batch"]
   [`"a string"` (rpc/codes :invalid-request) "a JSON value that is not an object"]
   [`{"jsonrpc":"1.0","id":1,"method":"ping"}` (rpc/codes :invalid-request) "another JSON-RPC version"]
   [`{"jsonrpc":"2.0","id":1,"method":42}` (rpc/codes :invalid-request) "a method that is not a string"]
   [`{"jsonrpc":"2.0","id":{},"method":"ping"}` (rpc/codes :invalid-request) "an id that is neither string nor number"]
   [`{"jsonrpc":"2.0","id":1,"method":"ping","params":[1,2]}` (rpc/codes :invalid-params) "positional params"]]
  (def d (rpc/decode text))
  (assert (d :error) (string why " is refused"))
  (assert (= code (get-in d [:error :error :code]))
          (string why " is refused with the code that says why")))

# the id rides along when there was one: a client that cannot correlate
# an error waits for a response that will never come
(assert (= 1 (get-in (rpc/decode `{"jsonrpc":"1.0","id":1,"method":"ping"}`) [:error :id]))
        "a refusal carries the id of the message it refused")

# and when there was none, the id is JSON null rather than absent —
# JSON-RPC 2.0 says so, and an absent id is a fourth thing to interpret
(def encoded (json/decode (rpc/encode (rpc/fail nil :parse-error "x"))))
(assert (and (in encoded "id") (= :null (get encoded "id")))
        "an error with no id carries a null one")

# -- batches are refused with the reason, not just the code --------------

(assert (string/find "2025-06-18" (get-in (rpc/decode "[]") [:error :error :message]))
        "the batch refusal names the protocol revision that removed them")

# -- encoding is one line ------------------------------------------------

(def line (rpc/encode (rpc/result 1 @{:content @[@{:type "text" :text "a\nb"}]})))
(assert (nil? (string/find "\n" line))
        "a message with a newline in it still encodes as one line — the frame is a line")
(assert (= "a\nb" (get-in (json/decode line true) [:result :content 0 :text]))
        "and the newline survives inside the string")

(print "jsonrpc-test ok")
