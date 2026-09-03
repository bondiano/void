### void/mcp/jsonrpc — JSON-RPC 2.0 as data.
###
### MCP is JSON-RPC 2.0 and nothing else, so this module is the whole
### wire format: bytes in, a message table out; a message table in,
### one line of JSON out. It knows no MCP method — ./server does — and
### it holds no state, which is what lets both transports (./stdio and
### ./http) share it without sharing anything else.
###
### **A line is a message.** The stdio transport frames messages by
### newline (MCP's own rule), and `encode` therefore guarantees a
### single line: `json/encode` never emits one, and this module never
### adds one except as the frame.
###
### **Batches are refused, and that is the specification.** JSON-RPC
### 2.0 has them; MCP removed them in 2025-06-18, after having them in
### 2025-03-26. Accepting an array here would mean answering with one,
### and an array of responses on a transport that promised none is a
### worse failure than a readable refusal.
###
### **Every rejection carries an id when the message had one.** A
### client that cannot correlate an error waits for a response that
### will never come, so `decode` digs the id out of a message it is
### otherwise refusing.

(import spork/json)

(def version "The only JSON-RPC version MCP speaks." "2.0")

(def codes
  ``The error codes this server uses. The first five are JSON-RPC
  2.0's; :resource-not-found is MCP's own (server/resources), and it
  is the one place MCP adds to the vocabulary rather than reusing
  -32602 — a URI that does not resolve is not a malformed request.``
  {:parse-error -32700
   :invalid-request -32600
   :method-not-found -32601
   :invalid-params -32602
   :internal-error -32603
   :resource-not-found -32002})

(defn request
  "A request message — the client half, which the suite and
  ./http's tests speak."
  [id method &opt params]
  (def m @{:jsonrpc version :id id :method method})
  (when params (put m :params params))
  m)

(defn notification
  "A notification: a method with no id, and therefore no answer."
  [method &opt params]
  (def m @{:jsonrpc version :method method})
  (when params (put m :params params))
  m)

(defn result
  "A successful response to the request `id`."
  [id value]
  @{:jsonrpc version :id id :result value})

(defn fail
  ``An error response. `code` is a keyword from `codes` or a number;
  `data` is optional and rides in the error object, which is where a
  client looks for the machine-readable half of a refusal.``
  [id code message &opt data]
  (def err @{:code (get codes code code) :message message})
  (when data (put err :data data))
  # JSON-RPC 2.0: an error whose id could not be read carries a null
  # id rather than none — :null is what spork/json writes as null, and
  # an omitted id would be a fourth thing a client has to interpret
  @{:jsonrpc version :id (if (nil? id) :null id) :error err})

(defn error?
  "Is this message an error response?"
  [msg]
  (and (dictionary? msg) (not (nil? (get msg :error)))))

(defn encode
  "One message as one line of JSON — the frame both transports write."
  [msg]
  (json/encode msg))

(defn- json-id
  ``The id of a decoded message, or nil. JSON null decodes to the
  keyword :null (spork/json), and a null id is JSON-RPC's way of
  saying "no id" — the two collapse here so nothing downstream has to
  know the encoding.``
  [msg]
  (def id (get msg :id))
  (cond
    (nil? id) nil
    (= :null id) nil
    (or (number? id) (string? id) (buffer? id)) (if (bytes? id) (string id) id)
    :bad-id))

(defn decode
  ``Decode one frame. Returns

      {:ok {:id :method :params :notification? true|false}}
      {:error <an error response ready to encode>}

  A notification (no id) that turns out to be invalid still produces
  an error response here; the caller drops it, because JSON-RPC
  forbids answering a notification — but the check belongs to the
  format and the decision to stay silent belongs to the transport.``
  [text]
  (def [ok parsed] (protect (json/decode text true)))
  (cond
    (not ok)
    {:error (fail nil :parse-error
                  (string "not JSON: " (if (string? parsed) parsed (describe parsed))))}

    (indexed? parsed)
    {:error (fail nil :invalid-request
                  (string "JSON-RPC batches are not supported: MCP removed them in "
                          "protocol version 2025-06-18. Send one message per frame."))}

    (not (dictionary? parsed))
    {:error (fail nil :invalid-request "a JSON-RPC message must be an object")}

    (do (def id (json-id parsed))
        (def method (get parsed :method))
        (cond
          (= :bad-id id)
          {:error (fail nil :invalid-request "the id of a request must be a string or a number")}

          (not= version (get parsed :jsonrpc))
          {:error (fail id :invalid-request
                        (string/format "jsonrpc must be %q, got %q" version (get parsed :jsonrpc)))}

          # a response, not a request: a client answering a server
          # request. This server sends none (see ./server on why it
          # asks the client for nothing), so an answer to nothing is
          # dropped rather than escalated
          (nil? method)
          {:ok @{:id id :response? true :params (get parsed :result)}}

          (not (string? method))
          {:error (fail id :invalid-request "method must be a string")}

          (and (not (nil? (get parsed :params)))
               (not (dictionary? (get parsed :params))))
          {:error (fail id :invalid-params
                        "params must be an object — this server declares no positional parameters")}

          {:ok @{:id id
                 :method method
                 :params (get parsed :params @{})
                 :notification? (nil? id)}}))))
